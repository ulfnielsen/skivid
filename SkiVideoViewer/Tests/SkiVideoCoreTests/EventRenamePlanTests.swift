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

    func testAFolderAlreadyRenamedPlansNothing() async throws {
        try file("2026-02-14_Hoch-Ybrig/Anna/IMG_1.mov")
        let plan = try await EventRenamePlanner.plan(
            eventFolders: [["2026-02-14_Hochybrig"]], newName: "2026-02-14_Hoch-Ybrig", in: folders)
        XCTAssertEqual(plan.steps, [])
    }
}
