import XCTest
@testable import SkiVideoCore

@MainActor
final class FetchOnSelectTests: XCTestCase {
    /// Every test here opens root id "d1", and `openRemoteLibrary` saves an
    /// index for it via the un-isolated static `RemoteLibraryIndex.storeRoot`.
    /// Without redirecting it, a real run wrote a fake five-clip index
    /// straight into `~/Library/Application Support/SkiVideoViewer/RemoteLibrary`
    /// — found on disk, next to the real 407-clip index, and confirmed by
    /// inspection before this fix. `RemoteLibraryWiringTests` already isolates
    /// itself the same way; this copies that pattern.
    private var previousIndexStoreRoot: URL!

    override func setUpWithError() throws {
        previousIndexStoreRoot = RemoteLibraryIndex.storeRoot
        RemoteLibraryIndex.storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: RemoteLibraryIndex.storeRoot)
        RemoteLibraryIndex.storeRoot = previousIndexStoreRoot
    }

    private func fiveClips() -> [RemoteFile] {
        (1...5).map { remoteFile("f\($0)", "run\($0).mp4", ["Neuss 2026", "Ada"]) }
    }

    private func sixClips() -> [RemoteFile] {
        (1...6).map { remoteFile("f\($0)", "run\($0).mp4", ["Neuss 2026", "Ada"]) }
    }

    /// The reported case, in the second slot: 400MB of 30-second 1080p, about
    /// 29× the bitrate this app's own pipeline produces. Keeps the name
    /// `fiveClips` gave it, so the sidebar's ordering — and therefore which
    /// clip `changeVideo(by: 1)` lands on — is unchanged from every other test
    /// in this file.
    private func fiveClipsWithAnOversizedSecond() -> [RemoteFile] {
        var files = fiveClips()
        files[1] = RemoteFile(
            id: "f2", name: "run2.mp4", path: ["Neuss 2026", "Ada"],
            size: 400 * 1_000_000, contentVersion: "v1", md5: nil,
            width: 1920, height: 1080, durationMillis: 30_000
        )
        return files
    }

    private func openedLibrary(
        files: [RemoteFile]
    ) async throws -> (ViewerModel, FakeRemoteProvider, ClipCache, FakeClipDownloader) {
        let (model, provider, cache, downloader) = try remoteModelWithDownloader(files: files)
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )
        return (model, provider, cache, downloader)
    }

    // MARK: - Clips too heavy to be worth fetching

    /// The whole point of the rule: a clip `ClipWeight` flags must not be
    /// downloaded. Asserted on what actually reached the downloader rather
    /// than on a status string — a status assertion would pass with the 400MB
    /// transfer still running, which is the one outcome this exists to prevent.
    func testSelectingAnOversizedClipDoesNotFetchIt() async throws {
        let (model, _, _, downloader) = try await openedLibrary(
            files: fiveClipsWithAnOversizedSecond()
        )

        _ = model.changeVideo(by: 1)
        try await model.settleFetches()

        XCTAssertFalse(
            downloader.requestedFileIDs.contains("f2"),
            "the flagged clip was downloaded anyway: \(downloader.requestedFileIDs)"
        )
        XCTAssertNil(model.currentPlaybackURL, "nothing was fetched, so there is nothing to play")
        let message = try XCTUnwrap(
            model.unsupportedFormatMessage,
            "a refused clip with no explanation reads as a broken app"
        )
        XCTAssertTrue(message.contains("400"), message)
    }

    /// Refusing to *fetch* is not refusing to *play*. A coach who already has
    /// the bytes — from before this rule existed, or from a deliberate repair
    /// — paid for them once, and taking the clip away at that point would be a
    /// regression dressed up as a safeguard.
    func testAnOversizedClipAlreadyInTheCacheStillPlays() async throws {
        let files = fiveClipsWithAnOversizedSecond()
        let (model, provider, cache, downloader) = try remoteModelWithDownloader(files: files)
        // Primed through a record that declares the size of the bytes actually
        // handed over, because `ClipCache` rejects a download whose length
        // disagrees with the file's declared size — priming with the 400MB
        // record would need 400MB of fake bytes. Same id and same
        // `contentVersion`, which is all a cache hit consults: `cachedURL`
        // looks a clip up by id alone, and `materialize`'s hit branch compares
        // only the version. So this is genuinely "f2's bytes are on disk".
        downloader.bytesByFileID["f2"] = Data("already paid for".utf8)
        _ = try await cache.materialize(
            RemoteFile(
                id: "f2", name: "run2.mp4", path: ["Neuss 2026", "Ada"],
                size: Int64("already paid for".utf8.count), contentVersion: "v1", md5: nil
            ),
            source: DownloadSource(url: provider.downloadURL, headers: [:])
        )
        let fetchesWhilePriming = downloader.requestedFileIDs.filter { $0 == "f2" }.count

        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )
        _ = model.changeVideo(by: 1)
        try await model.settleFetches()

        XCTAssertEqual(model.currentClipIdentity, .remote(provider: "fake", fileID: "f2"),
                       "got \(String(describing: model.currentPlaybackURL))")
        XCTAssertNotNil(model.currentPlaybackURL, "the cached clip must still resolve to a file")
        XCTAssertEqual(
            downloader.requestedFileIDs.filter { $0 == "f2" }.count, fetchesWhilePriming,
            "playing a cached clip must not re-download it: \(downloader.requestedFileIDs)"
        )
    }

    /// The comparison screen matters more than it looks: a coach filling both
    /// panes with flagged clips would otherwise start two 400MB transfers at
    /// once. Both panes go through `ViewerModel.materialise`, so the rule is
    /// enforced in one place — this pins that it actually reaches them, and
    /// that the pane says why instead of sitting blank.
    func testLoadingAnOversizedClipIntoAComparisonPaneDoesNotFetchIt() async throws {
        let (model, _, _, downloader) = try await openedLibrary(
            files: fiveClipsWithAnOversizedSecond()
        )
        try await model.settleFetches()
        let choice = try XCTUnwrap(
            model.comparisonLibrary.first?.videos.first { $0.identity == .remote(provider: "fake", fileID: "f2") }
        )

        let comparison = ComparisonModel()
        await comparison.load(choice, side: .left, fetching: model)

        XCTAssertFalse(
            downloader.requestedFileIDs.contains("f2"),
            "a comparison pane downloaded the flagged clip: \(downloader.requestedFileIDs)"
        )
        XCTAssertTrue(
            comparison.status.contains("run2.mp4"),
            "the pane must name the clip it did not load, got \(comparison.status)"
        )
        // The reason itself, on the screen the operator is looking at. Before
        // `ClipPreparer` carried it, the seam could only say "no URL" and this
        // read "see the main window" — a pointer to a banner on the *other*
        // window, which is not an explanation.
        XCTAssertTrue(
            comparison.status.contains("400"),
            "the pane must say why, not point elsewhere, got \(comparison.status)"
        )
    }

    /// Drive fills `videoMediaMetadata` in asynchronously after an upload, so a
    /// clip added minutes ago carries none — and a rule that refused what it
    /// cannot measure would strike hardest exactly when a coach has just
    /// uploaded footage and wants to watch it. 400MB, deliberately: size alone
    /// must not be enough to refuse.
    func testAClipWithNoMetadataIsFetchedNormally() async throws {
        var files = fiveClips()
        files[1] = RemoteFile(
            id: "f2", name: "run2.mp4", path: ["Neuss 2026", "Ada"],
            size: 400 * 1_000_000, contentVersion: "v1", md5: nil
        )
        let (model, _, _, downloader) = try await openedLibrary(files: files)

        _ = model.changeVideo(by: 1)
        try await model.settleFetches()

        XCTAssertTrue(
            downloader.requestedFileIDs.contains("f2"),
            "an unmeasurable clip must be fetched as usual: \(downloader.requestedFileIDs)"
        )
    }

    /// Selecting a clip is what asks for it. Nothing else in the app calls
    /// `prepareCurrentClip`, so without this a coach clicks a clip and watches
    /// an empty pane forever.
    func testChangingTheSelectedClipFetchesIt() async throws {
        let (model, provider, cache, downloader) = try remoteModelWithDownloader(files: fiveClips())
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )

        _ = model.changeVideo(by: 1)
        try await model.settleFetches()

        XCTAssertTrue(
            downloader.requestedFileIDs.contains("f2"),
            "got \(downloader.requestedFileIDs)"
        )
    }

    /// Prefetch reaches the next two and the previous one — and stops.
    /// Six clips, clip 3 selected: fetching must reach clips 2 through 5
    /// (indices 1–4) and must leave clip 6 alone. Five clips was too small a
    /// fixture to state this bound — with the middle of five selected,
    /// "next two" necessarily lands on the last clip, making the negative
    /// assertion impossible to satisfy honestly. A test asserting only that
    /// the neighbours *were* fetched would pass an implementation that
    /// fetched the whole athlete, which on a 74 GB library is the difference
    /// between a warm cache and a flooded connection.
    func testPrefetchReachesTheNeighboursAndNoFurther() async throws {
        let (model, provider, cache, downloader) = try remoteModelWithDownloader(files: sixClips())
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )

        _ = model.changeVideo(by: 2)          // now on run3
        try await model.settleFetches()

        let fetched = Set(downloader.requestedFileIDs)
        XCTAssertTrue(fetched.isSuperset(of: ["f2", "f3", "f4", "f5"]), "got \(fetched)")
        XCTAssertFalse(fetched.contains("f6"), "prefetch reached too far: \(fetched)")
    }

    /// A comparison pane must fetch the clip it was given. This closes the gap
    /// plan 2 pinned deliberately: before this, a pane was handed the raw
    /// library URL and could open nothing.
    func testChoosingAClipForAComparisonPaneFetchesIt() async throws {
        let (model, provider, cache, downloader) = try remoteModelWithDownloader(files: fiveClips())
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )
        let choice = try XCTUnwrap(model.comparisonLibrary.first?.videos.last)

        let comparison = ComparisonModel()
        await comparison.load(choice, side: .left, fetching: model)

        XCTAssertTrue(downloader.requestedFileIDs.contains("f5"), "got \(downloader.requestedFileIDs)")
        XCTAssertEqual(comparison.playbackURL(for: .left)?.isFileURL, true)
    }

    /// Moving twice quickly must load what was selected *last*, not whichever
    /// download happened to finish last.
    ///
    /// Two problems, found in this order:
    ///
    /// 1. **The original test built no race at all.** `changeVideo` does not
    ///    await its own fetch — it fires an unstructured `Task` and returns
    ///    immediately — and `prepareCurrentClip` reads `currentVideo` live,
    ///    when that `Task` actually *runs*, not a snapshot from when it was
    ///    created. Two `changeVideo` calls back to back with no `await`
    ///    between them do not by themselves construct a race: neither `Task`
    ///    gets any time until the test itself suspends, so both would read
    ///    the *final* selection. `waitUntilGated` is what makes it genuine:
    ///    it suspends until run2's fetch has actually reached the downloader
    ///    — captured `videoAtRequest` and is now blocked — *before* run3 is
    ///    selected.
    /// 2. **The guard the test exists to pin was dead code.**
    ///    `prepareCurrentClip` had `guard let currentVideo, …` at its top,
    ///    which shadows the computed property `self.currentVideo` for the
    ///    rest of the function — so `guard currentVideo == videoAtRequest`
    ///    compared the shadowed local against itself and was always true.
    ///    Fixing problem 1 alone still passed with the guard *deleted*; only
    ///    reading `self.currentVideo` explicitly (the fix now in
    ///    `prepareCurrentClip`) makes the comparison real. Confirmed both
    ///    ways: with the shadowing bug, deleting the guard changed nothing;
    ///    with the fix, deleting the guard fails this test's status
    ///    assertion below, and restoring it passes again.
    ///
    /// The stale fetch is released and given a moment to reach its guard
    /// check while run3's own fetch is still gated, so the status it would
    /// wrongly set (if the guard failed to protect it) is observable before a
    /// later, correct completion could overwrite it. That moment is bounded
    /// by a short `Task.sleep`, not by `waitUntilGated`: the guard's effect
    /// is on `status`, set several actor-hops after the downloader gate opens
    /// (`ClipCache`'s internal `Task`, then a `recordPlayback` round trip),
    /// and nothing in this fake can observe "`ViewerModel` finished handling
    /// the resumed continuation" without instrumenting `ViewerModel` itself.
    func testMovingTwiceQuicklyLoadsTheClipSelectedLast() async throws {
        let (model, provider, cache, downloader) = try remoteModelWithDownloader(files: fiveClips())
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )
        downloader.shouldWait = true

        _ = model.changeVideo(by: 1)              // run2 selected; its fetch starts
        await downloader.waitUntilGated("f2")     // ...and is genuinely in flight, blocked
        _ = model.changeVideo(by: 1)              // run3 selected before run2's fetch landed

        downloader.release("f2")                  // the stale fetch is allowed to land...
        try await Task.sleep(nanoseconds: 50_000_000)  // ...give its guard check time to run
        XCTAssertNotEqual(
            model.status, "run2.mp4",
            "a stale fetch landing after the selection moved on must not overwrite the status"
        )

        downloader.release("f3")
        try await model.settleFetches()

        // `ClipCache` names cached files by a digest of the file id
        // (`StorageName.forIdentifier`), never the id itself, so which clip
        // actually loaded has to be confirmed by identity — a filename
        // substring check could never pass regardless of correctness, and
        // must not be weakened to "some file loaded": that would pass even
        // if f2, not f3, ended up on screen.
        XCTAssertEqual(model.currentClipIdentity, .remote(provider: "fake", fileID: "f3"),
                       "got \(String(describing: model.currentPlaybackURL))")
        XCTAssertFalse(model.isPreparingClip, "the flag must clear once both finish")
    }

    /// Task 3's provider-side 401 refresh does not cover this path: the bytes
    /// are fetched by `ClipCache`'s downloader, which has no provider to ask.
    /// A session past the hour mark could list the library fine and still
    /// fail to open a clip without this. Refused once, then given a fresh
    /// source, the clip must still land — and the assertion is on the number
    /// of attempts, not just eventual success, so an implementation with no
    /// retry at all cannot pass by coincidence.
    func testAnUnauthorisedDownloadIsRetriedOnceWithAFreshSource() async throws {
        let (model, provider, cache, downloader) = try remoteModelWithDownloader(files: fiveClips())
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )
        try await model.settleFetches()

        // f5 sits outside any neighbour window the initial selection (f1)
        // could have already touched, so this test owns its first attempt.
        downloader.errorToThrow = RemoteLibraryError.unauthorised
        downloader.errorThrowLimitByFileID["f5"] = 1

        _ = model.changeVideo(by: 4)          // jump straight to run5
        try await model.settleFetches()

        // `ClipCache` names cached files by a digest of the file id
        // (`StorageName.forIdentifier`), never the id itself, so the clip
        // actually loaded has to be confirmed by identity — a filename
        // substring check could never pass regardless of correctness.
        XCTAssertEqual(model.currentClipIdentity, .remote(provider: "fake", fileID: "f5"),
                       "got \(String(describing: model.currentPlaybackURL))")
        XCTAssertNotNil(model.currentPlaybackURL, "the clip must still land after one retry")
        XCTAssertEqual(downloader.requestedFileIDs.filter { $0 == "f5" }.count, 2,
                       "expected exactly two attempts (one refused, one retried), got \(downloader.requestedFileIDs)")
    }
}
