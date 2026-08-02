import CoreGraphics
import ImageIO
import XCTest
@testable import SkiVideoCore

final class SegmentThumbnailsTests: XCTestCase {
    /// A 200x120 image whose top-left quadrant is white and everything else
    /// black. Asymmetric in both axes, so a crop that is mirrored, transposed
    /// or offset lands somewhere measurably different.
    private func markedImage() -> CGImage {
        let width = 200, height = 120
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<40 {
            for x in 0..<60 { bytes[y * width + x] = 255 }
        }
        let context = CGContext(
            data: &bytes, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        return context.makeImage()!
    }

    private func meanLuma(of image: CGImage) -> Double {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height)
        let context = CGContext(
            data: &bytes, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes.reduce(0.0) { $0 + Double($1) } / Double(bytes.count)
    }

    func testCroppingRectUsesATopLeftOrigin() {
        let image = markedImage()
        // A box in the top-left eighth: normalised y 0.0 means the TOP.
        let rect = SegmentThumbnails.croppingRect(
            CGRect(x: 0.1, y: 0.05, width: 0.2, height: 0.25), in: image
        )

        XCTAssertEqual(rect.minX, 20, accuracy: 1e-9)
        XCTAssertEqual(rect.minY, 6, accuracy: 1e-9)
        XCTAssertEqual(rect.width, 40, accuracy: 1e-9)
        XCTAssertEqual(rect.height, 30, accuracy: 1e-9)
    }

    func testCropTakesTheRegionTheBoxNamesAndNotItsMirror() {
        // This is the test that would have caught the shipped bug: a
        // bottom-left-origin rect passed to `cropping(to:)` mirrors the crop
        // about the frame centre, and on snow the mirrored result still looks
        // like a photograph. The marked image makes the two distinguishable —
        // the named region is white, its mirror is black.
        let image = markedImage()
        let inTheWhite = CGRect(x: 0.05, y: 0.05, width: 0.2, height: 0.2)

        let cropped = SegmentThumbnails.crop(image, to: inTheWhite, padding: 1.0)

        XCTAssertNotNil(cropped)
        XCTAssertGreaterThan(meanLuma(of: cropped!), 200)
    }

    func testCropPadsAroundTheBoxWithoutLeavingTheFrame() {
        let image = markedImage()
        // Hard against the left edge: 1.6x padding would run negative.
        let cropped = SegmentThumbnails.crop(
            image, to: CGRect(x: 0.0, y: 0.3, width: 0.15, height: 0.4), padding: 1.6
        )

        XCTAssertNotNil(cropped)
        XCTAssertLessThanOrEqual(cropped!.width, image.width)
        XCTAssertLessThanOrEqual(cropped!.height, image.height)
        // Padded, so wider than the unpadded 30px, but clamped at the edge.
        XCTAssertGreaterThan(cropped!.width, 30)
    }

    func testCropRefusesABoxTooSmallToShow() {
        XCTAssertNil(
            SegmentThumbnails.crop(
                markedImage(),
                to: CGRect(x: 0.5, y: 0.5, width: 0.001, height: 0.001),
                padding: 1.0
            )
        )
    }

    // MARK: - Real footage

    private static let clip = URL(fileURLWithPath:
        "/Users/ulfnielsen/Ski/Neuss2026/organized/2026-07-19_Neuss/Idun Nielsen/C0094.MP4")

    /// Renders strips for the largest segments of a real clip and checks they
    /// carry actual picture rather than a flat fill.
    ///
    /// A blank thumbnail is the failure mode worth guarding: it has happened
    /// twice in this project — once from a silently-zeroing bitmap render, once
    /// from a mirrored crop landing on empty snow — and in both cases the code
    /// reported success. Contrast, not mere non-nil-ness, is what distinguishes
    /// a picture from a fill.
    func testRendersLegibleStripsFromRealFootage() async throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.clip.path),
            "ground-truth footage not present on this machine"
        )
        let analysis = try await SubjectAnalyzer.analyse(clip: Self.clip)
        let biggest = analysis.segments.prefix(4)
        XCTAssertGreaterThanOrEqual(biggest.count, 3)

        let directory = URL(fileURLWithPath: "/tmp/thumbtest", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )

        for segment in biggest {
            let strip = try SegmentThumbnails.strip(clip: Self.clip, segment: segment)
            XCTAssertNotNil(strip, "segment \(segment.id) rendered no strip")
            guard let strip else { continue }

            XCTAssertEqual(strip.width, 72 * 2 * segment.previews.count)
            XCTAssertGreaterThan(
                contrast(of: strip), 20.0,
                "segment \(segment.id)'s strip is flat — a fill, not a picture"
            )
            writePNG(strip, to: directory.appendingPathComponent("C0094-seg\(segment.id).png"))
        }
    }

    /// Standard deviation of luma. A solid fill scores 0; a photograph of a
    /// skier on snow scores tens.
    private func contrast(of image: CGImage) -> Double {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height)
        let context = CGContext(
            data: &bytes, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let mean = bytes.reduce(0.0) { $0 + Double($1) } / Double(bytes.count)
        let variance = bytes.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(bytes.count)
        return variance.squareRoot()
    }

    private func writePNG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
