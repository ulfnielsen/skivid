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
            version: AlignmentTrack.currentVersion,
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

    /// A track written before the y-axis convention was fixed must be refused,
    /// not adapted and not used.
    ///
    /// Version 1 stored `dy` in Vision's bottom-left, y-up space. Applied by a
    /// reader expecting top-left, y-down, it moves the floating clip the wrong
    /// way — pushing the pair apart by exactly the distance it should have
    /// closed. Measured in the running app before the fix: a shared banner went
    /// from ~100pt apart at `dy = 0` to ~205pt at `dy = -0.0656`.
    ///
    /// Nothing on screen would say so, which is why this refuses rather than
    /// migrating: a wrong number that looks like an answer is worse than no
    /// answer, and recomputing costs fifteen seconds.
    func testATrackFromTheOlderConventionIsRefused() throws {
        let left = directory.appendingPathComponent("C0094.MP4")
        let right = directory.appendingPathComponent("C0092.MP4")
        try AlignmentTrackStore.save(track(), left: left, right: right)

        // Rewrite the stored version as 1, leaving everything else intact — the
        // file a build from before the fix would have produced.
        let url = AlignmentTrackStore.sidecarURL(left: left, right: right)
        let original = try String(contentsOf: url, encoding: .utf8)
        let downgraded = original.replacingOccurrences(
            of: "\"version\" : \(AlignmentTrack.currentVersion)",
            with: "\"version\" : 1"
        )
        XCTAssertNotEqual(downgraded, original, "the downgrade did not apply")
        try Data(downgraded.utf8).write(to: url)

        XCTAssertNil(
            AlignmentTrackStore.load(left: left, right: right),
            "a version 1 track loaded; its dy is inverted and would misalign silently"
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

    // MARK: - Identity-keyed pairs

    private func withTemporaryKeyedStore(_ body: (URL) throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let previous = ClipIdentity.keyedStoreRoot
        ClipIdentity.keyedStoreRoot = root
        defer {
            ClipIdentity.keyedStoreRoot = previous
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }

    // `withTemporaryKeyedStore` is `rethrows`, so a test whose closure calls
    // nothing throwing must omit both `try` and `throws` — otherwise the
    // compiler warns "no calls to throwing functions occur within 'try'".
    func testRemotePairLivesInTheKeyedStoreNamedFromBothSides() {
        withTemporaryKeyedStore { root in
            let url = AlignmentTrackStore.sidecarURL(
                left: .remote(provider: "gdrive", fileID: "L"),
                right: .remote(provider: "gdrive", fileID: "R")
            )
            XCTAssertEqual(url.deletingLastPathComponent().path, root.path)
            XCTAssertEqual(url.lastPathComponent, "gdrive-L--gdrive-R.skialignment.json")
        }
    }

    /// A coach can compare a cloud clip against one on disk. That pair has no
    /// business beside the local clip — the track would be orphaned the moment
    /// the folder moved, and half of it describes a file that folder never
    /// held.
    func testMixedPairGoesToTheKeyedStoreRatherThanBesideTheLocalClip() {
        withTemporaryKeyedStore { root in
            let url = AlignmentTrackStore.sidecarURL(
                left: ClipIdentity(directory.appendingPathComponent("C0094.MP4")),
                right: .remote(provider: "gdrive", fileID: "R")
            )
            XCTAssertEqual(url.deletingLastPathComponent().path, root.path)
        }
    }

    /// Two local clips whose paths differ only by characters that a lossy
    /// escaping would fold together must not name the same sidecar. Paired
    /// against the same remote clip they both land in the keyed store, and a
    /// collision there means one coach's alignment silently overwrites
    /// another's — no error, no warning, just the wrong track.
    func testLocalPathsThatFoldAlikeDoNotShareAKeyedSidecar() {
        withTemporaryKeyedStore { _ in
            let remote = ClipIdentity.remote(provider: "gdrive", fileID: "R")
            let spaced = ClipIdentity(URL(fileURLWithPath: "/Ski Team 2026/run.mp4"))
            let scored = ClipIdentity(URL(fileURLWithPath: "/Ski_Team_2026/run.mp4"))
            XCTAssertNotEqual(
                AlignmentTrackStore.sidecarURL(left: spaced, right: remote),
                AlignmentTrackStore.sidecarURL(left: scored, right: remote)
            )
        }
    }

    /// A path deep enough that escaping it whole would breach the 255-byte
    /// limit on a filename component must still produce a usable name.
    func testADeepLocalPathStillProducesAUsableFilename() {
        withTemporaryKeyedStore { _ in
            let deep = ClipIdentity(URL(fileURLWithPath:
                "/" + Array(repeating: "averylongfoldername", count: 40).joined(separator: "/")
                    + "/run.mp4"))
            let url = AlignmentTrackStore.sidecarURL(
                left: deep, right: .remote(provider: "gdrive", fileID: "R")
            )
            XCTAssertLessThan(url.lastPathComponent.utf8.count, 255)
        }
    }

    func testRemotePairRoundTrips() throws {
        try withTemporaryKeyedStore { _ in
            let left = ClipIdentity.remote(provider: "gdrive", fileID: "L")
            let right = ClipIdentity.remote(provider: "gdrive", fileID: "R")
            try AlignmentTrackStore.save(track(), left: left, right: right)
            XCTAssertEqual(
                AlignmentTrackStore.load(left: left, right: right)?.samples.count, 2
            )
        }
    }

    /// Left and right are not interchangeable — the track describes a shift
    /// *from* one *to* the other — so the reversed pair must be a different
    /// sidecar, exactly as it is for two local clips.
    func testReversedRemotePairIsADifferentTrack() throws {
        try withTemporaryKeyedStore { _ in
            let left = ClipIdentity.remote(provider: "gdrive", fileID: "L")
            let right = ClipIdentity.remote(provider: "gdrive", fileID: "R")
            try AlignmentTrackStore.save(track(), left: left, right: right)
            XCTAssertNil(AlignmentTrackStore.load(left: right, right: left))
        }
    }

    func testTwoLocalIdentitiesResolveToTheSameSidecarAsTheURLAPI() {
        let left = directory.appendingPathComponent("C0094.MP4")
        let right = directory.appendingPathComponent("C0092.MP4")
        XCTAssertEqual(
            AlignmentTrackStore.sidecarURL(
                left: ClipIdentity(left), right: ClipIdentity(right)
            ),
            AlignmentTrackStore.sidecarURL(left: left, right: right)
        )
    }
}
