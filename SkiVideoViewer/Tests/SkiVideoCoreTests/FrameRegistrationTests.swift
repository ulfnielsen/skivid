import CoreGraphics
import CoreImage
import XCTest
import simd
import SkiVideoCore
@testable import SkiVideoCore

/// A test-local stand-in for the worktree's `RegistrationResidual`, which
/// this port deliberately excludes from `SkiVideoCore` (it is validation
/// tooling for `RegistrationLab`/`OverlayExport`, not part of the detection
/// core). `testApplyingTheRecoveredWarpReducesTheResidual` below needs some
/// way to quantify "closer to aligned", so the measurement — not the
/// production type — is copied here, scoped to this file only.
private enum TestResidual {
    static let identityWarp = matrix_float3x3(1)

    static func meanAbsoluteDifference(
        reference: CGImage,
        floating: CGImage,
        warp: matrix_float3x3
    ) -> Double {
        let width = reference.width
        let height = reference.height
        let frame = CGRect(x: 0, y: 0, width: width, height: height)

        let transform = CGAffineTransform(
            a: CGFloat(warp.columns.0.x), b: CGFloat(warp.columns.0.y),
            c: CGFloat(warp.columns.1.x), d: CGFloat(warp.columns.1.y),
            tx: CGFloat(warp.columns.2.x), ty: CGFloat(warp.columns.2.y)
        )

        let warped = CIImage(cgImage: floating)
            .transformed(by: transform)
            .cropped(to: frame)

        guard
            let referenceGray = grayscaleBytes(from: CIImage(cgImage: reference), in: frame),
            let warpedGray = grayscaleBytes(from: warped, in: frame),
            let warpedAlpha = alphaBytes(from: warped, in: frame)
        else {
            return 255
        }

        var total = 0.0
        var counted = 0
        for index in 0..<(width * height) where warpedAlpha[index] > 127 {
            total += abs(Double(referenceGray[index]) - Double(warpedGray[index]))
            counted += 1
        }

        guard counted > 0 else { return 255 }
        return total / Double(counted)
    }

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    private static func grayscaleBytes(from image: CIImage, in frame: CGRect) -> [UInt8]? {
        guard let cgImage = context.createCGImage(image, from: frame) else { return nil }
        return bytesFromGrayscaleCGImage(cgImage)
    }

    private static func alphaBytes(from image: CIImage, in frame: CGRect) -> [UInt8]? {
        guard let cgImage = context.createCGImage(image, from: frame) else { return nil }
        return alphaFromCGImage(cgImage)
    }

    private static func bytesFromGrayscaleCGImage(_ cgImage: CGImage) -> [UInt8]? {
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &bytes, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }

    private static func alphaFromCGImage(_ cgImage: CGImage) -> [UInt8]? {
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &bytes, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }
}

final class FrameRegistrationTests: XCTestCase {
    private func makePair(
        _ transform: CGAffineTransform
    ) -> (reference: CGImage, floating: CGImage) {
        let reference = TestImageFactory.textured(width: 640, height: 480)
        let floating = TestImageFactory.transformed(reference, by: transform)
        return (reference, floating)
    }

    func testTranslationalRecoversAKnownShiftExactly() throws {
        let pair = makePair(CGAffineTransform(translationX: 17, y: 9))

        let result = try FrameRegistration.register(
            reference: pair.reference,
            floating: pair.floating,
            method: .translational
        )

        XCTAssertEqual(result.method, .translational)
        // `warp` is the transform that undoes the shift, so a floating image
        // displaced by (+17, +9) is realigned by (-17, -9).
        XCTAssertEqual(Double(result.warp.columns.2.x), -17, accuracy: 0.5)
        XCTAssertEqual(Double(result.warp.columns.2.y), -9, accuracy: 0.5)
    }

    func testHomographicRecoversAKnownShiftApproximately() throws {
        let pair = makePair(CGAffineTransform(translationX: 17, y: 9))

        let result = try FrameRegistration.register(
            reference: pair.reference,
            floating: pair.floating,
            method: .homographic
        )

        XCTAssertEqual(result.method, .homographic)
        // Inverted, as above. The tolerance stays wide because homographic
        // was measured landing ~4.5px off on this same easy pair.
        XCTAssertEqual(Double(result.warp.columns.2.x), -17, accuracy: 6)
        XCTAssertEqual(Double(result.warp.columns.2.y), -9, accuracy: 6)
    }

    func testHomographicRecoversRotationAndScale() throws {
        // Rotation and scale are what homography buys over translation.
        // Rotate 3 degrees about the origin and scale by 1.05.
        let radians = 3.0 * .pi / 180.0
        let transform = CGAffineTransform(rotationAngle: radians)
            .concatenating(CGAffineTransform(scaleX: 1.05, y: 1.05))
        let pair = makePair(transform)

        let result = try FrameRegistration.register(
            reference: pair.reference,
            floating: pair.floating,
            method: .homographic
        )

        // Inverted: a 1.05 scale becomes ~0.952.
        XCTAssertEqual(Double(result.warp.columns.0.x), 0.952, accuracy: 0.08)
        XCTAssertEqual(abs(Double(result.warp.columns.0.y)), 0.055, accuracy: 0.08)
        // Whatever it recovered, it must not be the identity — that would mean
        // it silently gave up rather than solving anything.
        let isIdentity = abs(Double(result.warp.columns.0.x) - 1) < 0.001
            && abs(Double(result.warp.columns.0.y)) < 0.001
        XCTAssertFalse(isIdentity, "homographic returned identity for a rotated pair")
    }

    func testIdenticalImagesGiveANearIdentityWarp() throws {
        let image = TestImageFactory.textured(width: 640, height: 480)

        let result = try FrameRegistration.register(
            reference: image,
            floating: image,
            method: .translational
        )

        XCTAssertEqual(Double(result.warp.columns.2.x), 0, accuracy: 0.5)
        XCTAssertEqual(Double(result.warp.columns.2.y), 0, accuracy: 0.5)
    }

    func testResultCarriesTimingAndConfidence() throws {
        let pair = makePair(CGAffineTransform(translationX: 5, y: 5))

        let result = try FrameRegistration.register(
            reference: pair.reference,
            floating: pair.floating,
            method: .translational
        )

        XCTAssertGreaterThan(result.duration, 0)
        // Vision was measured returning 1.0 even for badly registered pairs.
        // This asserts only that the value is carried through, not that it
        // means anything.
        XCTAssertGreaterThanOrEqual(result.visionConfidence, 0)
    }

    func testEveryMethodHasARawValueForReporting() {
        XCTAssertEqual(RegistrationMethod.translational.rawValue, "translational")
        XCTAssertEqual(RegistrationMethod.homographic.rawValue, "homographic")
        XCTAssertEqual(RegistrationMethod.allCases.count, 2)
    }

    func testApplyingTheRecoveredWarpReducesTheResidual() throws {
        let reference = TestImageFactory.textured(width: 640, height: 480)
        // Asymmetric on purpose: a symmetric shift would hide an x/y swap,
        // and a same-signed one would hide a single-axis sign error.
        let floating = TestImageFactory.transformed(
            reference,
            by: CGAffineTransform(translationX: 40, y: 17)
        )

        let before = TestResidual.meanAbsoluteDifference(
            reference: reference,
            floating: floating,
            warp: TestResidual.identityWarp
        )
        let result = try FrameRegistration.register(
            reference: reference,
            floating: floating,
            method: .translational
        )
        let after = TestResidual.meanAbsoluteDifference(
            reference: reference,
            floating: floating,
            warp: result.warp
        )

        XCTAssertLessThan(
            after,
            before,
            "applying the recovered warp must reduce the residual"
        )
        // Recovering an exact translation should land essentially on top of
        // the reference, not merely somewhat closer.
        XCTAssertLessThan(after, 1.0)
    }

    func testDegenerateWarpIsRejected() throws {
        // Construct a singular matrix by making the first two columns linearly
        // dependent (both are multiples of the same vector).
        let singular = matrix_float3x3(
            SIMD3<Float>(1, 2, 0),    // column 0
            SIMD3<Float>(2, 4, 0),    // column 1: 2x column 0
            SIMD3<Float>(0, 0, 1)     // column 2
        )

        XCTAssertThrowsError(
            try invertedWarp(singular),
            "singular matrix should throw degenerateWarp"
        ) { error in
            XCTAssertEqual(error as? RegistrationError, .degenerateWarp)
        }
    }

    func testInvertedWarpNormalisesH33() throws {
        // Verify that normalising h33 to 1 before inversion produces the same
        // result as inverting a matrix that was already normalised. This property
        // must hold: normalisation cannot change the inverse.
        //
        // Build M with h33 = 0.5 and a non-symmetric affine part.
        // Build N = M / 0.5 (already normalised to h33 = 1).
        // Invert both and verify they match. This fails loudly if normalisation
        // is removed, reversed, or applied to the wrong operand.
        //
        // Real clip pair produced h33 = 0.59; using 0.5 for clarity.

        // Non-symmetric affine part so transposition bugs cannot hide.
        let affineA = Float(1.05)
        let affineB = Float(0.055)
        let affineC = Float(-0.1)
        let affineD = Float(1.048)
        let tx = Float(17)
        let ty = Float(9)

        // Matrix with h33 = 0.5
        let m = matrix_float3x3(
            SIMD3<Float>(affineA, affineB, 0),
            SIMD3<Float>(affineC, affineD, 0),
            SIMD3<Float>(tx, ty, 0.5)
        )

        // Same matrix but already normalised: divide every element by 0.5.
        // This represents the same projective transform.
        let n = matrix_float3x3(
            SIMD3<Float>(affineA * 2, affineB * 2, 0),
            SIMD3<Float>(affineC * 2, affineD * 2, 0),
            SIMD3<Float>(tx * 2, ty * 2, 1)
        )

        let resultFromM = try invertedWarp(m)
        let resultFromN = try invertedWarp(n)

        // Both results should be identical. The normalisation ensures that
        // inverting m (with h33 = 0.5) produces the same result as inverting
        // n (with h33 = 1), because they represent the same transform.
        // Tolerance is tight: 1e-5 is well within floating-point precision
        // for these operations.
        XCTAssertEqual(
            Double(resultFromM.columns.0.x),
            Double(resultFromN.columns.0.x),
            accuracy: 1e-5,
            "affine a should match"
        )
        XCTAssertEqual(
            Double(resultFromM.columns.0.y),
            Double(resultFromN.columns.0.y),
            accuracy: 1e-5,
            "affine b should match"
        )
        XCTAssertEqual(
            Double(resultFromM.columns.1.x),
            Double(resultFromN.columns.1.x),
            accuracy: 1e-5,
            "affine c should match"
        )
        XCTAssertEqual(
            Double(resultFromM.columns.1.y),
            Double(resultFromN.columns.1.y),
            accuracy: 1e-5,
            "affine d should match"
        )
        XCTAssertEqual(
            Double(resultFromM.columns.2.x),
            Double(resultFromN.columns.2.x),
            accuracy: 1e-5,
            "translation x should match"
        )
        XCTAssertEqual(
            Double(resultFromM.columns.2.y),
            Double(resultFromN.columns.2.y),
            accuracy: 1e-5,
            "translation y should match"
        )
    }
}
