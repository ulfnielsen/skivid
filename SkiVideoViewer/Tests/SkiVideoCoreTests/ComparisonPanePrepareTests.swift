import XCTest
@testable import SkiVideoCore

/// `ComparisonModel.load(_:side:prepare:)` is the closure-shaped overload
/// `SecondaryScreenPresenter.presentComparison`'s `prepare` parameter reaches:
/// `ContentView` captures `ViewerModel.prepareClip` into that shape, and
/// `ClipSourceMenu` calls this exact method when the operator picks a clip
/// from the menu. These tests drive that closure directly — `{ choice in
/// await model.prepareClip(choice) }` — standing in for the capture
/// `ContentView` makes, so they exercise the real fetch-then-load sequence
/// without needing a rendered window.
///
/// `Tests/SkiVideoCoreTests/FetchOnSelectTests.swift` already covers the
/// sibling overload, `load(_:side:fetching:)`, which takes `ViewerModel`
/// directly rather than a closure. That overload is what the UI used to be
/// unable to reach without threading `ViewerModel` through six-plus files;
/// this one is what closes the gap without that.
@MainActor
final class ComparisonPanePrepareTests: XCTestCase {
    /// Every test here opens root id "d1"; see `FetchOnSelectTests` for why
    /// `RemoteLibraryIndex.storeRoot` must be redirected before that happens.
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

    /// The discriminating test for this whole task: picking a cloud clip
    /// nobody has touched yet must fetch it, not merely hand the pane the
    /// `gdrive://`-style library URL unchanged.
    ///
    /// Unlike `RemoteLibraryWiringTests.testTheComparisonPickerOffersAFileOnlyForAPreparedClip`,
    /// this clip is genuinely untouched going in — no `prepareCurrentClip`,
    /// no `changeVideo`, nothing that would fetch it as a side effect of
    /// browsing. The `XCTAssertFalse` right after building the fixture is
    /// what pins that down, so a change to `remoteModelWithDownloader` or
    /// `comparisonLibrary` that started prefetching everything could not
    /// make this test pass for the wrong reason.
    ///
    /// **Would fail if `load(_:side:prepare:)` loaded `choice.playbackURL`
    /// directly instead of awaiting `prepare(choice)` first** — exactly the
    /// gap this task exists to close. With that change, both assertions
    /// below fail together: the downloader never sees "f2", and the pane's
    /// URL is the library URL, not a file.
    func testChoosingAnUnpreparedCloudClipFetchesItThroughTheClosure() async throws {
        let (model, provider, cache, downloader) = try remoteModelWithDownloader(files: [
            remoteFile("f1", "run1.mp4", ["Neuss 2026", "Ada"]),
            remoteFile("f2", "run2.mp4", ["Neuss 2026", "Ada"]),
        ])
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )
        let choice = try XCTUnwrap(model.comparisonLibrary.first?.videos.last)
        XCTAssertFalse(
            choice.playbackURL.isFileURL,
            "the fixture must start unprepared, or this test proves nothing: got \(choice.playbackURL)"
        )

        let comparison = ComparisonModel()
        await comparison.load(choice, side: .left, prepare: ClipPreparer { await model.prepareClip($0) })

        XCTAssertTrue(downloader.requestedFileIDs.contains("f2"), "got \(downloader.requestedFileIDs)")
        XCTAssertEqual(comparison.playbackURL(for: .left)?.isFileURL, true)
    }

    /// The other half of the discriminating test: a clip that was never
    /// remote must load with no fetch at all, so closing the cloud gap does
    /// not quietly turn every pane selection into a network request.
    ///
    /// The model here has a real, reachable downloader — opened against a
    /// cloud library exactly as the test above — so "nothing was asked" is
    /// evidence about this clip's identity, not merely that no downloader
    /// happened to exist. The choice is built with `.local` identity and a
    /// URL that is already a file, standing in for a clip picked from local
    /// disk (or from a purely local library, where `ViewerModel.prepareClip`
    /// takes the same early-return path because there is no `remoteIndex` at
    /// all).
    ///
    /// **Would fail if `prepareClip`'s remote check were dropped or loosened**
    /// — e.g. if it stopped pattern-matching `choice.identity` against
    /// `.remote` and instead tried to resolve every choice through the
    /// remote index — the downloader would then be asked for a clip that
    /// never came from the cloud, and `requestedFileIDs` would be non-empty.
    func testChoosingALocalClipFetchesNothing() async throws {
        let (model, provider, cache, downloader) = try remoteModelWithDownloader(files: [
            remoteFile("f1", "run1.mp4", ["Neuss 2026", "Ada"]),
        ])
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )
        // Opening a cloud library auto-selects its first clip and fetches it,
        // which has nothing to do with the local choice below. Settled and
        // then subtracted, rather than ignored: this assertion used to read
        // `requestedFileIDs == []` and passed only because that fetch's `Task`
        // had not been given time to run by the time it ran — adding one
        // suspension point anywhere upstream made it fail. What the test means
        // is "the local choice asked for nothing", so it now says that.
        try await model.settleFetches()
        let requestedBeforeTheLocalChoice = downloader.requestedFileIDs
        let localFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mov")
        try Data().write(to: localFile)
        addTeardownBlock { try? FileManager.default.removeItem(at: localFile) }
        let choice = ComparisonVideoChoice(
            id: "local-pick",
            name: localFile.lastPathComponent,
            playbackURL: localFile,
            identity: ClipIdentity(localFile)
        )

        let comparison = ComparisonModel()
        await comparison.load(choice, side: .left, prepare: ClipPreparer { await model.prepareClip($0) })

        XCTAssertEqual(
            downloader.requestedFileIDs, requestedBeforeTheLocalChoice,
            "a local clip must not touch the downloader: got \(downloader.requestedFileIDs)"
        )
        XCTAssertEqual(comparison.playbackURL(for: .left), localFile)
    }
}
