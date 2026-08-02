import CoreGraphics
import XCTest
@testable import SkiVideoCore

final class AlignmentTrackTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func track(leftStart: TimeInterval = 18.56) -> AlignmentTrack {
        AlignmentTrack(
            version: 1,
            computedAt: Date(timeIntervalSince1970: 1_754_140_000),
            leftClip: "C0094.MP4", rightClip: "C0092.MP4",
            leftStart: leftStart, rightStart: 4.40,
            parameters: .current,
            samples: [
                AlignmentSample(
                    time: 0.0, translation: CGVector(dx: 0.031, dy: -0.017),
                    overlap: 0.913, residual: 5.04, identityResidual: 9.63
                ),
                AlignmentSample(
                    time: 0.5, translation: CGVector(dx: 0.036, dy: -0.021),
                    overlap: 0.854, residual: 5.17, identityResidual: 11.66
                ),
            ]
        )
    }

    func testRoundTrips() throws {
        let decoded = try JSONDecoder().decode(
            AlignmentTrack.self, from: JSONEncoder().encode(track())
        )
        XCTAssertEqual(decoded.samples.count, 2)
        XCTAssertEqual(decoded.samples[1].translation.dx, 0.036, accuracy: 1e-9)
        XCTAssertEqual(decoded.samples[0].overlap, 0.913, accuracy: 1e-9)
        XCTAssertEqual(decoded.rightStart, 4.40, accuracy: 1e-9)
    }

    func testTheSidecarNamesBothClipsAndSitsBesideTheLeftOne() {
        let left = directory.appendingPathComponent("C0094.MP4")
        let right = directory.appendingPathComponent("sub/C0092.MP4")
        let url = AlignmentTrackStore.sidecarURL(left: left, right: right)

        XCTAssertEqual(url.lastPathComponent, "C0094--C0092.skialignment.json")
        XCTAssertEqual(url.deletingLastPathComponent().path, directory.path)
    }

    func testSaveThenLoadRoundTrips() throws {
        let left = directory.appendingPathComponent("C0094.MP4")
        let right = directory.appendingPathComponent("C0092.MP4")
        try AlignmentTrackStore.save(track(), left: left, right: right)

        XCTAssertEqual(
            AlignmentTrackStore.load(left: left, right: right)?.samples.count, 2
        )
    }

    func testATrackComputedForDifferentRunStartsIsStale() {
        // A track describes one comparison. Re-picking the subject moves the
        // run start, and every translation in the file then refers to a pairing
        // of frames that no longer happens.
        XCTAssertTrue(
            track(leftStart: 12.0).isStale(leftStart: 18.56, rightStart: 4.40)
        )
        XCTAssertFalse(
            track().isStale(leftStart: 18.56, rightStart: 4.40)
        )
    }

    func testStalenessSurvivesFloatingPointNoiseInTheStarts() {
        // The starts come back through JSON and through a detector that reports
        // to two decimals; an exact-equality check would call every reloaded
        // track stale and recompute a 15-second pass on every open.
        XCTAssertFalse(
            track().isStale(leftStart: 18.560000001, rightStart: 4.4)
        )
    }
}
