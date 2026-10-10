import XCTest
@testable import SkiVideoCore

/// Plans read the live folders, so every test builds a real directory and
/// plans through `LocalEventFolders`.
final class EventRenamePlanTests: XCTestCase {
    private var root: URL!
    private var folders: LocalEventFolders!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        folders = LocalEventFolders(root: root)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func file(_ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: url)
    }

    func testEventFirstWithNoTargetIsOneRename() async throws {
        try file("2026-02-14_Hochybrig/Anna/IMG_1.mov")
        let plan = try await EventRenamePlanner.plan(
            eventFolders: [["2026-02-14_Hochybrig"]], newName: "2026-02-14_Hoch-Ybrig", in: folders)
        XCTAssertEqual(plan.steps, [.rename(["2026-02-14_Hochybrig"], to: "2026-02-14_Hoch-Ybrig")])
        XCTAssertFalse(plan.mergesIntoExisting)
    }

    func testAthleteFirstRenamesUnderEveryAthlete() async throws {
        try file("Anna/2026-02-14_Hochybrig/IMG_1.mov")
        try file("Bo/2026-02-14_Hochybrig/IMG_2.mov")
        let plan = try await EventRenamePlanner.plan(
            eventFolders: [["Anna", "2026-02-14_Hochybrig"], ["Bo", "2026-02-14_Hochybrig"]],
            newName: "2026-02-14_Hoch-Ybrig", in: folders)
        XCTAssertEqual(plan.steps, [
            .rename(["Anna", "2026-02-14_Hochybrig"], to: "2026-02-14_Hoch-Ybrig"),
            .rename(["Bo", "2026-02-14_Hochybrig"], to: "2026-02-14_Hoch-Ybrig"),
        ])
    }

    func testMergeMovesNewAthletesWholeAndMergesSharedOnesClipByClip() async throws {
        try file("2026-02-14_Hochybrig/Anna/IMG_1.mov")
        try file("2026-02-14_Hochybrig/Bo/IMG_2.mov")
        try file("2026-02-14_Hoch-Ybrig/Anna/IMG_9.mov")
        let plan = try await EventRenamePlanner.plan(
            eventFolders: [["2026-02-14_Hochybrig"]], newName: "2026-02-14_Hoch-Ybrig", in: folders)
        XCTAssertTrue(plan.mergesIntoExisting)
        XCTAssertEqual(plan.steps, [
            .move("IMG_1.mov", from: ["2026-02-14_Hochybrig", "Anna"], to: ["2026-02-14_Hoch-Ybrig", "Anna"]),
            .removeIfEmpty(["2026-02-14_Hochybrig", "Anna"]),
            .move("Bo", from: ["2026-02-14_Hochybrig"], to: ["2026-02-14_Hoch-Ybrig"]),
            .removeIfEmpty(["2026-02-14_Hochybrig"]),
        ])
        XCTAssertEqual(plan.leftInPlace, [])
    }

    /// Review Focus 2: a clip that stays keeps its sidecars with it.
    func testACollidingClipStaysWithItsSidecars() async throws {
        try file("2026-02-14_Hochybrig/Anna/IMG_1.mov")
        try file("2026-02-14_Hochybrig/Anna/IMG_1.skianalysis.json")
        try file("2026-02-14_Hochybrig/Anna/IMG_1--IMG_7.skialignment.json")
        try file("2026-02-14_Hochybrig/Anna/IMG_2.mov")
        try file("2026-02-14_Hochybrig/Anna/IMG_2.skianalysis.json")
        try file("2026-02-14_Hoch-Ybrig/Anna/IMG_1.mov")
        let plan = try await EventRenamePlanner.plan(
            eventFolders: [["2026-02-14_Hochybrig"]], newName: "2026-02-14_Hoch-Ybrig", in: folders)
        let moved = plan.steps.compactMap { step -> String? in
            if case let .move(name, _, _) = step { return name }
            return nil
        }
        XCTAssertEqual(Set(moved), ["IMG_2.mov", "IMG_2.skianalysis.json"])
        XCTAssertEqual(Set(plan.leftInPlace.map { $0.last! }),
                       ["IMG_1.mov", "IMG_1.skianalysis.json", "IMG_1--IMG_7.skialignment.json"])
    }

    /// Two spellings of one sidebar event side by side under one parent:
    /// the first renames, the second merges into what the first became. On
    /// Drive the siblings can differ by case; APFS (case-insensitive) cannot
    /// hold `hochybrig` beside `Hochybrig`, so the fixture uses an accent
    /// variant, which APFS does hold and the sidebar's fold groups the same
    /// way. Not a "Merge?" — the coach renamed one event, and nothing by the
    /// new name existed.
    func testSiblingSpellingsOfOneEventRenameThenMerge() async throws {
        try file("2026-01-10_Zurs/Anna/IMG_1.mov")
        try file("2026-01-10_Zürs/Anna/IMG_2.mov")
        try file("2026-01-10_Zürs/Bo/IMG_3.mov")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2,
                       "precondition: the volume holds both spellings")
        let plan = try await EventRenamePlanner.plan(
            eventFolders: [["2026-01-10_Zurs"], ["2026-01-10_Zürs"]], newName: "2026-01-10_Zuers", in: folders)
        XCTAssertEqual(plan.steps, [
            .rename(["2026-01-10_Zurs"], to: "2026-01-10_Zuers"),
            .move("IMG_2.mov", from: ["2026-01-10_Zürs", "Anna"], to: ["2026-01-10_Zuers", "Anna"]),
            .removeIfEmpty(["2026-01-10_Zürs", "Anna"]),
            .move("Bo", from: ["2026-01-10_Zürs"], to: ["2026-01-10_Zuers"]),
            .removeIfEmpty(["2026-01-10_Zürs"]),
        ])
        XCTAssertFalse(plan.mergesIntoExisting)
    }

    /// The same, run for real: both spellings end up as one folder.
    @MainActor
    func testSiblingSpellingsOfOneEventEndAsOneFolder() async throws {
        try file("2026-01-10_Zurs/Anna/IMG_1.mov")
        try file("2026-01-10_Zürs/Anna/IMG_2.mov")
        try file("2026-01-10_Zürs/Bo/IMG_3.mov")
        let model = EventRenameModel(oldName: "2026-01-10_Zurs",
                                     eventFolders: [["2026-01-10_Zurs"], ["2026-01-10_Zürs"]],
                                     folders: folders)
        let ok = await model.run(newName: "2026-01-10_Zuers")
        XCTAssertTrue(ok, model.stopReason ?? "")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["2026-01-10_Zuers"])
        for path in ["Anna/IMG_1.mov", "Anna/IMG_2.mov", "Bo/IMG_3.mov"] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: root.appendingPathComponent("2026-01-10_Zuers/" + path).path), path)
        }
    }

    func testAFolderAlreadyRenamedPlansNothing() async throws {
        try file("2026-02-14_Hoch-Ybrig/Anna/IMG_1.mov")
        let plan = try await EventRenamePlanner.plan(
            eventFolders: [["2026-02-14_Hochybrig"]], newName: "2026-02-14_Hoch-Ybrig", in: folders)
        XCTAssertEqual(plan.steps, [])
    }

    private let old = "2026-02-14_Hochybrig"
    private let new = "2026-02-14_Hoch-Ybrig"

    private func plan(_ paths: [[String]]? = nil, to name: String? = nil) async throws -> EventRenamePlan {
        try await EventRenamePlanner.plan(eventFolders: paths ?? [[old]], newName: name ?? new, in: folders)
    }

    private func movedNames(_ plan: EventRenamePlan) -> Set<String> {
        Set(plan.steps.compactMap { step -> String? in
            if case let .move(name, _, _) = step { return name }
            return nil
        })
    }

    private func stayed(_ plan: EventRenamePlan) -> Set<String> { Set(plan.leftInPlace.map { $0.last! }) }

    /// Sidecars are keyed by stem, so a target sidecar of the same stem would
    /// be loaded by the moved clip in place of its own analysis.
    func testAClipStaysWhenTheTargetAlreadyHoldsASidecarOfItsStem() async throws {
        try file("\(old)/Anna/IMG_1.mov")
        try file("\(old)/Anna/IMG_1.skianalysis.json")
        try file("\(new)/Anna/IMG_1.skianalysis.json")
        let p = try await plan()
        XCTAssertEqual(movedNames(p), [])
        XCTAssertEqual(stayed(p), ["IMG_1.mov", "IMG_1.skianalysis.json"])
    }

    /// The reverse: a moved sidecar would become the analysis of the clip
    /// that is already there.
    func testASidecarStaysWhenTheTargetHoldsAnotherClipOfItsStem() async throws {
        try file("\(old)/Anna/IMG_1.mov")
        try file("\(old)/Anna/IMG_1.skianalysis.json")
        try file("\(new)/Anna/IMG_1.mp4")
        let p = try await plan()
        XCTAssertEqual(movedNames(p), [])
        XCTAssertEqual(stayed(p), ["IMG_1.mov", "IMG_1.skianalysis.json"])
    }

    func testAStayingStemDoesNotCaptureALongerStem() async throws {
        try file("\(old)/Anna/IMG_1.mov")
        try file("\(old)/Anna/IMG_10.mov")
        try file("\(old)/Anna/IMG_10.skianalysis.json")
        try file("\(new)/Anna/IMG_1.mov")
        let p = try await plan()
        XCTAssertEqual(movedNames(p), ["IMG_10.mov", "IMG_10.skianalysis.json"])
        XCTAssertEqual(stayed(p), ["IMG_1.mov"])
    }

    func testAHalfDoneMergePlansOnlyTheRemainder() async throws {
        try file("\(old)/Anna/IMG_2.mov")
        try file("\(new)/Anna/IMG_1.mov")
        let p = try await plan()
        XCTAssertEqual(p.steps, [
            .move("IMG_2.mov", from: [old, "Anna"], to: [new, "Anna"]),
            .removeIfEmpty([old, "Anna"]),
            .removeIfEmpty([old]),
        ])
    }

    func testAthleteFirstPlansOnlyTheAthletesNotYetRenamed() async throws {
        try file("Anna/\(old)/IMG_1.mov")
        try file("Bo/\(new)/IMG_2.mov")
        let p = try await plan([["Anna", old], ["Bo", old]])
        XCTAssertEqual(p.steps, [.rename(["Anna", old], to: new)])
    }

    func testAPairSidecarMovesWithItsFirstClipWhenTheSecondStays() async throws {
        try file("\(old)/Anna/IMG_1.mov")
        try file("\(old)/Anna/IMG_7.mov")
        try file("\(old)/Anna/IMG_1--IMG_7.skialignment.json")
        try file("\(new)/Anna/IMG_7.mov")
        let p = try await plan()
        XCTAssertEqual(movedNames(p), ["IMG_1.mov", "IMG_1--IMG_7.skialignment.json"])
        XCTAssertEqual(stayed(p), ["IMG_7.mov"])
    }

    func testAPairSidecarStaysWithItsFirstClipWhenItStays() async throws {
        try file("\(old)/Anna/IMG_1.mov")
        try file("\(old)/Anna/IMG_7.mov")
        try file("\(old)/Anna/IMG_1--IMG_7.skialignment.json")
        try file("\(new)/Anna/IMG_1.mov")
        let p = try await plan()
        XCTAssertEqual(movedNames(p), ["IMG_7.mov"])
        XCTAssertEqual(stayed(p), ["IMG_1.mov", "IMG_1--IMG_7.skialignment.json"])
    }

    /// A local volume treats `B` and `b` as one folder, so a "new" name that
    /// differs only in case still exists and must be merged into, by its real name.
    func testAnEventNameDifferingOnlyInCaseMergesIntoTheExistingFolder() async throws {
        try file("A/Anna/IMG_1.mov")
        try file("B/Bo/IMG_2.mov")
        let p = try await plan([["A"]], to: "b")
        XCTAssertTrue(p.mergesIntoExisting)
        XCTAssertEqual(p.steps, [
            .move("Anna", from: ["A"], to: ["B"]),
            .removeIfEmpty(["A"]),
        ])
    }

    func testACaseOnlyRenameOfTheSourceItselfIsAPlainRename() async throws {
        try file("a/Anna/IMG_1.mov")
        let p = try await plan([["a"]], to: "A")
        XCTAssertEqual(p.steps, [.rename(["a"], to: "A")])
        XCTAssertFalse(p.mergesIntoExisting)
    }

    func testMergeRecursesIntoTheTargetFolderByItsActualCase() async throws {
        try file("\(old)/anna/IMG_2.mov")
        try file("\(new)/Anna/IMG_1.mov")
        let p = try await plan()
        XCTAssertEqual(p.steps, [
            .move("IMG_2.mov", from: [old, "anna"], to: [new, "Anna"]),
            .removeIfEmpty([old, "anna"]),
            .removeIfEmpty([old]),
        ])
    }

    /// Name order puts `IMG_5--IMG_7.skialignment.json` before `IMG_5.mov`
    /// ("-" sorts before "."). A run stopped between the two would leave the
    /// target holding a file of the stem and keep the clip behind for good, so
    /// videos are planned first.
    func testVideosAreMovedBeforeTheirSidecars() async throws {
        try file("\(old)/Anna/IMG_5.mov")
        try file("\(old)/Anna/IMG_5.skianalysis.json")
        try file("\(old)/Anna/IMG_5--IMG_7.skialignment.json")
        try file("\(new)/Anna/IMG_1.mov")
        let p = try await plan()
        XCTAssertEqual(p.steps, [
            .move("IMG_5.mov", from: [old, "Anna"], to: [new, "Anna"]),
            .move("IMG_5--IMG_7.skialignment.json", from: [old, "Anna"], to: [new, "Anna"]),
            .move("IMG_5.skianalysis.json", from: [old, "Anna"], to: [new, "Anna"]),
            .removeIfEmpty([old, "Anna"]),
            .removeIfEmpty([old]),
        ])
    }

    /// After a run stopped right after the video moved: only sidecars are left
    /// in the source, and they follow their clip rather than staying.
    func testSidecarsWhoseClipAlreadyMovedAreMoved() async throws {
        try file("\(old)/Anna/IMG_5.skianalysis.json")
        try file("\(old)/Anna/IMG_5--IMG_7.skialignment.json")
        try file("\(new)/Anna/IMG_5.mov")
        let p = try await plan()
        XCTAssertEqual(movedNames(p), ["IMG_5.skianalysis.json", "IMG_5--IMG_7.skialignment.json"])
        XCTAssertEqual(p.leftInPlace, [])
    }

    /// Clash lookup ignores case, so the stem test must too: on a
    /// case-insensitive volume `img_1.mov` would load `IMG_1.skianalysis.json`.
    func testAStemIsMatchedIgnoringCase() async throws {
        try file("\(old)/Anna/img_1.mov")
        try file("\(new)/Anna/IMG_1.skianalysis.json")
        let p = try await plan()
        XCTAssertEqual(movedNames(p), [])
        XCTAssertEqual(stayed(p), ["img_1.mov"])
    }

    /// A clip iCloud has not downloaded is listed under its real name and
    /// stays with every sidecar of its stem, even when the target holds
    /// nothing of it: a placeholder cannot be moved as the clip, and a
    /// sidecar moved without its clip could later sit beside another one.
    func testAnICloudPlaceholderClipStaysWithItsSidecars() async throws {
        try file("\(old)/Anna/.C0001.MP4.icloud")
        try file("\(old)/Anna/C0001.skianalysis.json")
        try file("\(old)/Anna/C0002.MP4")
        try file("\(new)/Anna/IMG_9.mov")
        let p = try await plan()
        XCTAssertEqual(movedNames(p), ["C0002.MP4"])
        XCTAssertEqual(p.leftInPlace, [[old, "Anna", "C0001.MP4"], [old, "Anna", "C0001.skianalysis.json"]])
    }
}
