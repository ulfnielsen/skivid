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

        XCTAssertEqual(model.currentPlaybackURL, clip)
    }

    /// The comparison window gets the same treatment — a pane must never be
    /// handed a remote URL.
    func testTheComparisonPickerOffersOnlyLocalURLs() async throws {
        let (model, provider, cache) = self.model(files: [
            file("a", "run1.mp4", ["Neuss 2026", "Ada"]),
        ])
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )
        try await model.prepareCurrentClip()

        let choice = try XCTUnwrap(model.comparisonLibrary.first?.videos.first)
        XCTAssertTrue(choice.playbackURL.isFileURL, "got \(choice.playbackURL)")
    }
}
