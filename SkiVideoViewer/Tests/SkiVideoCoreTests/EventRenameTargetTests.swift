import XCTest
@testable import SkiVideoCore

@MainActor
final class EventRenameTargetTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    /// Opens a fake drive. Deliberately *not* wrapped in its own
    /// `withTemporaryIndexStore`: the reload tests must open and reload
    /// against the same store, or the reload finds no stored index, sweeps
    /// from scratch, and passes without ever reaching the change-feed branch
    /// they exist to test. Callers wrap the whole test body instead.
    private func openDrive(_ files: [RemoteFile], convention: FolderConvention,
                           writer: FakeDriveWriter = FakeDriveWriter()) async throws -> ViewerModel {
        writer.listedFiles = files
        let model = ViewerModel(input: FakeInputSource(), folderPicker: FakeFolderPicker(),
                                oauthPresenter: FakeOAuthPresenter())
        await model.signIn(with: writer)
        let opened = await model.chooseRoot(RemoteFolder(id: "drive-1", name: "Club"),
                                            cache: ClipCache(root: root.appendingPathComponent(".cache"),
                                                             downloader: FakeClipDownloader(), budget: 1_000),
                                            convention: convention)
        XCTAssertTrue(opened, model.signInError ?? "")
        return model
    }

    /// Every await here talks to in-memory fakes, but a hang would still stall
    /// the whole xctest process; ten seconds is far beyond any honest run.
    private func bounded(_ body: @escaping @MainActor () async throws -> Void) async throws {
        let finished = expectation(description: "finished in time")
        var failure: Error?
        let task = Task { @MainActor in
            do { try await body() } catch { failure = error }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 10)
        task.cancel()
        if let failure { throw failure }
    }

    /// Open and reload share one index store, so the reload meets the index
    /// the open saved — see `openDrive`.
    private func boundedWithStore(_ body: @escaping @MainActor () async throws -> Void) async throws {
        try await bounded { try await withTemporaryIndexStore(body) }
    }

    func testAnEventFirstDriveEventIsOneFolder() async throws {
        try await boundedWithStore {
            let model = try await self.openDrive([
                remoteFile("1", "a.mov", ["2026-02-14_Hochybrig", "Anna"]),
                remoteFile("2", "b.mov", ["2026-02-14_Hochybrig", "Bo"]),
            ], convention: .eventThenAthlete)
            let rename = try model.eventRenameTarget(for: "2026-02-14_Hochybrig")
            XCTAssertEqual(rename.oldName, "2026-02-14_Hochybrig")
            XCTAssertEqual(model.eventRenameFolders(for: "2026-02-14_Hochybrig"), [["2026-02-14_Hochybrig"]])
            XCTAssertEqual(model.eventClipCount(named: "2026-02-14_Hochybrig"), EventClipCount(clips: 2, athletes: 2))
        }
    }

    /// Review Focus 4: case variants grouped as one event are all renamed.
    func testAthleteFirstCollectsEveryAthletesFolderIgnoringCase() async throws {
        try await boundedWithStore {
            let model = try await self.openDrive([
                remoteFile("1", "a.mov", ["Anna", "2026-02-14_hochybrig"]),
                remoteFile("2", "b.mov", ["Bo", "2026-02-14_Hochybrig"]),
            ], convention: .athleteThenEvent)
            XCTAssertEqual(model.eventRenameFolders(for: "2026-02-14_Hochybrig"),
                           [["Anna", "2026-02-14_hochybrig"], ["Bo", "2026-02-14_Hochybrig"]])
        }
    }

    /// The sidebar folds diacritics as well as case (`LibraryGrouping.fold`),
    /// so `Zürs` and `Zurs` are one sidebar event — and one rename.
    func testAccentVariantsTheSidebarGroupsAreCollectedToo() async throws {
        try await boundedWithStore {
            let model = try await self.openDrive([
                remoteFile("1", "a.mov", ["Anna", "2026-01-10_Zürs"]),
                remoteFile("2", "b.mov", ["Bo", "2026-01-10_Zurs"]),
            ], convention: .athleteThenEvent)
            XCTAssertEqual(model.events.compactMap(\.name).count, 1, "precondition: one sidebar event")
            let shown = try XCTUnwrap(model.events.first?.name)
            XCTAssertEqual(model.eventRenameFolders(for: shown),
                           [["Anna", "2026-01-10_Zürs"], ["Bo", "2026-01-10_Zurs"]])
            XCTAssertEqual(model.eventClipCount(named: shown), EventClipCount(clips: 2, athletes: 2))
        }
    }

    func testNothingOpenRefuses() {
        let model = ViewerModel(input: FakeInputSource(), folderPicker: FakeFolderPicker(),
                                oauthPresenter: FakeOAuthPresenter())
        XCTAssertThrowsError(try model.eventRenameTarget(for: "x")) {
            XCTAssertEqual($0 as? EventRenameRefusal, .noLibraryOpen)
        }
    }

    func testALocalLibraryRenamesTheFolderAboveEachAthlete() throws {
        for path in ["2026/2026-02-14_Hochybrig/Anna/a.mov", "2026/2026-02-14_Hochybrig/Bo/b.mov"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: url)
        }
        let model = ViewerModel(input: FakeInputSource(), folderPicker: FakeFolderPicker(),
                                oauthPresenter: FakeOAuthPresenter())
        model.openDirectory(root)
        XCTAssertEqual(model.eventRenameFolders(for: "2026-02-14_Hochybrig"), [["2026", "2026-02-14_Hochybrig"]])
        XCTAssertNoThrow(try model.eventRenameTarget(for: "2026-02-14_Hochybrig"))
    }

    /// Review Focus 5 and the spec's refresh rule.
    func testAChangePageWithAFolderMakesTheNextOpenReList() async throws {
        try await boundedWithStore {
            let writer = FakeDriveWriter()
            let model = try await self.openDrive([remoteFile("1", "a.mov", ["2026-02-14_Hochybrig", "Anna"])],
                                            convention: .eventThenAthlete, writer: writer)
            writer.listedFiles = [remoteFile("1", "a.mov", ["2026-02-14_Hoch-Ybrig", "Anna"])]
            writer.nextChanges = RemoteLibraryChanges(changed: [], removed: [], cursor: "c2", foldersChanged: true)
            try await model.reloadOpenLibrary()
            XCTAssertEqual(model.events.compactMap(\.name), ["2026-02-14_Hoch-Ybrig"])
        }
    }

    /// Without a folder change the page is applied as a delta, not re-listed:
    /// the re-list is the rare path, not the new default.
    func testAChangePageWithoutAFolderStillAppliesTheDelta() async throws {
        try await boundedWithStore {
            let writer = FakeDriveWriter()
            let model = try await self.openDrive([remoteFile("1", "a.mov", ["2026-02-14_Hochybrig", "Anna"])],
                                            convention: .eventThenAthlete, writer: writer)
            writer.listedFiles = [remoteFile("1", "a.mov", ["2026-02-14_Hoch-Ybrig", "Anna"])]
            writer.nextChanges = RemoteLibraryChanges(changed: [], removed: [], cursor: "c2")
            try await model.reloadOpenLibrary()
            XCTAssertEqual(model.events.compactMap(\.name), ["2026-02-14_Hochybrig"])
        }
    }

    /// Review Focus 5: the re-list drops the stored index, and with it the
    /// record that the coach picked the layout. Folders with no dates read as
    /// nothing either way, so without the kept pick the default
    /// (athlete-first) would flip `Hoch-Ybrig` from event to athlete.
    func testAnExplicitLayoutSurvivesTheReList() async throws {
        try await boundedWithStore {
            let writer = FakeDriveWriter()
            let model = try await self.openDrive([remoteFile("1", "a.mov", ["Hochybrig", "Anna"])],
                                            convention: .eventThenAthlete, writer: writer)
            XCTAssertEqual(model.events.compactMap(\.name), ["Hochybrig"])
            writer.listedFiles = [remoteFile("1", "a.mov", ["Hoch-Ybrig", "Anna"])]
            writer.nextChanges = RemoteLibraryChanges(changed: [], removed: [], cursor: "c2", foldersChanged: true)
            try await model.reloadOpenLibrary()
            XCTAssertEqual(model.events.compactMap(\.name), ["Hoch-Ybrig"])
        }
    }

    /// The spec: a clip open in the viewer is re-selected under its new name.
    func testTheOpenClipIsReselectedAfterTheRename() async throws {
        try await boundedWithStore {
            let writer = FakeDriveWriter()
            let model = try await self.openDrive([
                remoteFile("1", "a.mov", ["2026-02-14_Hochybrig", "Anna"]),
                remoteFile("2", "b.mov", ["2026-02-14_Hochybrig", "Anna"]),
            ], convention: .eventThenAthlete, writer: writer)
            _ = model.changeVideo(by: 1)
            XCTAssertEqual(model.currentVideo?.lastPathComponent, "b.mov")
            writer.listedFiles = [
                remoteFile("1", "a.mov", ["2026-02-14_Hoch-Ybrig", "Anna"]),
                remoteFile("2", "b.mov", ["2026-02-14_Hoch-Ybrig", "Anna"]),
            ]
            writer.nextChanges = RemoteLibraryChanges(changed: [], removed: [], cursor: "c2", foldersChanged: true)
            try await model.reloadOpenLibrary()
            XCTAssertEqual(model.currentVideo?.lastPathComponent, "b.mov")
            XCTAssertEqual(model.currentClipIdentity, .remote(provider: FakeDriveWriter.identifier, fileID: "2"))
            XCTAssertEqual(model.events.compactMap(\.name), ["2026-02-14_Hoch-Ybrig"])
        }
    }

    /// A local clip has no id; it is found again by athlete and file name
    /// after the folder above it was renamed on disk.
    func testALocalOpenClipIsReselectedAfterTheRename() async throws {
        for path in ["2026-02-14_Hochybrig/Anna/a.mov", "2026-02-14_Hochybrig/Anna/b.mov",
                     "2026-01-01_Other/Bo/c.mov"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: url)
        }
        let model = ViewerModel(input: FakeInputSource(), folderPicker: FakeFolderPicker(),
                                oauthPresenter: FakeOAuthPresenter())
        model.openDirectory(root)
        let anna = try XCTUnwrap(model.athletes.first { $0.name == "Anna" })
        model.selectAthlete(anna.id)
        _ = model.changeVideo(by: 1)
        XCTAssertEqual(model.currentVideo?.lastPathComponent, "b.mov")
        try FileManager.default.moveItem(at: root.appendingPathComponent("2026-02-14_Hochybrig"),
                                         to: root.appendingPathComponent("2026-02-14_Hoch-Ybrig"))
        try await bounded { try await model.reloadOpenLibrary() }
        XCTAssertEqual(model.currentVideo?.lastPathComponent, "b.mov")
        XCTAssertEqual(model.currentVideo?.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
                       "2026-02-14_Hoch-Ybrig")
    }
}
