import XCTest
@testable import SkiVideoCore

@MainActor
final class RemoteLibraryWiringTests: XCTestCase {
    /// Only the two tests that need a directory of their own — a nested local
    /// library and a second, custom-downloader `ClipCache` — still use this.
    /// Every test that just needs a `ViewerModel` over a fake remote library
    /// gets its own fresh directory from `remoteModel(files:)` instead, in
    /// `RemoteLibraryTestSupport.swift`.
    private var root: URL!
    /// Every test in this file opens root id "d1", and `openRemoteLibrary`
    /// now saves and loads an index for it. Without redirecting
    /// `RemoteLibraryIndex.storeRoot`, the second test to run would find the
    /// first one's stored index on the real disk and skip its sweep — this
    /// was measured to happen and corrupt results across this whole suite,
    /// not just theorized.
    private var previousIndexStoreRoot: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        previousIndexStoreRoot = RemoteLibraryIndex.storeRoot
        RemoteLibraryIndex.storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: RemoteLibraryIndex.storeRoot)
        RemoteLibraryIndex.storeRoot = previousIndexStoreRoot
    }

    func testOpeningARemoteLibraryFillsTheSidebar() async throws {
        let (model, provider, cache) = try remoteModel(files: [
            remoteFile("a", "run1.mp4", ["Neuss 2026", "Ada"]),
            remoteFile("b", "run1.mp4", ["Neuss 2026", "Bea"]),
        ])

        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )

        XCTAssertEqual(model.athletes.map(\.name), ["Ada", "Bea"])
        XCTAssertEqual(model.athletes.map(\.event), ["Neuss 2026", "Neuss 2026"])
    }

    /// The heart of this plan: what playback receives is an ordinary file, not
    /// an HTTPS URL with a token in it.
    func testThePlaybackURLIsALocalFileNotARemoteURL() async throws {
        let (model, provider, cache) = try remoteModel(files: [
            remoteFile("a", "run1.mp4", ["Neuss 2026", "Ada"]),
        ])
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )

        try await model.prepareCurrentClip()

        let url = try XCTUnwrap(model.currentPlaybackURL)
        XCTAssertTrue(url.isFileURL, "got \(url)")
        XCTAssertFalse(url.absoluteString.contains("access_token"))
        XCTAssertFalse(url.absoluteString.contains("googleapis.com"))
    }

    /// Before the bytes land there is nothing to play. The model must say it
    /// is working rather than hand back a URL to a file that is not there.
    func testAClipNotYetOnDiskReportsThatItIsBeingPrepared() async throws {
        let (model, provider, cache) = try remoteModel(files: [
            remoteFile("a", "run1.mp4", ["Neuss 2026", "Ada"]),
        ])
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )

        XCTAssertNil(model.currentPlaybackURL)
        try await model.prepareCurrentClip()
        XCTAssertNotNil(model.currentPlaybackURL)
    }

    /// A local library must keep working exactly as before — its URLs are
    /// already files and must not be routed through the cache.
    func testALocalLibraryStillPlaysDirectlyFromItsOwnFiles() throws {
        let directory = root.appendingPathComponent("Neuss/Ada", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clip = directory.appendingPathComponent("run1.mp4")
        try Data().write(to: clip)

        let model = ViewerModel(
            input: FakeInputSource(), folderPicker: FakeFolderPicker(), oauthPresenter: FakeOAuthPresenter()
        )
        model.openDirectory(root)

        // Both sides resolved. `/var` is a symlink to `/private/var` on macOS,
        // and `FileManager.enumerator` hands back children under the *resolved*
        // path while a URL built by appending components keeps the unresolved
        // one — the same measurement `VideoLibrary.scan` records where it
        // computes `rootPaths`. Comparing the two raw would fail for a reason
        // that has nothing to do with this task.
        XCTAssertEqual(
            model.currentPlaybackURL?.resolvingSymlinksInPath(),
            clip.resolvingSymlinksInPath()
        )
    }

    /// A prepared clip resolves to a file for the comparison window — and so
    /// does any other clip a coach has actually visited, now that selecting
    /// one fetches it. `changeVideo` here stands in for a sidebar click: the
    /// same `fetchSelection` that runs after it is what a coach's own
    /// selection triggers.
    func testTheComparisonPickerOffersAFileOnlyForAPreparedClip() async throws {
        let (model, provider, cache) = try remoteModel(files: [
            remoteFile("a", "run1.mp4", ["Neuss 2026", "Ada"]),
            remoteFile("b", "run2.mp4", ["Neuss 2026", "Ada"]),
        ])
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )
        try await model.prepareCurrentClip()
        _ = model.changeVideo(by: 1)
        try await model.settleFetches()

        let choices = try XCTUnwrap(model.comparisonLibrary.first?.videos)
        XCTAssertEqual(choices.count, 2)
        XCTAssertTrue(
            choices[0].playbackURL.isFileURL,
            "the prepared clip must be a file: got \(choices[0].playbackURL)"
        )
        XCTAssertTrue(
            choices[1].playbackURL.isFileURL,
            "selecting this clip must fetch it too: got \(choices[1].playbackURL)"
        )
    }

    /// `currentPlaybackURL` guards its mirror with `fileExists` because
    /// eviction or an iOS Caches purge can delete a clip's bytes out from
    /// under a still-valid manifest entry. The comparison picker must fall
    /// back the same way rather than handing out a `file://` URL to nothing.
    func testTheComparisonPickerFallsBackWhenTheCachedFileHasBeenEvicted() async throws {
        let (model, provider, cache) = try remoteModel(files: [
            remoteFile("a", "run1.mp4", ["Neuss 2026", "Ada"]),
        ])
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )
        try await model.prepareCurrentClip()
        let preparedURL = try XCTUnwrap(model.currentPlaybackURL)
        try FileManager.default.removeItem(at: preparedURL)

        let choice = try XCTUnwrap(model.comparisonLibrary.first?.videos.first)

        XCTAssertFalse(
            choice.playbackURL.isFileURL,
            "eviction must fall back to the library URL, not a file URL pointing at nothing"
        )
    }

    /// The entire justification for `preparingCount`: a coach reselecting
    /// while the first clip is still downloading must not let that first
    /// fetch finishing clear the flag while the second is still in flight —
    /// which is exactly what a bare boolean would do, showing neither a
    /// spinner nor a clip.
    func testIsPreparingClipStaysTrueUntilBothOverlappingFetchesFinish() async throws {
        let downloader = FakeClipDownloader()
        downloader.shouldWait = true
        let cache = ClipCache(root: root, downloader: downloader, budget: 1_000_000)
        let provider = FakeRemoteProvider(files: [
            remoteFile("a", "run1.mp4", ["Neuss 2026", "Ada"]),
            remoteFile("b", "run2.mp4", ["Neuss 2026", "Ada"]),
        ])
        let model = ViewerModel(
            input: FakeInputSource(), folderPicker: FakeFolderPicker(),
            oauthPresenter: FakeOAuthPresenter()
        )
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )
        XCTAssertFalse(model.isPreparingClip)

        Task { try await model.prepareCurrentClip() }
        // Let the first fetch reach the downloader and hold its gate before
        // the selection moves on.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(model.isPreparingClip)

        model.changeVideo(by: 1)
        Task { try await model.prepareCurrentClip() }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(downloader.requestedFileIDs, ["a", "b"], "both fetches must be in flight")
        XCTAssertTrue(model.isPreparingClip)

        downloader.release("a")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(
            model.isPreparingClip,
            "the first fetch finishing must not clear the flag while the second is still in flight"
        )

        downloader.release("b")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(model.isPreparingClip)
    }

    // MARK: - Folder layout

    /// **Why the layout picker "never took effect".** `openRemoteLibrary` used
    /// the convention it was handed only on a *fresh* sweep; a stored index
    /// kept whatever it was built with, so once a drive had been indexed once
    /// — which is after the very first open — no pick could reach it again.
    /// The operator's drive was stored `eventThenAthlete`, and toggling the
    /// picker changed nothing, "no matter what I do it gets it wrong".
    ///
    /// The second open here is the one that used to be ignored. Asserted on
    /// the sidebar, and on the enumeration count, which is what proves the
    /// re-grouping came from the files already indexed rather than from
    /// listing the drive again.
    func testAChosenLayoutTakesEffectOnAnAlreadyIndexedDrive() async throws {
        let (model, provider, cache) = try remoteModel(files: [
            remoteFile("a", "run1.mp4", ["2026-07-16_Neuss", "Ada"]),
        ])
        let root = RemoteFolder(id: "d1", name: "Club")
        try await model.openRemoteLibrary(provider: provider, root: root, cache: cache)
        XCTAssertEqual(model.athletes.map(\.name), ["Ada"], "inferred event-first")

        try await model.openRemoteLibrary(
            provider: provider, root: root, cache: cache, convention: .athleteThenEvent
        )

        XCTAssertEqual(model.athletes.map(\.name), ["2026-07-16_Neuss"])
        XCTAssertEqual(model.athletes.map(\.event), ["Ada"])
        XCTAssertEqual(provider.enumerateCallCount, 1, "re-grouped, not re-listed")
    }

    /// A pick is a pick. The folders here say event-first as loudly as folders
    /// can, and the coach who said otherwise must not be argued with on the
    /// next open — an inference that could overrule a choice would be the same
    /// bug as a choice that could not be made.
    func testInferenceNeverOverrulesAChosenLayoutOnALaterOpen() async throws {
        let (model, provider, cache) = try remoteModel(files: [
            remoteFile("a", "run1.mp4", ["2026-07-16_Neuss", "Ada"]),
        ])
        let root = RemoteFolder(id: "d1", name: "Club")
        try await model.openRemoteLibrary(
            provider: provider, root: root, cache: cache, convention: .athleteThenEvent
        )

        try await model.openRemoteLibrary(provider: provider, root: root, cache: cache)

        XCTAssertEqual(model.athletes.map(\.name), ["2026-07-16_Neuss"])
    }

    /// The operator's own shape, end to end: dated sessions under named
    /// people, opened with nothing chosen. Their index stored the opposite and
    /// showed the dates as athletes.
    func testAnUnchosenLayoutIsInferredFromTheFoldersThemselves() async throws {
        let (model, provider, cache) = try remoteModel(files: [
            remoteFile("a", "run1.mp4", ["Idun Nielsen", "2026-02-25_Hoch-Ybrig"]),
            remoteFile("b", "run2.mp4", ["Nora Nielsen", "20251213 Zürs"]),
        ])

        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Videos"), cache: cache
        )

        XCTAssertEqual(model.athletes.map(\.name), ["Idun Nielsen", "Nora Nielsen"])
        XCTAssertEqual(
            model.athletes.map(\.event), ["2026-02-25_Hoch-Ybrig", "20251213 Zürs"]
        )
    }

    /// Where the folders say nothing, athlete-first — the shape the one
    /// measured Shared Drive uses, and a decision that has to be made
    /// somewhere. Fails if the fallback is ever put back to event-first.
    func testFoldersThatSayNothingFallBackToAthleteFirst() async throws {
        let (model, provider, cache) = try remoteModel(files: [
            remoteFile("a", "run1.mp4", ["Ada", "Session"]),
        ])

        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )

        XCTAssertEqual(model.athletes.map(\.name), ["Ada"])
        XCTAssertEqual(model.athletes.map(\.event), ["Session"])
    }
}
