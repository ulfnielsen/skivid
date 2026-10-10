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
    private func openDrive(_ files: [RemoteFile], convention: FolderConvention?,
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
            await model.settleFetches()
            XCTAssertEqual(model.currentVideo?.lastPathComponent, "b.mov")
            XCTAssertEqual(model.currentClipIdentity, .remote(provider: FakeDriveWriter.identifier, fileID: "2"))
            XCTAssertEqual(model.events.compactMap(\.name), ["2026-02-14_Hoch-Ybrig"])
        }
    }

    private func makeFiles(_ paths: [String]) throws {
        for path in paths {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: url)
        }
    }

    private func openLocal() -> ViewerModel {
        let model = ViewerModel(input: FakeInputSource(), folderPicker: FakeFolderPicker(),
                                oauthPresenter: FakeOAuthPresenter())
        model.openDirectory(root)
        return model
    }

    /// Selects the clip at `path` (relative to `root`) the way a coach would.
    private func select(_ path: String, in model: ViewerModel) throws {
        let wanted = root.appendingPathComponent(path).standardizedFileURL
        let group = try XCTUnwrap(model.athletes.first { $0.videos.contains { $0.standardizedFileURL == wanted } })
        let index = try XCTUnwrap(group.videos.firstIndex { $0.standardizedFileURL == wanted })
        model.selectAthlete(group.id)
        if index > 0 { _ = model.changeVideo(by: index) }
        XCTAssertEqual(model.currentVideo?.standardizedFileURL, wanted)
    }

    private func currentRelativePath(_ model: ViewerModel) -> String? {
        model.currentVideo.map { Array($0.standardizedFileURL.pathComponents.suffix(3)).joined(separator: "/") }
    }

    /// Camera file names repeat every day. A plain Refresh must keep the
    /// exact clip, not jump to the first same-named clip in sidebar order.
    func testAPlainLocalReloadKeepsTheExactClipWhenCameraNamesRepeat() async throws {
        try makeFiles(["2026-02-14_Hochybrig/Anna/C0001.MP4", "2026-02-20_Brunni/Anna/C0001.MP4"])
        let model = openLocal()
        // Events sort descending, so 02-14 is the later-sorting one.
        try select("2026-02-14_Hochybrig/Anna/C0001.MP4", in: model)
        try await bounded { try await model.reloadOpenLibrary() }
        XCTAssertEqual(currentRelativePath(model), "2026-02-14_Hochybrig/Anna/C0001.MP4")
    }

    /// After a local rename the clip follows to the new event — and only
    /// because the caller said which event was renamed.
    func testALocalOpenClipFollowsItsRenamedEvent() async throws {
        try makeFiles(["2026-02-14_Hochybrig/Anna/a.mov", "2026-02-14_Hochybrig/Anna/C0001.MP4",
                       "2026-02-20_Brunni/Anna/C0001.MP4"])
        let model = openLocal()
        try select("2026-02-14_Hochybrig/Anna/C0001.MP4", in: model)
        try FileManager.default.moveItem(at: root.appendingPathComponent("2026-02-14_Hochybrig"),
                                         to: root.appendingPathComponent("2026-02-14_Hoch-Ybrig"))
        try await bounded {
            try await model.reloadOpenLibrary(renamedEvent: (from: "2026-02-14_Hochybrig", to: "2026-02-14_Hoch-Ybrig"))
        }
        XCTAssertEqual(currentRelativePath(model), "2026-02-14_Hoch-Ybrig/Anna/C0001.MP4")
    }

    /// Without the rename named, a moved clip is not guessed at: the default
    /// selection stands rather than a same-named clip from another day.
    func testALocalClipThatMovedUnannouncedFallsBackToTheDefault() async throws {
        try makeFiles(["2026-02-14_Hochybrig/Anna/C0001.MP4", "2026-02-20_Brunni/Anna/C0001.MP4"])
        let model = openLocal()
        try select("2026-02-14_Hochybrig/Anna/C0001.MP4", in: model)
        try FileManager.default.moveItem(at: root.appendingPathComponent("2026-02-14_Hochybrig"),
                                         to: root.appendingPathComponent("2026-02-14_Hoch-Ybrig"))
        try await bounded { try await model.reloadOpenLibrary() }
        XCTAssertEqual(currentRelativePath(model), "2026-02-20_Brunni/Anna/C0001.MP4")
    }

    /// A rescan that fails leaves the library as it was; nothing steps from a
    /// stale index.
    func testAFailedLocalRescanThrowsAndKeepsTheSelection() async throws {
        try makeFiles(["2026-02-14_Hochybrig/Anna/a.mov", "2026-02-14_Hochybrig/Anna/b.mov"])
        let model = openLocal()
        try select("2026-02-14_Hochybrig/Anna/b.mov", in: model)
        try FileManager.default.removeItem(at: root)
        var thrown: Error?
        try await bounded {
            do { try await model.reloadOpenLibrary() } catch { thrown = error }
        }
        XCTAssertNotNil(thrown)
        XCTAssertEqual(currentRelativePath(model), "2026-02-14_Hochybrig/Anna/b.mov")
    }

    /// Review: the reload used to auto-select group 0's first clip, fetch it,
    /// then step to the old clip — up to three player loads and a download
    /// nobody asked for. It must fetch only the clip that was open.
    func testADriveReloadFetchesOnlyThePreferredClip() async throws {
        try await boundedWithStore {
            let writer = FakeDriveWriter()
            let model = try await self.openDrive([
                remoteFile("1", "a.mov", ["2026-02-20_Brunni", "Anna"]),
                remoteFile("2", "b.mov", ["2026-02-14_Hochybrig", "Bo"]),
                remoteFile("3", "c.mov", ["2026-02-14_Hochybrig", "Bo"]),
            ], convention: .eventThenAthlete, writer: writer)
            let bo = try XCTUnwrap(model.athletes.first { $0.name == "Bo" })
            model.selectAthlete(bo.id)
            _ = model.changeVideo(by: 1)
            await model.settleFetches()
            XCTAssertEqual(model.currentClipIdentity, .remote(provider: FakeDriveWriter.identifier, fileID: "3"))
            // Neighbour prefetches are untracked tasks, so `settleFetches`
            // does not wait for them. The open, the select and the step each
            // fetch once, and the select and the step each prefetch one
            // neighbour: five requests. Wait for all five, or a late one
            // would be counted against the reload.
            let deadline = Date().addingTimeInterval(5)
            while writer.downloadRequests.count < 5, Date() < deadline {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            XCTAssertEqual(writer.downloadRequests.count, 5)
            writer.resetDownloadRequests()
            try await model.reloadOpenLibrary()
            await model.settleFetches()
            XCTAssertEqual(writer.downloadRequests, ["3"])
            XCTAssertEqual(model.currentClipIdentity, .remote(provider: FakeDriveWriter.identifier, fileID: "3"))
        }
    }

    func testADriveReloadKeepsTheSidebarSearch() async throws {
        try await boundedWithStore {
            let model = try await self.openDrive([remoteFile("1", "a.mov", ["2026-02-14_Hochybrig", "Anna"])],
                                                 convention: .eventThenAthlete)
            model.athleteQuery = "ann"
            try await model.reloadOpenLibrary()
            XCTAssertEqual(model.athleteQuery, "ann")
        }
    }

    /// A Refresh that cannot reach the drive must say so, not return as if
    /// it had refreshed. There is no sign-out today, so the reachable case is
    /// a drive opened without a library record — no root id to reopen.
    func testADriveReloadWithoutALibraryRecordThrows() async throws {
        try await boundedWithStore {
            let writer = FakeDriveWriter()
            writer.listedFiles = [remoteFile("1", "a.mov", ["2026-02-14_Hochybrig", "Anna"])]
            let model = ViewerModel(input: FakeInputSource(), folderPicker: FakeFolderPicker(),
                                    oauthPresenter: FakeOAuthPresenter())
            try await model.openRemoteLibrary(
                provider: writer, root: RemoteFolder(id: "drive-1", name: "Club"),
                cache: ClipCache(root: self.root.appendingPathComponent(".cache"),
                                 downloader: FakeClipDownloader(), budget: 1_000))
            var thrown: Error?
            do { try await model.reloadOpenLibrary() } catch { thrown = error }
            XCTAssertNotNil(thrown)
        }
    }

    func testAReloadWithNothingOpenThrows() async throws {
        let model = ViewerModel(input: FakeInputSource(), folderPicker: FakeFolderPicker(),
                                oauthPresenter: FakeOAuthPresenter())
        var thrown: Error?
        try await bounded { do { try await model.reloadOpenLibrary() } catch { thrown = error } }
        XCTAssertEqual(thrown as? EventRenameRefusal, .noLibraryOpen)
    }

    /// The re-list keeps the change page's cursor rather than minting a fresh
    /// one after the sweep: a change made during the sweep is replayed on the
    /// next open instead of falling between the two.
    func testTheReListKeepsTheChangePagesCursor() async throws {
        try await boundedWithStore {
            let writer = FakeDriveWriter()
            let model = try await self.openDrive([remoteFile("1", "a.mov", ["2026-02-14_Hochybrig", "Anna"])],
                                                 convention: .eventThenAthlete, writer: writer)
            writer.listedFiles = [remoteFile("1", "a.mov", ["2026-02-14_Hoch-Ybrig", "Anna"])]
            writer.nextChanges = RemoteLibraryChanges(changed: [], removed: [], cursor: "c2", foldersChanged: true)
            try await model.reloadOpenLibrary()
            writer.nextChanges = nil
            try await model.reloadOpenLibrary()
            XCTAssertEqual(writer.changesRequestedSince, ["c1", "c2"])
        }
    }

    /// An inferred layout is not a choice: after a re-list the folders are
    /// read afresh, and a library that now reads event-first becomes so.
    func testAnInferredLayoutIsReInferredAfterTheReList() async throws {
        try await boundedWithStore {
            let writer = FakeDriveWriter()
            let model = try await self.openDrive([remoteFile("1", "a.mov", ["Anna", "2026-02-14_Hochybrig"])],
                                                 convention: nil, writer: writer)
            XCTAssertEqual(model.events.compactMap(\.name), ["2026-02-14_Hochybrig"])
            writer.listedFiles = [remoteFile("1", "a.mov", ["2026-02-14_Hochybrig", "Anna"])]
            writer.nextChanges = RemoteLibraryChanges(changed: [], removed: [], cursor: "c2", foldersChanged: true)
            try await model.reloadOpenLibrary()
            XCTAssertEqual(model.athletes.map(\.name), ["Anna"])
            XCTAssertEqual(model.eventRenameFolders(for: "2026-02-14_Hochybrig"), [["2026-02-14_Hochybrig"]])
        }
    }

    /// The event is the folder above the athlete, however deep it sits.
    func testANestedEventFirstDrivePathCollectsTheFullPath() async throws {
        try await boundedWithStore {
            let model = try await self.openDrive([
                remoteFile("1", "a.mov", ["2026", "2026-02-14_Hochybrig", "Anna"]),
                remoteFile("2", "b.mov", ["2026", "2026-02-14_Hochybrig", "Bo"]),
            ], convention: .eventThenAthlete)
            XCTAssertEqual(model.eventRenameFolders(for: "2026-02-14_Hochybrig"), [["2026", "2026-02-14_Hochybrig"]])
        }
    }
}
