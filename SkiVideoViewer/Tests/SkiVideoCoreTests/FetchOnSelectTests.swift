import XCTest
@testable import SkiVideoCore

@MainActor
final class FetchOnSelectTests: XCTestCase {
    private func fiveClips() -> [RemoteFile] {
        (1...5).map { remoteFile("f\($0)", "run\($0).mp4", ["Neuss 2026", "Ada"]) }
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
    /// Selecting clip 3 of 5 must leave clip 5 alone. A test asserting only
    /// that the neighbours *were* fetched would pass an implementation that
    /// fetched the whole athlete, which on a 74 GB library is the difference
    /// between a warm cache and a flooded connection.
    func testPrefetchReachesTheNeighboursAndNoFurther() async throws {
        let (model, provider, cache, downloader) = try remoteModelWithDownloader(files: fiveClips())
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )

        _ = model.changeVideo(by: 2)          // now on run3
        try await model.settleFetches()

        let fetched = Set(downloader.requestedFileIDs)
        XCTAssertTrue(fetched.isSuperset(of: ["f2", "f3", "f4"]), "got \(fetched)")
        XCTAssertFalse(fetched.contains("f5"), "prefetch reached too far: \(fetched)")
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
    /// download happened to finish last. The gate holds the first fetch open
    /// past the second selection, which is the ordering that would otherwise
    /// leave the wrong clip on screen.
    func testMovingTwiceQuicklyLoadsTheClipSelectedLast() async throws {
        let (model, provider, cache, downloader) = try remoteModelWithDownloader(files: fiveClips())
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )
        downloader.shouldWait = true

        _ = model.changeVideo(by: 1)          // run2, blocked
        _ = model.changeVideo(by: 1)          // run3, blocked
        downloader.release("f2")              // the stale one finishes first
        downloader.release("f3")
        try await model.settleFetches()

        XCTAssertEqual(model.currentPlaybackURL?.lastPathComponent.contains("f3"), true,
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
