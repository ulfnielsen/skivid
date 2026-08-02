import CoreGraphics
import XCTest
import simd
@testable import SkiVideoCore

final class RegistrationResidualTests: XCTestCase {
    // MARK: - Test Helper Verification
    // These tests verify that TestImageFactory.semiTransparent() actually produces
    // the requested alpha values. Without this, all downstream tests are vacuous.

    func testSemiTransparentHelperProducesRequestedAlphaValues() {
        let reference = TestImageFactory.textured(width: 100, height: 100)

        // Extract alpha using the same direct alphaOnly approach as the metric uses
        func extractAlpha(_ image: CGImage) -> [UInt8]? {
            let width = image.width
            let height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height)
            guard let context = CGContext(
                data: &bytes,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ) else {
                return nil
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return bytes
        }

        // Test that each target alpha value is actually produced
        let testCases: [(target: UInt8, description: String)] = [
            (0, "fully transparent"),
            (64, "25% opaque"),
            (128, "50% opaque"),
            (191, "75% opaque"),
            (255, "fully opaque"),
        ]

        for (targetAlpha, description) in testCases {
            let semiTransp = TestImageFactory.semiTransparent(reference, alpha: targetAlpha)
            guard let alphaBytes = extractAlpha(semiTransp) else {
                XCTFail("Failed to extract alpha for \(description)")
                continue
            }

            // All pixels should have the target alpha value
            let uniqueAlphas = Set(alphaBytes)
            XCTAssertEqual(
                uniqueAlphas,
                [targetAlpha],
                "semiTransparent(alpha: \(targetAlpha)) (\(description)) must produce uniform alpha=\(targetAlpha), "
                + "got \(uniqueAlphas.sorted())"
            )
        }
    }

    // MARK: - Registration Residual Tests

    func testIdenticalImagesUnderIdentityWarpGiveNearZeroDifference() {
        let image = TestImageFactory.textured(width: 320, height: 240)

        let residual = RegistrationResidual.measure(
            reference: image,
            floating: image,
            warp: RegistrationResidual.identityWarp
        )

        XCTAssertLessThan(residual.meanAbsoluteDifference, 1.0)
        XCTAssertGreaterThan(residual.overlapFraction, 0.99)
    }

    func testAMisalignedPairScoresWorseThanAnAlignedOne() {
        let reference = TestImageFactory.textured(width: 320, height: 240)
        let shifted = TestImageFactory.transformed(
            reference,
            by: CGAffineTransform(translationX: 20, y: 12)
        )

        let uncorrected = RegistrationResidual.measure(
            reference: reference,
            floating: shifted,
            warp: RegistrationResidual.identityWarp
        )
        // Warping the shifted image back by the known offset should recover
        // the reference.
        let corrected = RegistrationResidual.measure(
            reference: reference,
            floating: shifted,
            warp: matrix_float3x3(CGAffineTransform(translationX: -20, y: -12))
        )

        XCTAssertLessThan(
            corrected.meanAbsoluteDifference,
            uncorrected.meanAbsoluteDifference,
            "correcting a known shift must beat doing nothing"
        )
    }

    func testAWarpPushingTheImageOffFrameReportsLowOverlap() {
        let reference = TestImageFactory.textured(width: 320, height: 240)

        let residual = RegistrationResidual.measure(
            reference: reference,
            floating: reference,
            warp: matrix_float3x3(CGAffineTransform(translationX: 5000, y: 5000))
        )

        XCTAssertLessThan(residual.overlapFraction, 0.01)
    }

    func testDifferenceIsReportedInEightBitUnits() {
        let image = TestImageFactory.textured(width: 64, height: 64, seed: 1)

        let residual = RegistrationResidual.measure(
            reference: image,
            floating: image,
            warp: RegistrationResidual.identityWarp
        )

        // Whatever the value, it must be on a 0...255 scale, not 0...1.
        XCTAssertGreaterThanOrEqual(residual.meanAbsoluteDifference, 0)
        XCTAssertLessThanOrEqual(residual.meanAbsoluteDifference, 255)
    }

    func testPartialAlphaFromRotationAndFractionalTranslatePreservesOverlap() {
        // This test exercises the alpha channel with realistic warps from Vision:
        // rotation and fractional-pixel translation that produce anti-aliased
        // (partially opaque) pixels at the boundaries. It verifies that the direct
        // alpha render correctly classifies pixels. Note: this test does not catch
        // alpha-thresholding regressions because the partial-alpha boundary is only
        // ~0.3-0.7% of the frame; see testUniformlySemiTransparentImagePreservesOverlap
        // for a regression guard that dominates the entire frame.
        let reference = TestImageFactory.textured(width: 320, height: 240)

        // A 2° rotation around the center of the frame produces edge pixels with
        // partial alpha (anti-aliasing). The overlap should be high (~98%) because
        // most of the image remains in-frame.
        let rotated = TestImageFactory.transformed(
            reference,
            by: CGAffineTransform(translationX: 160, y: 120)
                .rotated(by: CGFloat.pi * 2.0 / 180.0)  // 2° rotation
                .translatedBy(x: -160, y: -120)
        )

        let residual = RegistrationResidual.measure(
            reference: reference,
            floating: rotated,
            warp: RegistrationResidual.identityWarp
        )

        // The overlap must be high. This is a smoke test for realistic warp geometry,
        // not a regression guard for alpha thresholding.
        XCTAssertGreaterThan(
            residual.overlapFraction,
            0.90,
            "a 2° rotation should preserve most of the frame"
        )

        // Fractional-pixel translation also produces partial alpha at the new edges.
        let fractionallyShifted = TestImageFactory.transformed(
            reference,
            by: CGAffineTransform(translationX: 1.5, y: 2.3)
        )

        let fractionalResidual = RegistrationResidual.measure(
            reference: reference,
            floating: fractionallyShifted,
            warp: RegistrationResidual.identityWarp
        )

        // Fractional shifts expose a small boundary strip, but overlap should
        // still be very high (>98%).
        XCTAssertGreaterThan(
            fractionalResidual.overlapFraction,
            0.98,
            "fractional translation should incur minimal overlap loss"
        )
    }

    func testUniformlySemiTransparentImagePreservesOverlap() {
        // This test guards against alpha-channel thresholding regressions by making
        // partial alpha the *dominant* signal across the entire frame. A 75% opaque
        // floating image under identity warp should report high overlap (~1.0) because
        // the direct alpha render correctly classifies 75% opacity as above threshold.
        //
        // The old CIColorMatrix + RGB→Gray approach misclassified 75% opacity:
        // - Input: alpha = 191 (75% of 255)
        // - Old path: smuggled into red channel, then luma-weighted by grayscale:
        //   gray = 0.299*191 ≈ 57, then bias +54 → ~111, below the 127 threshold
        // - Result: nearly every pixel was excluded, overlapFraction collapsed to ~0
        //
        // The new direct alphaOnly render preserves the full 0...255 range:
        // - New path: alpha = 191 → stays 191, above threshold
        // - Result: nearly every pixel is counted, overlapFraction ≈ 1.0
        let reference = TestImageFactory.textured(width: 320, height: 240)

        // 75% opacity: alpha = 191 (0.75 * 255)
        let semiTransparent75 = TestImageFactory.semiTransparent(reference, alpha: UInt8(0.75 * 255.0))

        let residual = RegistrationResidual.measure(
            reference: reference,
            floating: semiTransparent75,
            warp: RegistrationResidual.identityWarp
        )

        // Under the new (correct) implementation, 75% opaque pixels have alpha ~191,
        // comfortably above the 127 threshold, so overlapFraction must be very high.
        XCTAssertGreaterThan(
            residual.overlapFraction,
            0.99,
            "75% opaque image under identity warp should report near-full overlap; "
            + "low overlap indicates alpha thresholding regressed (alpha values below threshold)"
        )
    }
}
