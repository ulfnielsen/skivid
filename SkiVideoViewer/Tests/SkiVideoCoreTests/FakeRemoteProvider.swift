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
    /// Thrown by `roots()`, so a test can exercise a session that was resumed
    /// or connected successfully and then could not list the drives — a
    /// different outcome from having nothing to resume, and one the sheet must
    /// not swallow.
    var rootsError: Error?
    /// What `resumeSession()` answers. False by default: a fake with nothing
    /// arranged has no previous session, which is the honest answer and the
    /// state most tests want.
    var canResumeSession = false
    private(set) var resumeCallCount = 0
    private(set) var connectCallCount = 0
    private(set) var downloadSourceCallCount = 0
    /// How many times `enumerate` was called — a full sweep. The relaunch
    /// tests assert this stays at 1 across a second `openRemoteLibrary`, which
    /// is the only thing that distinguishes a delta from a re-sweep that
    /// happens to agree with the stored index.
    private(set) var enumerateCallCount = 0
    /// Bumped by `startCursor`, so each call mints a distinguishable token
    /// ("cursor-1", "cursor-2", …) rather than a fixed string that would hide
    /// a test calling it more than once.
    var cursorsIssued = 0
    /// Every cursor `changes(since:forRoot:)` was asked to resume from, in
    /// call order.
    private(set) var changesRequestedSince: [String] = []
    /// What `changes(since:forRoot:)` hands back. Nil means "nothing
    /// changed", answered with the same cursor it was asked to resume from —
    /// the honest default for a test that never sets this.
    var pendingChanges: RemoteLibraryChanges?
    /// Every file id `replaceContents` was asked to overwrite, in call order.
    /// The assertion that the repair keeps a clip's identity is made on this:
    /// a delete-and-reupload would show a different id, or none.
    private(set) var replacedFileIDs: [String] = []
    /// How many times the write upgrade was requested.
    private(set) var authorizeWritesCallCount = 0
    /// Thrown by `authorizeWrites`, for a coach who declines the consent
    /// screen — distinct from being refused by the drive afterwards.
    var authorizeWritesError: Error?
    /// Thrown by `replaceContents`, for the view-only-permission case.
    var replaceError: Error?
    /// The new content version a replacement reports — Drive's
    /// `headRevisionId`, which is what makes the cache drop the old bytes.
    var replacementVersion: String? = "rev-after-repair"

    init(files: [RemoteFile] = []) {
        self.files = files
    }

    func connect(presenter: OAuthPresenter) async throws {
        if let connectError {
            throw connectError
        }
        connectCallCount += 1
    }

    func resumeSession() async -> Bool {
        resumeCallCount += 1
        return canResumeSession
    }

    func roots() async throws -> [RemoteFolder] {
        if let rootsError { throw rootsError }
        return rootsToReturn
    }

    func enumerate(_ folder: RemoteFolder) -> AsyncThrowingStream<RemoteFile, Error> {
        enumerateCallCount += 1
        return AsyncThrowingStream { continuation in
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

/// The write half. Separate conformance because `ContentReplaceable` is a
/// separate protocol — a provider can be readable and not writable, which is
/// the everyday case for a coach without edit access to the club's drive.
extension FakeRemoteProvider: ContentReplaceable {
    func authorizeWrites(presenter: OAuthPresenter) async throws {
        if let authorizeWritesError { throw authorizeWritesError }
        authorizeWritesCallCount += 1
    }

    func replaceContents(ofFileID fileID: String, withFileAt url: URL) async throws -> String? {
        if let replaceError { throw replaceError }
        replacedFileIDs.append(fileID)
        return replacementVersion
    }
}

extension FakeRemoteProvider: IncrementallyEnumerable {
    func startCursor(forRoot rootID: String) async throws -> String {
        cursorsIssued += 1
        return "cursor-\(cursorsIssued)"
    }

    func changes(since cursor: String, forRoot rootID: String) async throws -> RemoteLibraryChanges {
        changesRequestedSince.append(cursor)
        return pendingChanges ?? RemoteLibraryChanges(changed: [], removed: [], cursor: cursor)
    }
}
