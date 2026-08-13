import Foundation
@testable import SkiVideoCore

/// Shared setup for tests that drive a `ViewerModel` against either a fake
/// remote library or a real local one.
///
/// Extracted from `RemoteLibraryWiringTests`, which had this exact setup
/// before `RemoteAnalysisIdentityTests` (in the `SkiVideoViewerTests` target)
/// needed the same shape. Each call gets its own fresh temporary directory
/// rather than sharing one across a test case's lifetime, so there is no
/// `setUp`/`tearDown` for a caller to wire up — and no directory for two
/// callers to collide in.
@MainActor
func remoteModel(
    files: [RemoteFile]
) throws -> (ViewerModel, FakeRemoteProvider, ClipCache) {
    let (model, provider, cache, _) = try remoteModelWithDownloader(files: files)
    return (model, provider, cache)
}

/// Same as `remoteModel`, plus the `FakeClipDownloader` behind the cache, so a
/// test can assert on what was actually fetched — not just what the model's
/// published state claims.
@MainActor
func remoteModelWithDownloader(
    files: [RemoteFile]
) throws -> (ViewerModel, FakeRemoteProvider, ClipCache, FakeClipDownloader) {
    let provider = FakeRemoteProvider(files: files)
    let downloader = FakeClipDownloader()
    let cache = ClipCache(
        root: try freshTemporaryDirectory(), downloader: downloader, budget: 1_000_000
    )
    let model = ViewerModel(
        input: FakeInputSource(), folderPicker: FakeFolderPicker(), oauthPresenter: FakeOAuthPresenter()
    )
    return (model, provider, cache, downloader)
}

/// A `ViewerModel` over a local directory holding one clip, loose at the top
/// of it — `VideoLibrary.scan` groups a clip there under the root's own name,
/// so this needs no nested athlete/event folders to be a valid library.
@MainActor
func localModel(clipNamed name: String) throws -> (ViewerModel, URL) {
    let root = try freshTemporaryDirectory()
    try Data().write(to: root.appendingPathComponent(name))
    let model = ViewerModel(
        input: FakeInputSource(), folderPicker: FakeFolderPicker(), oauthPresenter: FakeOAuthPresenter()
    )
    return (model, root)
}

func remoteFile(_ id: String, _ name: String, _ path: [String]) -> RemoteFile {
    RemoteFile(id: id, name: name, path: path, size: 100, contentVersion: "v1", md5: nil)
}

/// A directory that exists and is unique to this call, so `remoteModel` and
/// `localModel` never share one and nothing has to remember to delete it
/// afterwards — it sits under the system's own temporary directory, which the
/// OS is responsible for reclaiming.
private func freshTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
