import XCTest
@testable import SkiVideoCore

@MainActor
final class RemoteLibraryWiringTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func model(files: [RemoteFile]) -> (ViewerModel, FakeRemoteProvider, ClipCache) {
        let provider = FakeRemoteProvider(files: files)
        let cache = ClipCache(root: root, downloader: FakeClipDownloader(), budget: 1_000_000)
        let model = ViewerModel(
            input: FakeInputSource(),
            folderPicker: FakeFolderPicker(),
            oauthPresenter: FakeOAuthPresenter()
        )
        return (model, provider, cache)
    }

    private func file(_ id: String, _ name: String, _ path: [String]) -> RemoteFile {
        RemoteFile(id: id, name: name, path: path, size: 100, contentVersion: "v1", md5: nil)
    }

    func testOpeningARemoteLibraryFillsTheSidebar() async throws {
        let (model, provider, cache) = self.model(files: [
            file("a", "run1.mp4", ["Neuss 2026", "Ada"]),
            file("b", "run1.mp4", ["Neuss 2026", "Bea"]),
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
        let (model, provider, cache) = self.model(files: [
            file("a", "run1.mp4", ["Neuss 2026", "Ada"]),
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
        let (model, provider, cache) = self.model(files: [
            file("a", "run1.mp4", ["Neuss 2026", "Ada"]),
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

        let (model, _, _) = self.model(files: [])
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

    /// A prepared clip resolves to a file for the comparison window; an
    /// unprepared one does not, and today the picker hands out the library URL
    /// for it.
    ///
    /// That second half is pinned deliberately rather than claimed otherwise.
    /// `ComparisonVideoChoice.playbackURL` is non-optional, so there is nothing
    /// honest to put there until plan 3 fetches a clip when a pane selects it —
    /// and a test asserting "only local URLs" would be false the moment a
    /// library has more than one clip. When plan 3 lands, the second assertion
    /// is the one that changes.
    func testTheComparisonPickerOffersAFileOnlyForAPreparedClip() async throws {
        let (model, provider, cache) = self.model(files: [
            file("a", "run1.mp4", ["Neuss 2026", "Ada"]),
            file("b", "run2.mp4", ["Neuss 2026", "Ada"]),
        ])
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )
        try await model.prepareCurrentClip()

        let choices = try XCTUnwrap(model.comparisonLibrary.first?.videos)
        XCTAssertEqual(choices.count, 2)
        XCTAssertTrue(
            choices[0].playbackURL.isFileURL,
            "the prepared clip must be a file: got \(choices[0].playbackURL)"
        )
        XCTAssertFalse(
            choices[1].playbackURL.isFileURL,
            """
            KNOWN GAP, pinned on purpose: an unprepared clip is still offered its \
            library URL, which no player can open. Plan 3 must fetch a clip when a \
            pane selects it. If this assertion starts failing, that work has landed \
            and this test should assert both are files.
            """
        )
    }
}
