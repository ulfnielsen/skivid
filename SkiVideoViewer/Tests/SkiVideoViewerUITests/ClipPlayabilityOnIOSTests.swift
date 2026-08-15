import AVFoundation
import SkiVideoCore
import XCTest

/// Pins the one fact the "unsupported format" banner rests on: that iOS really
/// does refuse 10-bit 4:4:4 H.264, and that `ClipPlayability` notices.
///
/// **This cannot be a SwiftPM test.** Those run on macOS, whose decoder accepts
/// this format — the same file returns `isDecodable == true` there. That
/// difference is not incidental, it is the entire bug: the club's library plays
/// on the coach's Mac and is silent-with-sound on an iPad. Asserting it
/// anywhere but on an iOS runtime would assert the opposite of the truth.
///
/// The fixtures are ~1.9KB each, one per side of the line
/// `resize_video.py` draws (`982b761`, "Pin resize output to yuv420p so iOS
/// can decode it"), generated with:
///
///     ffmpeg -f lavfi -i "color=c=0x3A6EA5:size=160x120:rate=10:duration=1" \
///       -c:v libx264 -profile:v high444 -pix_fmt yuv444p10le  unsupported-444-10bit.mp4
///     ffmpeg -f lavfi -i "color=c=0x3A6EA5:size=160x120:rate=10:duration=1" \
///       -c:v libx264 -profile:v high    -pix_fmt yuv420p      supported-420-8bit.mp4
final class ClipPlayabilityOnIOSTests: XCTestCase {
    /// The format every clip resized before 2026-08-01 is in.
    ///
    /// Fails if `ClipPlayability` stops asking the decoder — in which case the
    /// banner never appears and a coach is back to sound over a blank frame
    /// with no explanation, which is where this whole diagnosis started.
    func testATenBitFourFourFourClipIsReportedUnplayable() async throws {
        let url = try fixture("unsupported-444-10bit")
        let message = await ClipPlayability.unsupportedVideoMessage(for: url)

        let reported = try XCTUnwrap(
            message,
            "iOS reported this clip decodable; if that is genuinely true on this "
                + "runtime the banner is unnecessary, but the club's library plays "
                + "silently on iPad, so verify before deleting this test"
        )
        XCTAssertTrue(
            reported.contains("10-bit 4:4:4"),
            "the message should name the format so it is actionable, got: \(reported)"
        )
    }

    /// The other direction, and it is what stops the banner appearing over
    /// every clip in the library. A check that always reported "unsupported"
    /// would pass the test above on its own.
    func testAnEightBitFourTwoZeroClipIsReportedFine() async throws {
        let url = try fixture("supported-420-8bit")
        let message = await ClipPlayability.unsupportedVideoMessage(for: url)
        XCTAssertNil(message, "a clip iOS can decode must not be flagged; got: \(message ?? "")")
    }

    /// A file with no video track at all is not this type's business, and must
    /// not be reported as a format problem — that would put a misleading
    /// explanation in front of a genuinely different failure.
    func testAFileWithNoVideoTrackIsNotFlagged() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-video-\(UUID().uuidString).mp4")
        try Data("this is not a video".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let message = await ClipPlayability.unsupportedVideoMessage(for: url)
        XCTAssertNil(message, "an unreadable file is not an unsupported format")
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "mp4"),
            "fixture \(name).mp4 is not in the test bundle — check it is still under "
                + "Tests/SkiVideoViewerUITests/Fixtures and that project.yml includes it"
        )
    }
}
