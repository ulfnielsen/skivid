import XCTest
@testable import SkiVideoCore

@MainActor
final class RemoteAnalysisIdentityTests: XCTestCase {
    /// Two tests here open root id "d1", and `openRemoteLibrary` now saves and
    /// loads an index for it. Without redirecting `RemoteLibraryIndex.storeRoot`
    /// away from the real Application Support directory, the second test would
    /// find the first one's stored index and skip its sweep.
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

    /// A cloud clip's analysis must be keyed on the clip, not on wherever its
    /// bytes happen to sit. The cache path is under `Caches`, which eviction
    /// reclaims and iOS may purge outright — a sidecar written there is gone
    /// the first time the budget is tight.
    ///
    /// This fails if `currentClipIdentity` returns `.local(playbackURL)`: the
    /// assertion names the remote case explicitly rather than checking "not
    /// nil", so returning the cache path cannot satisfy it.
    func testACloudClipIsIdentifiedByItsFileIDNotItsCachePath() async throws {
        let (model, provider, cache) = try remoteModel(
            files: [remoteFile("1AbC", "run.mp4", ["Neuss 2026", "Ada"])]
        )
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )
        try await model.prepareCurrentClip()

        // The clip really is cached — otherwise this test would pass simply
        // because nothing had been downloaded.
        XCTAssertEqual(model.currentPlaybackURL?.isFileURL, true)
        XCTAssertEqual(
            model.currentClipIdentity,
            .remote(provider: "fake", fileID: "1AbC")
        )
    }

    /// A local clip must still be identified by its own URL — the change must
    /// not route local analysis through anything new.
    func testALocalClipIsStillIdentifiedByItsOwnURL() throws {
        let (model, root) = try localModel(clipNamed: "run1.mp4")
        model.openDirectory(root)

        let identity = try XCTUnwrap(model.currentClipIdentity)
        guard case let .local(url) = identity else {
            return XCTFail("expected .local, got \(identity)")
        }
        XCTAssertEqual(url.lastPathComponent, "run1.mp4")
    }

    /// The comparison window is where the defect actually bit: it reads a
    /// per-side URL and hands it straight to the analysis stores. Each side
    /// must carry its identity so it never has to derive one from a path.
    func testEachComparisonSideCarriesItsOwnIdentity() async throws {
        let (model, provider, cache) = try remoteModel(files: [
            remoteFile("a", "run1.mp4", ["Neuss 2026", "Ada"]),
            remoteFile("b", "run2.mp4", ["Neuss 2026", "Ada"]),
        ])
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )

        let choices = try XCTUnwrap(model.comparisonLibrary.first?.videos)
        XCTAssertEqual(
            choices.map(\.identity),
            [.remote(provider: "fake", fileID: "a"), .remote(provider: "fake", fileID: "b")]
        )
    }
}
