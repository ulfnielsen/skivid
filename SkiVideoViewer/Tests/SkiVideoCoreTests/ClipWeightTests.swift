import XCTest
@testable import SkiVideoCore

/// The "too big to fetch" rule, as pure arithmetic.
///
/// No network and no media on purpose: every claim here is about numbers, and
/// the cost of getting it wrong is either a 400MB download the operator did not
/// want or a clip they cannot open at all. Both deserve exhaustive cheap tests.
final class ClipWeightTests: XCTestCase {
    /// 1920 × 1080 × 1.784 ≈ 3.70 Mbps; the bar is twice that.
    private let hdTargetBitsPerSecond = 1920.0 * 1080.0 * 1.784

    private func size(forBitrate bitsPerSecond: Double, seconds: Double) -> Int64 {
        Int64((bitsPerSecond * seconds / 8).rounded())
    }

    func testAClipAtThePipelinesOwnBitrateIsFine() {
        let verdict = ClipWeight.verdict(
            width: 1920, height: 1080, durationMillis: 30_000,
            size: size(forBitrate: hdTargetBitsPerSecond, seconds: 30)
        )
        XCTAssertFalse(verdict.isTooLarge)
        XCTAssertNil(verdict.explanation)
    }

    /// The observed case: 400MB of 1080p footage that is seconds long.
    func testTheReportedFourHundredMegabyteClipIsFlagged() {
        let verdict = ClipWeight.verdict(
            width: 1920, height: 1080, durationMillis: 30_000, size: 400 * 1_000_000
        )
        XCTAssertTrue(verdict.isTooLarge)
        XCTAssertNotNil(verdict.explanation)
    }

    /// 2× leaves room for ordinary encoder variation, so just-above-target is
    /// deliberately left alone — flagging it would make the feature fire on
    /// clips nobody would call excessive.
    func testJustUnderTwiceTheTargetIsNotFlagged() {
        let verdict = ClipWeight.verdict(
            width: 1920, height: 1080, durationMillis: 10_000,
            size: size(forBitrate: hdTargetBitsPerSecond * 1.98, seconds: 10)
        )
        XCTAssertFalse(verdict.isTooLarge)
    }

    func testJustOverTwiceTheTargetIsFlagged() {
        let verdict = ClipWeight.verdict(
            width: 1920, height: 1080, durationMillis: 10_000,
            size: size(forBitrate: hdTargetBitsPerSecond * 2.02, seconds: 10)
        )
        XCTAssertTrue(verdict.isTooLarge)
    }

    /// The pipeline downscales anything above 1080p, so the extra pixels can
    /// never be seen — a well-compressed 4K clip still costs more to fetch than
    /// it can show.
    func testFourKIsFlaggedEvenAtAModestBitrate() {
        let verdict = ClipWeight.verdict(
            width: 3840, height: 2160, durationMillis: 30_000,
            size: size(forBitrate: 8_000_000, seconds: 30)
        )
        XCTAssertTrue(verdict.isTooLarge)
    }

    func testAClipTallerThanTenEightyIsFlagged() {
        let verdict = ClipWeight.verdict(
            width: 1080, height: 1920, durationMillis: 30_000,
            size: size(forBitrate: 3_000_000, seconds: 30)
        )
        XCTAssertTrue(verdict.isTooLarge, "portrait 1080×1920 exceeds the 1080 height bound")
    }

    /// Length alone is never a reason. At the target bitrate a 1080p clip only
    /// reaches 400MB at about 14 minutes, and a correctly encoded long clip is
    /// not the problem this rule exists for.
    func testALongClipAtTheTargetBitrateIsNotFlagged() {
        let verdict = ClipWeight.verdict(
            width: 1920, height: 1080, durationMillis: 20 * 60_000,
            size: size(forBitrate: hdTargetBitsPerSecond, seconds: 20 * 60)
        )
        XCTAssertFalse(verdict.isTooLarge)
    }

    // MARK: - Absent and degenerate metadata

    /// Drive fills `videoMediaMetadata` in asynchronously after an upload, so a
    /// clip added minutes ago carries none. Refusing what cannot be measured
    /// would strike hardest exactly when a coach has just uploaded footage.
    func testMissingMetadataIsNeverFlagged() {
        for verdict in [
            ClipWeight.verdict(width: nil, height: 1080, durationMillis: 30_000, size: 400_000_000),
            ClipWeight.verdict(width: 1920, height: nil, durationMillis: 30_000, size: 400_000_000),
            ClipWeight.verdict(width: 1920, height: 1080, durationMillis: nil, size: 400_000_000),
        ] {
            XCTAssertFalse(verdict.isTooLarge)
            XCTAssertNil(verdict.explanation)
        }
    }

    /// A zero duration would divide by zero and a zero dimension would make the
    /// target bitrate zero, so every clip would flag. Both mean "Drive told us
    /// something useless", which is the missing-metadata case.
    func testZeroDurationOrDimensionIsNeverFlagged() {
        XCTAssertFalse(
            ClipWeight.verdict(width: 1920, height: 1080, durationMillis: 0, size: 400_000_000).isTooLarge
        )
        XCTAssertFalse(
            ClipWeight.verdict(width: 0, height: 0, durationMillis: 30_000, size: 400_000_000).isTooLarge
        )
    }

    func testANegativeOrZeroSizeIsNeverFlagged() {
        XCTAssertFalse(
            ClipWeight.verdict(width: 1920, height: 1080, durationMillis: 30_000, size: 0).isTooLarge
        )
    }

    // MARK: - The explanation

    /// The operator is being refused a download, so the message has to carry
    /// the numbers that justify it — "too big" alone gives them nothing to act
    /// on or to disagree with.
    func testTheExplanationNamesTheSizeAndHowFarOverItIs() throws {
        let verdict = ClipWeight.verdict(
            width: 1920, height: 1080, durationMillis: 30_000, size: 400 * 1_000_000
        )
        let explanation = try XCTUnwrap(verdict.explanation)
        XCTAssertTrue(explanation.contains("400"), explanation)
        XCTAssertTrue(explanation.contains("×"), explanation)
    }

    func testTheExplanationForAnOversizedResolutionSaysSo() throws {
        let verdict = ClipWeight.verdict(
            width: 3840, height: 2160, durationMillis: 30_000,
            size: size(forBitrate: 8_000_000, seconds: 30)
        )
        let explanation = try XCTUnwrap(verdict.explanation)
        XCTAssertTrue(explanation.contains("3840"), explanation)
    }
}
