import Foundation
@testable import SkiVideoCore

/// An in-memory Drive for the upload batch: a tree of folders and files that
/// `find…`, `create…` and `upload` read and write, with knobs to make one
/// clip's upload throw or hang. Locked rather than an actor so the
/// protocol's plain `async` methods can be called from any context, the way
/// `GoogleDriveProvider`'s are.
final class FakeDriveWriter: ItemCreatable, @unchecked Sendable {
    static let identifier = "fake-writer"

    private let lock = NSLock()
    private var folders: [String: (name: String, parent: String)] = [:]
    private var files: [(id: String, name: String, parent: String)] = []
    private var nextID = 0
    private var _uploadErrors: [String: [Error]] = [:]
    private var _findFolderErrors: [String: Error] = [:]
    private var _authorizeCount = 0
    private var _uploadedNames: [String] = []
    private var _createdFolderNames: [String] = []
    private var _hangingUpload: String?
    private var _uploadStarted: Set<String> = []

    var authorizeError: Error?

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    // MARK: Arranging

    /// Errors `upload` throws for a file name, one per attempt, in order.
    func failUpload(of name: String, with errors: Error...) {
        locked { _uploadErrors[name, default: []].append(contentsOf: errors) }
    }

    /// `findFolder` for this name throws, standing in for the 403 that Drive's
    /// find path reports as an untyped `.api`.
    func failFindFolder(named name: String, with error: Error) {
        locked { _findFolderErrors[name] = error }
    }

    /// `upload` of this name waits until its task is cancelled.
    func hangUpload(of name: String) { locked { _hangingUpload = name } }

    /// Puts a file at `path` (folder names under `root`), creating folders.
    func seedFile(_ name: String, at path: [String], root: String = "root-1") {
        locked {
            var parent = root
            for component in path {
                parent = folderIDLocked(named: component, parent: parent)
                    ?? createFolderLocked(named: component, parent: parent)
            }
            files.append((id: mintLocked("file"), name: name, parent: parent))
        }
    }

    // MARK: Reading back

    var authorizeCount: Int { locked { _authorizeCount } }
    var uploadedNames: [String] { locked { _uploadedNames } }
    var createdFolderNames: [String] { locked { _createdFolderNames } }
    func uploadHasStarted(_ name: String) -> Bool { locked { _uploadStarted.contains(name) } }

    /// Folder names from `root` down to where `name` lives, or nil.
    func path(ofFile name: String, root: String = "root-1") -> [String]? {
        locked {
            guard let file = files.first(where: { $0.name == name }) else { return nil }
            var path: [String] = []
            var current = file.parent
            while current != root {
                guard let folder = folders[current] else { return nil }
                path.insert(folder.name, at: 0)
                current = folder.parent
            }
            return path
        }
    }

    func fileCount(named name: String) -> Int { locked { files.filter { $0.name == name }.count } }

    // MARK: ItemCreatable

    func authorizeWrites(presenter: OAuthPresenter) async throws {
        locked { _authorizeCount += 1 }
        if let authorizeError { throw authorizeError }
    }

    func findFolder(named name: String, parent parentID: String) async throws -> RemoteItem? {
        try locked {
            if let error = _findFolderErrors[name] { throw error }
            return folderIDLocked(named: name, parent: parentID).map { RemoteItem(id: $0, name: name) }
        }
    }

    func findFile(named name: String, parent parentID: String) async throws -> RemoteItem? {
        locked {
            files.first { $0.name == name && $0.parent == parentID }.map { RemoteItem(id: $0.id, name: $0.name) }
        }
    }

    func createFolder(named name: String, parent parentID: String) async throws -> RemoteItem {
        locked {
            _createdFolderNames.append(name)
            return RemoteItem(id: createFolderLocked(named: name, parent: parentID), name: name)
        }
    }

    func findOrCreateFolder(named name: String, parent parentID: String) async throws -> RemoteItem {
        if let existing = try await findFolder(named: name, parent: parentID) { return existing }
        return try await createFolder(named: name, parent: parentID)
    }

    func upload(fileAt url: URL, named name: String, parent parentID: String) async throws -> RemoteItem {
        let (error, hangs): (Error?, Bool) = locked {
            _uploadStarted.insert(name)
            let error = _uploadErrors[name]?.isEmpty == false ? _uploadErrors[name]!.removeFirst() : nil
            return (error, _hangingUpload == name)
        }
        if let error { throw error }
        if hangs {
            // Rethrows CancellationError, as the real upload does.
            while true { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        precondition(FileManager.default.fileExists(atPath: url.path), "uploading a missing file")
        return locked {
            _uploadedNames.append(name)
            let id = mintLocked("file")
            files.append((id: id, name: name, parent: parentID))
            return RemoteItem(id: id, name: name)
        }
    }

    // MARK: RemoteLibraryProvider (reading, for opening it as a library)

    /// What the drive lists when opened as a library through `ViewerModel`.
    var listedFiles: [RemoteFile] = []

    func connect(presenter: OAuthPresenter) async throws {}
    func roots() async throws -> [RemoteFolder] { [RemoteFolder(id: "drive-1", name: "Club")] }
    func enumerate(_ folder: RemoteFolder) -> AsyncThrowingStream<RemoteFile, Error> {
        let files = listedFiles
        return AsyncThrowingStream { continuation in
            files.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
    func downloadSource(for file: RemoteFile) async throws -> DownloadSource {
        throw RemoteLibraryError.api("not a reading fake")
    }

    // MARK: Locked helpers

    private func mintLocked(_ prefix: String) -> String {
        nextID += 1
        return "\(prefix)-\(nextID)"
    }

    private func folderIDLocked(named name: String, parent: String) -> String? {
        folders.filter { $0.value.name == name && $0.value.parent == parent }.keys.sorted().first
    }

    private func createFolderLocked(named name: String, parent: String) -> String {
        let id = mintLocked("folder")
        folders[id] = (name, parent)
        return id
    }
}
