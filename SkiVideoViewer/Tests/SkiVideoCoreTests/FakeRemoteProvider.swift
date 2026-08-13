import Foundation
@testable import SkiVideoCore

/// Stands in for a cloud source with no network of any kind. Every test that
/// needs a library of files uses this rather than `GoogleDriveProvider`.
final class FakeRemoteProvider: RemoteLibraryProvider, @unchecked Sendable {
    static let identifier = "fake"

    var files: [RemoteFile]
    /// Not named `roots` — a stored property cannot share its name with the
    /// protocol method that returns it.
    var rootsToReturn: [RemoteFolder] = [RemoteFolder(id: "root", name: "Test Drive")]
    /// Throws after this many files have been yielded. Nil never throws.
    var errorAfter: Int?
    var downloadURL = URL(string: "https://example.invalid/bytes")!
    var headers: [String: String] = ["Authorization": "Bearer test"]
    /// Thrown by `connect`, so a test can exercise a refused sign-in without
    /// a network or a real Google account.
    var connectError: Error?
    private(set) var connectCallCount = 0
    private(set) var downloadSourceCallCount = 0

    init(files: [RemoteFile] = []) {
        self.files = files
    }

    func connect(presenter: OAuthPresenter) async throws {
        if let connectError {
            throw connectError
        }
        connectCallCount += 1
    }

    func roots() async throws -> [RemoteFolder] { rootsToReturn }

    func enumerate(_ folder: RemoteFolder) -> AsyncThrowingStream<RemoteFile, Error> {
        AsyncThrowingStream { continuation in
            for (offset, file) in files.enumerated() {
                if let errorAfter, offset >= errorAfter {
                    continuation.finish(throwing: RemoteLibraryError.api("fake enumeration failure"))
                    return
                }
                continuation.yield(file)
            }
            continuation.finish()
        }
    }

    func downloadSource(for file: RemoteFile) async throws -> DownloadSource {
        downloadSourceCallCount += 1
        return DownloadSource(url: downloadURL, headers: headers)
    }
}
