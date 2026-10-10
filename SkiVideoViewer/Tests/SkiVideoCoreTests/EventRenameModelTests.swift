import XCTest
@testable import SkiVideoCore

@MainActor
final class EventRenameModelTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func file(_ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: url)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    func testARenameMovesEveryAthletesClips() async throws {
        try file("Anna/2026-02-14_Hochybrig/IMG_1.mov")
        try file("Bo/2026-02-14_Hochybrig/IMG_2.mov")
        let model = EventRenameModel(
            oldName: "2026-02-14_Hochybrig",
            eventFolders: [["Anna", "2026-02-14_Hochybrig"], ["Bo", "2026-02-14_Hochybrig"]],
            folders: LocalEventFolders(root: root))
        let ok = await model.run(newName: "2026-02-14_Hoch-Ybrig")
        XCTAssertTrue(ok)
        XCTAssertTrue(exists("Anna/2026-02-14_Hoch-Ybrig/IMG_1.mov"))
        XCTAssertTrue(exists("Bo/2026-02-14_Hoch-Ybrig/IMG_2.mov"))
        XCTAssertEqual(model.done, 2)
        XCTAssertEqual(model.total, 2)
    }

    /// Review Focus 3: stop partway, then try again.
    func testAStoppedRunFinishesOnTheSecondTryWithoutRepeatingWork() async throws {
        try file("Anna/2026-02-14_Hochybrig/IMG_1.mov")
        try file("Bo/2026-02-14_Hochybrig/IMG_2.mov")
        let flaky = FlakyFolders(LocalEventFolders(root: root), failRenamesAfter: 1)
        let model = EventRenameModel(
            oldName: "2026-02-14_Hochybrig",
            eventFolders: [["Anna", "2026-02-14_Hochybrig"], ["Bo", "2026-02-14_Hochybrig"]],
            folders: flaky)

        let first = await model.run(newName: "2026-02-14_Hoch-Ybrig")
        XCTAssertFalse(first)
        XCTAssertEqual(model.stopReason?.hasPrefix("Renamed 1 of 2"), true)
        XCTAssertTrue(exists("Anna/2026-02-14_Hoch-Ybrig/IMG_1.mov"))
        XCTAssertTrue(exists("Bo/2026-02-14_Hochybrig/IMG_2.mov"))

        flaky.heal()
        let second = await model.run(newName: "2026-02-14_Hoch-Ybrig")
        XCTAssertTrue(second)
        XCTAssertEqual(model.total, 1, "only the remaining athlete is renamed")
        XCTAssertTrue(exists("Bo/2026-02-14_Hoch-Ybrig/IMG_2.mov"))
        XCTAssertNil(model.stopReason)
    }

    func testNoEditAccessStopsAndSaysWhy() async throws {
        try file("2026-02-14_Hochybrig/Anna/IMG_1.mov")
        let model = EventRenameModel(
            oldName: "2026-02-14_Hochybrig", eventFolders: [["2026-02-14_Hochybrig"]],
            folders: RefusingFolders())
        let ok = await model.run(newName: "2026-02-14_Hoch-Ybrig")
        XCTAssertFalse(ok)
        XCTAssertEqual(model.stopReason, "You cannot edit this Drive.")
    }

    func testAMergeLeavesCollisionsAndBinsWhatEmptied() async throws {
        try file("2026-02-14_Hochybrig/Anna/IMG_1.mov")
        try file("2026-02-14_Hochybrig/Anna/IMG_2.mov")
        try file("2026-02-14_Hochybrig/Bo/IMG_3.mov")
        try file("2026-02-14_Hoch-Ybrig/Anna/IMG_1.mov")
        let model = EventRenameModel(
            oldName: "2026-02-14_Hochybrig", eventFolders: [["2026-02-14_Hochybrig"]],
            folders: LocalEventFolders(root: root))
        let merges = try await model.targetExists(newName: "2026-02-14_Hoch-Ybrig")
        XCTAssertTrue(merges)
        let ok = await model.run(newName: "2026-02-14_Hoch-Ybrig", allowMerge: true)
        XCTAssertTrue(ok)
        XCTAssertTrue(exists("2026-02-14_Hoch-Ybrig/Bo/IMG_3.mov"))
        XCTAssertFalse(exists("2026-02-14_Hochybrig/Bo"), "an athlete folder that emptied completely is gone")
        XCTAssertTrue(exists("2026-02-14_Hoch-Ybrig/Anna/IMG_2.mov"))
        XCTAssertTrue(exists("2026-02-14_Hochybrig/Anna/IMG_1.mov"), "the collision stays")
        XCTAssertEqual(model.leftInPlace, [["2026-02-14_Hochybrig", "Anna", "IMG_1.mov"]])
    }

    /// Final review: a clip iCloud has not downloaded sits as a hidden
    /// `.C0001.MP4.icloud`. Unseen, its visible analysis was moved alone and
    /// landed beside a *different* `C0001.MP4`, loading as that clip's.
    func testAnICloudPlaceholderClipKeepsItsSidecarBehindInAMerge() async throws {
        try file("2026-02-14_A/Anna/.C0001.MP4.icloud")
        try file("2026-02-14_A/Anna/C0001.skianalysis.json")
        try file("2026-02-14_B/Anna/C0001.MP4")
        let model = EventRenameModel(
            oldName: "2026-02-14_A", eventFolders: [["2026-02-14_A"]], folders: LocalEventFolders(root: root))
        let ok = await model.run(newName: "2026-02-14_B", allowMerge: true)
        XCTAssertTrue(ok)
        XCTAssertTrue(exists("2026-02-14_A/Anna/C0001.skianalysis.json"))
        XCTAssertFalse(exists("2026-02-14_B/Anna/C0001.skianalysis.json"))
        XCTAssertTrue(exists("2026-02-14_A/Anna/.C0001.MP4.icloud"))
        XCTAssertEqual(model.leftInPlace, [
            ["2026-02-14_A", "Anna", "C0001.MP4"],
            ["2026-02-14_A", "Anna", "C0001.skianalysis.json"],
        ])
    }

    /// Without a merge the folder itself is renamed, so the placeholder
    /// travels with it and iCloud keeps tracking the clip.
    func testAPlainRenameCarriesAnICloudPlaceholderWithTheFolder() async throws {
        try file("2026-02-14_A/Anna/.C0001.MP4.icloud")
        try file("2026-02-14_A/Anna/C0001.skianalysis.json")
        let model = EventRenameModel(
            oldName: "2026-02-14_A", eventFolders: [["2026-02-14_A"]], folders: LocalEventFolders(root: root))
        let ok = await model.run(newName: "2026-02-14_B")
        XCTAssertTrue(ok)
        XCTAssertTrue(exists("2026-02-14_B/Anna/.C0001.MP4.icloud"))
        XCTAssertTrue(exists("2026-02-14_B/Anna/C0001.skianalysis.json"))
        XCTAssertFalse(exists("2026-02-14_A"))
        XCTAssertEqual(model.leftInPlace, [])
    }

    /// A pair's alignment sidecar is named from both stems and sits beside
    /// the left clip. After a real merge — one athlete merged clip by clip,
    /// the other moved whole — the store must find it again from the clips'
    /// new places, or every alignment in a merged event is silently lost.
    func testALocalPairsAlignmentStillResolvesAfterAMerge() async throws {
        try file("2026-02-14_A/Anna/C0094.MP4")
        try file("2026-02-14_A/Bo/C0092.MP4")
        try file("2026-02-14_B/Anna/IMG_9.mov")
        let url = { (path: String) in self.root.appendingPathComponent(path) }
        let track = AlignmentTrack(
            version: AlignmentTrack.currentVersion,
            computedAt: Date(timeIntervalSince1970: 1_754_140_000),
            leftClip: "C0094.MP4", rightClip: "C0092.MP4",
            leftStart: 18.56, rightStart: 4.40, parameters: .current,
            samples: [AlignmentSample(time: 0, translation: CGVector(dx: 0.031, dy: -0.017),
                                      overlap: 0.913, residual: 5.04, identityResidual: 9.63)])
        try AlignmentTrackStore.save(track, left: url("2026-02-14_A/Anna/C0094.MP4"),
                                     right: url("2026-02-14_A/Bo/C0092.MP4"))
        let model = EventRenameModel(
            oldName: "2026-02-14_A", eventFolders: [["2026-02-14_A"]], folders: LocalEventFolders(root: root))
        let ok = await model.run(newName: "2026-02-14_B", allowMerge: true)
        XCTAssertTrue(ok)
        XCTAssertFalse(exists("2026-02-14_A"), "the merge emptied and removed the old event")
        let loaded = AlignmentTrackStore.load(left: url("2026-02-14_B/Anna/C0094.MP4"),
                                              right: url("2026-02-14_B/Bo/C0092.MP4"))
        XCTAssertEqual(loaded, track)
    }

    /// The target appeared after `targetExists` said no (on Drive the consent
    /// sheet sits in that window): the coach was never asked, so nothing moves.
    func testATargetThatAppearsAfterTheQuestionStopsBeforeMoving() async throws {
        try file("Anna/2026-02-14_Hochybrig/IMG_1.mov")
        let model = EventRenameModel(
            oldName: "2026-02-14_Hochybrig", eventFolders: [["Anna", "2026-02-14_Hochybrig"]],
            folders: LocalEventFolders(root: root))
        let merges = try await model.targetExists(newName: "2026-02-14_Hoch-Ybrig")
        XCTAssertFalse(merges)
        try file("Anna/2026-02-14_Hoch-Ybrig/IMG_9.mov")
        let ok = await model.run(newName: "2026-02-14_Hoch-Ybrig")
        XCTAssertFalse(ok)
        XCTAssertEqual(model.stopReason,
                       "\u{201C}2026-02-14_Hoch-Ybrig\u{201D} now exists \u{2014} choose Merge or another name.")
        XCTAssertTrue(exists("Anna/2026-02-14_Hochybrig/IMG_1.mov"))
        XCTAssertEqual(model.done, 0)
    }

    func testCancellationSaysHowFarItGot() async throws {
        try file("Anna/2026-02-14_Hochybrig/IMG_1.mov")
        for error in [CancellationError() as Error, URLError(.cancelled)] {
            let model = EventRenameModel(
                oldName: "2026-02-14_Hochybrig", eventFolders: [["Anna", "2026-02-14_Hochybrig"]],
                folders: ThrowingFolders(error))
            let ok = await model.run(newName: "2026-02-14_Hoch-Ybrig")
            XCTAssertFalse(ok)
            XCTAssertEqual(model.stopReason, "Stopped after 0 of 1. Rename again to finish.")
        }
    }

    func testBeingSignedOutAsksToSignInAgain() async throws {
        try file("Anna/2026-02-14_Hochybrig/IMG_1.mov")
        let model = EventRenameModel(
            oldName: "2026-02-14_Hochybrig", eventFolders: [["Anna", "2026-02-14_Hochybrig"]],
            folders: ThrowingFolders(RemoteLibraryError.notSignedIn))
        let ok = await model.run(newName: "2026-02-14_Hoch-Ybrig")
        XCTAssertFalse(ok)
        XCTAssertEqual(model.stopReason, "Sign in to Google Drive again, then try again.")
    }

    func testNoWriteAccessStopsWithoutRetryWording() async throws {
        try file("2026-02-14_Hochybrig/Anna/IMG_1.mov")
        let model = EventRenameModel(
            oldName: "2026-02-14_Hochybrig", eventFolders: [["2026-02-14_Hochybrig"]],
            folders: ThrowingFolders(RemoteUploadError.noWriteAccess))
        let ok = await model.run(newName: "2026-02-14_Hoch-Ybrig")
        XCTAssertFalse(ok)
        XCTAssertEqual(model.stopReason, "You don't have permission to change folders in this library.")
    }

    /// Drive's rate limit surfaces as `.retryClip`; it must read as progress
    /// plus a retry, not as a bare message.
    func testARateLimitSaysHowFarItGotAndToTryAgain() async throws {
        try file("Anna/2026-02-14_Hochybrig/IMG_1.mov")
        let model = EventRenameModel(
            oldName: "2026-02-14_Hochybrig", eventFolders: [["Anna", "2026-02-14_Hochybrig"]],
            folders: ThrowingFolders(RemoteUploadError.retryClip("Google Drive is busy \u{2014} try again shortly.")))
        let ok = await model.run(newName: "2026-02-14_Hoch-Ybrig")
        XCTAssertFalse(ok)
        XCTAssertEqual(model.stopReason, "Renamed 0 of 1. Google Drive is busy \u{2014} try again shortly. Try again.")
    }

    /// A file that lands in the target between planning and moving makes the
    /// move stop rather than overwrite; the second run re-plans and leaves it.
    func testACollisionAppearingAfterPlanningStopsThenIsLeftInPlace() async throws {
        try file("2026-02-14_Hochybrig/Anna/IMG_1.mov")
        try file("2026-02-14_Hochybrig/Anna/IMG_2.mov")
        try file("2026-02-14_Hoch-Ybrig/Anna/IMG_1.mov")
        let target = root.appendingPathComponent("2026-02-14_Hoch-Ybrig/Anna/IMG_2.mov")
        let racing = CollidingFolders(LocalEventFolders(root: root)) {
            try? Data([9]).write(to: target)
        }
        let model = EventRenameModel(
            oldName: "2026-02-14_Hochybrig", eventFolders: [["2026-02-14_Hochybrig"]], folders: racing)

        let first = await model.run(newName: "2026-02-14_Hoch-Ybrig", allowMerge: true)
        XCTAssertFalse(first)
        XCTAssertEqual(model.stopReason?.contains("already in the target"), true)
        XCTAssertTrue(exists("2026-02-14_Hochybrig/Anna/IMG_2.mov"), "nothing was overwritten or lost")

        let second = await model.run(newName: "2026-02-14_Hoch-Ybrig", allowMerge: true)
        XCTAssertTrue(second)
        XCTAssertNil(model.stopReason)
        XCTAssertEqual(Set(model.leftInPlace), [
            ["2026-02-14_Hochybrig", "Anna", "IMG_1.mov"],
            ["2026-02-14_Hochybrig", "Anna", "IMG_2.mov"],
        ])
    }
}

/// Fails every rename after the first `n`, as a dropped signal would.
private final class FlakyFolders: EventFolderWriting, @unchecked Sendable {
    private let inner: LocalEventFolders
    private var remaining: Int
    init(_ inner: LocalEventFolders, failRenamesAfter n: Int) { self.inner = inner; remaining = n }
    func heal() { remaining = .max }
    func prepareToWrite() async throws {}
    func children(of path: [String]) async throws -> [FolderEntry]? { try await inner.children(of: path) }
    func rename(_ path: [String], to newName: String) async throws {
        guard remaining > 0 else { throw URLError(.networkConnectionLost) }
        remaining -= 1
        try await inner.rename(path, to: newName)
    }
    func move(_ name: String, from source: [String], to destination: [String]) async throws {
        try await inner.move(name, from: source, to: destination)
    }
    func removeIfEmpty(_ path: [String]) async throws -> Bool { try await inner.removeIfEmpty(path) }
}

private struct RefusingFolders: EventFolderWriting {
    func prepareToWrite() async throws { throw RemoteUploadError.stopBatch("You cannot edit this Drive.") }
    func children(of path: [String]) async throws -> [FolderEntry]? { [] }
    func rename(_ path: [String], to newName: String) async throws {}
    func move(_ name: String, from source: [String], to destination: [String]) async throws {}
    func removeIfEmpty(_ path: [String]) async throws -> Bool { false }
}

/// Throws `error` from the first write, as Drive's 403 handling would.
private struct ThrowingFolders: EventFolderWriting {
    let error: Error
    init(_ error: Error) { self.error = error }
    func prepareToWrite() async throws {}
    func children(of path: [String]) async throws -> [FolderEntry]? { [] }
    func rename(_ path: [String], to newName: String) async throws { throw error }
    func move(_ name: String, from source: [String], to destination: [String]) async throws { throw error }
    func removeIfEmpty(_ path: [String]) async throws -> Bool { false }
}

/// Runs a closure once, just before the first move, so a collision can
/// appear after the plan was made.
private final class CollidingFolders: EventFolderWriting, @unchecked Sendable {
    private let inner: LocalEventFolders
    private var pending: (() -> Void)?
    init(_ inner: LocalEventFolders, beforeFirstMove: @escaping () -> Void) {
        self.inner = inner; pending = beforeFirstMove
    }
    func prepareToWrite() async throws {}
    func children(of path: [String]) async throws -> [FolderEntry]? { try await inner.children(of: path) }
    func rename(_ path: [String], to newName: String) async throws { try await inner.rename(path, to: newName) }
    func move(_ name: String, from source: [String], to destination: [String]) async throws {
        if let run = pending { pending = nil; run() }
        try await inner.move(name, from: source, to: destination)
    }
    func removeIfEmpty(_ path: [String]) async throws -> Bool { try await inner.removeIfEmpty(path) }
}
