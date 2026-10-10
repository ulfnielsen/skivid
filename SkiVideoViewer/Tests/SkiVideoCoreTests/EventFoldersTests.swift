import XCTest
@testable import SkiVideoCore

/// The folder seam on real temporary directories (local) and on the
/// in-memory Drive (`FakeDriveWriter`), so both implementations are held to
/// one contract.
final class EventFoldersTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("EventFolders-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func file(_ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: url)
    }

    // MARK: Local

    func testLocalListsFoldersAndFilesAndSaysWhenAFolderIsMissing() async throws {
        try file("2026-02-14_A/Anna/IMG_1.mov")
        let folders = LocalEventFolders(root: root)
        let event = try await folders.children(of: ["2026-02-14_A"])
        XCTAssertEqual(event, [FolderEntry(name: "Anna", isFolder: true)])
        let missing = try await folders.children(of: ["nope"])
        XCTAssertNil(missing)
    }

    func testLocalRenameNeverOverwrites() async throws {
        try file("2026-02-14_A/Anna/IMG_1.mov")
        try file("2026-02-14_B/Bo/IMG_2.mov")
        let folders = LocalEventFolders(root: root)
        do {
            try await folders.rename(["2026-02-14_A"], to: "2026-02-14_B")
            XCTFail("renaming onto an existing folder must throw")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("2026-02-14_A/Anna/IMG_1.mov").path))
    }

    /// Review Focus 1: APFS is case-insensitive, so the destination "exists".
    func testLocalCaseOnlyRenameHappens() async throws {
        try file("2026-02-14_Hochybrig/Anna/IMG_1.mov")
        let folders = LocalEventFolders(root: root)
        try await folders.rename(["2026-02-14_Hochybrig"], to: "2026-02-14_HochYbrig")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(names, ["2026-02-14_HochYbrig"])
    }

    func testLocalMoveOfAMissingItemIsANoOp() async throws {
        try file("2026-02-14_A/Anna/IMG_1.mov")
        let folders = LocalEventFolders(root: root)
        try await folders.move("gone.mov", from: ["2026-02-14_A", "Anna"], to: ["2026-02-14_A"])
    }

    func testLocalRemovesOnlyAnEmptyFolder() async throws {
        try file("2026-02-14_A/Anna/IMG_1.mov")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("2026-02-14_A/Bo"),
                                                withIntermediateDirectories: true)
        let folders = LocalEventFolders(root: root)
        let removedFull = try await folders.removeIfEmpty(["2026-02-14_A", "Anna"])
        let removedEmpty = try await folders.removeIfEmpty(["2026-02-14_A", "Bo"])
        XCTAssertFalse(removedFull)
        XCTAssertTrue(removedEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("2026-02-14_A/Anna/IMG_1.mov").path))
    }

    func testLocalRemovesAFolderHoldingOnlyClutter() async throws {
        try file("2026-02-14_A/Bo/.DS_Store")
        try file("2026-02-14_A/Bo/._IMG_1.mov")
        let folders = LocalEventFolders(root: root)
        let removed = try await folders.removeIfEmpty(["2026-02-14_A", "Bo"])
        XCTAssertTrue(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("2026-02-14_A/Bo").path))
    }

    func testLocalKeepsAFolderHoldingOtherHiddenFiles() async throws {
        try file("2026-02-14_A/Bo/.keep")
        try file("2026-02-14_A/Cy/.IMG_2.mov.icloud")
        let folders = LocalEventFolders(root: root)
        let keptDot = try await folders.removeIfEmpty(["2026-02-14_A", "Bo"])
        let keptCloud = try await folders.removeIfEmpty(["2026-02-14_A", "Cy"])
        XCTAssertFalse(keptDot)
        XCTAssertFalse(keptCloud)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("2026-02-14_A/Bo/.keep").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("2026-02-14_A/Cy/.IMG_2.mov.icloud").path))
    }

    /// iCloud keeps a clip it has not downloaded as `.C0001.MP4.icloud`. The
    /// planner must see that clip, so it is listed by its real name and
    /// flagged; other hidden files stay unlisted.
    func testLocalListsAnICloudPlaceholderUnderItsRealName() async throws {
        try file("2026-02-14_A/Anna/.C0001.MP4.icloud")
        try file("2026-02-14_A/Anna/.keep")
        try file("2026-02-14_A/Anna/C0001.skianalysis.json")
        let folders = LocalEventFolders(root: root)
        let entries = try await folders.children(of: ["2026-02-14_A", "Anna"])
        XCTAssertEqual(entries, [
            FolderEntry(name: "C0001.MP4", isFolder: false, isPlaceholder: true),
            FolderEntry(name: "C0001.skianalysis.json", isFolder: false),
        ])
    }

    /// A `._x` *directory* is not AppleDouble clutter — it may hold anything —
    /// and deleting it would be recursive, so it keeps its folder.
    func testLocalKeepsAFolderHoldingADotUnderscoreDirectory() async throws {
        try file("2026-02-14_A/Bo/._dir/IMG_1.mov")
        let folders = LocalEventFolders(root: root)
        let removed = try await folders.removeIfEmpty(["2026-02-14_A", "Bo"])
        XCTAssertFalse(removed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("2026-02-14_A/Bo/._dir/IMG_1.mov").path))
    }

    /// A clip that lands after the emptiness check (an upload, a sync) must
    /// survive: the final removal is `rmdir`, which refuses a non-empty folder.
    func testLocalKeepsAClipThatArrivesAfterTheEmptinessCheck() async throws {
        try file("2026-02-14_A/Bo/.DS_Store")
        let late = root.appendingPathComponent("2026-02-14_A/Bo/IMG_1.mov")
        let folders = LocalEventFolders(root: root, afterCheckingEmpty: { _ in try? Data([1]).write(to: late) })
        let removed = try await folders.removeIfEmpty(["2026-02-14_A", "Bo"])
        XCTAssertFalse(removed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: late.path))
    }

    // MARK: Drive
    // `FakeOAuthPresenter` is main-actor isolated, so these run there.

    @MainActor
    func testDriveResolvesPathsAndRenamesByID() async throws {
        let drive = FakeDriveWriter()
        drive.seedFile("IMG_1.mov", at: ["2026-02-14_A", "Anna"])
        let folders = DriveEventFolders(writer: drive, rootID: "root-1", presenter: FakeOAuthPresenter())
        try await folders.rename(["2026-02-14_A"], to: "2026-02-14_B")
        XCTAssertEqual(drive.path(ofFile: "IMG_1.mov"), ["2026-02-14_B", "Anna"])
    }

    @MainActor
    func testDriveMovesAFileIntoAnotherFolder() async throws {
        let drive = FakeDriveWriter()
        drive.seedFile("IMG_1.mov", at: ["2026-02-14_A", "Anna"])
        drive.seedFile("IMG_2.mov", at: ["2026-02-14_B", "Anna"])
        let folders = DriveEventFolders(writer: drive, rootID: "root-1", presenter: FakeOAuthPresenter())
        try await folders.move("IMG_1.mov", from: ["2026-02-14_A", "Anna"], to: ["2026-02-14_B", "Anna"])
        XCTAssertEqual(drive.path(ofFile: "IMG_1.mov"), ["2026-02-14_B", "Anna"])
    }

    @MainActor
    func testDriveBinsOnlyAnEmptyFolder() async throws {
        let drive = FakeDriveWriter()
        drive.seedFile("IMG_1.mov", at: ["2026-02-14_A", "Anna"])
        let folders = DriveEventFolders(writer: drive, rootID: "root-1", presenter: FakeOAuthPresenter())
        let binned = try await folders.removeIfEmpty(["2026-02-14_A"])
        XCTAssertFalse(binned)
        XCTAssertEqual(drive.trashedIDs, [])
    }

    @MainActor
    func testDriveRenameOntoAnExistingNameStops() async throws {
        let drive = FakeDriveWriter()
        drive.seedFile("IMG_1.mov", at: ["2026-02-14_A", "Anna"])
        drive.seedFile("IMG_2.mov", at: ["2026-02-14_B", "Bo"])
        let folders = DriveEventFolders(writer: drive, rootID: "root-1", presenter: FakeOAuthPresenter())
        do {
            try await folders.rename(["2026-02-14_A"], to: "2026-02-14_B")
            XCTFail("renaming onto an existing folder must throw")
        } catch {}
        XCTAssertEqual(drive.path(ofFile: "IMG_1.mov"), ["2026-02-14_A", "Anna"])
    }

    @MainActor
    func testDriveCaseOnlyRenameStillWorks() async throws {
        let drive = FakeDriveWriter()
        drive.seedFile("IMG_1.mov", at: ["2026-02-14_Hochybrig", "Anna"])
        let folders = DriveEventFolders(writer: drive, rootID: "root-1", presenter: FakeOAuthPresenter())
        try await folders.rename(["2026-02-14_Hochybrig"], to: "2026-02-14_HochYbrig")
        XCTAssertEqual(drive.path(ofFile: "IMG_1.mov"), ["2026-02-14_HochYbrig", "Anna"])
    }

    @MainActor
    func testDriveBinsAnEmptyFolderAndItThenReadsAsGone() async throws {
        let drive = FakeDriveWriter()
        drive.seedFile("IMG_1.mov", at: ["2026-02-14_A", "Anna"])
        let folders = DriveEventFolders(writer: drive, rootID: "root-1", presenter: FakeOAuthPresenter())
        try await folders.move("IMG_1.mov", from: ["2026-02-14_A", "Anna"], to: ["2026-02-14_A"])
        let binned = try await folders.removeIfEmpty(["2026-02-14_A", "Anna"])
        XCTAssertTrue(binned)
        XCTAssertEqual(drive.trashedIDs.count, 1)
        let after = try await folders.children(of: ["2026-02-14_A", "Anna"])
        XCTAssertNil(after)
    }

    @MainActor
    func testDrivePreparingToWriteAsksForConsent() async throws {
        let drive = FakeDriveWriter()
        let folders = DriveEventFolders(writer: drive, rootID: "root-1", presenter: FakeOAuthPresenter())
        try await folders.prepareToWrite()
        XCTAssertEqual(drive.authorizeCount, 1)
    }
}
