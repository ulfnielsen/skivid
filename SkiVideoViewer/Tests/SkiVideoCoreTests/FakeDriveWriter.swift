import Foundation
@testable import SkiVideoCore

/// An in-memory Drive for the upload batch: a tree of folders and files that
/// `find…`, `create…` and `upload` read and write, with knobs to make one
/// clip's upload throw or hang. Locked rather than an actor so the
/// protocol's plain `async` methods can be called from any context, the way
/// `GoogleDriveProvider`'s are.
final class FakeDriveWriter: ItemUpdatable, IncrementallyEnumerable, @unchecked Sendable {
    static let identifier = "fake-writer"

    private let lock = NSLock()
    private var folders: [String: (name: String, parent: String)] = [:]
    /// `size` is what Drive's `files.list` reports in its `size` field — nil
    /// for an item it gives none for.
    private var files: [(id: String, name: String, parent: String, size: Int64?)] = []
    private var nextID = 0
    private var _uploadErrors: [String: [Error]] = [:]
    private var _findFolderErrors: [String: Error] = [:]
    private var _authorizeCount = 0
    private var _uploadedNames: [String] = []
    private var _createdFolderNames: [String] = []
    private var _findFolderNames: [String] = []
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

    /// Later uploads go through again, as when the signal comes back.
    func stopHanging() { locked { _hangingUpload = nil } }

    /// Puts a file at `path` (folder names under `root`), creating folders.
    /// `size` defaults to 10, the size `UploadBatchModelTests.sortedClip`
    /// writes by default, so a seeded twin of a default clip is the same clip.
    func seedFile(_ name: String, at path: [String], root: String = "root-1", size: Int64? = 10) {
        locked {
            var parent = root
            for component in path {
                parent = folderIDLocked(named: component, parent: parent)
                    ?? createFolderLocked(named: component, parent: parent)
            }
            files.append((id: mintLocked("file"), name: name, parent: parent, size: size))
        }
    }

    // MARK: Reading back

    var authorizeCount: Int { locked { _authorizeCount } }
    var uploadedNames: [String] { locked { _uploadedNames } }
    var createdFolderNames: [String] { locked { _createdFolderNames } }
    /// Every name `findFolder` was asked about, in order.
    var findFolderNames: [String] { locked { _findFolderNames } }
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
            _findFolderNames.append(name)
            if let error = _findFolderErrors[name] { throw error }
            return folderIDLocked(named: name, parent: parentID).map { RemoteItem(id: $0, name: name) }
        }
    }

    func findFile(named name: String, parent parentID: String) async throws -> RemoteItem? {
        locked {
            files.first { $0.name == name && $0.parent == parentID }
                .map { RemoteItem(id: $0.id, name: $0.name, size: $0.size) }
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
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
            files.append((id: id, name: name, parent: parentID, size: size))
            return RemoteItem(id: id, name: name, size: size)
        }
    }

    // MARK: ItemUpdatable

    private var _trashedIDs: [String] = []
    var trashedIDs: [String] { locked { _trashedIDs } }

    func listChildren(of folderID: String) async throws -> [RemoteChild] {
        locked {
            let subfolders = folders.filter { $0.value.parent == folderID && !_trashedIDs.contains($0.key) }
                .map { RemoteChild(id: $0.key, name: $0.value.name, isFolder: true) }
            let contained = files.filter { $0.parent == folderID && !_trashedIDs.contains($0.id) }
                .map { RemoteChild(id: $0.id, name: $0.name, isFolder: false) }
            return (subfolders + contained).sorted { $0.name < $1.name }
        }
    }

    func rename(itemID: String, to newName: String) async throws {
        locked {
            if let folder = folders[itemID] { folders[itemID] = (newName, folder.parent) }
            if let index = files.firstIndex(where: { $0.id == itemID }) { files[index].name = newName }
        }
    }

    func move(itemID: String, from oldParentID: String, to newParentID: String) async throws {
        locked {
            if let folder = folders[itemID] { folders[itemID] = (folder.name, newParentID) }
            if let index = files.firstIndex(where: { $0.id == itemID }) { files[index].parent = newParentID }
        }
    }

    func trash(itemID: String) async throws { locked { _trashedIDs.append(itemID) } }

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
    private var _downloadRequests: [String] = []
    /// File ids `downloadSource` was asked for — one per fetch the viewer
    /// started, which is how a test counts fetches.
    var downloadRequests: [String] { locked { _downloadRequests } }
    func resetDownloadRequests() { locked { _downloadRequests = [] } }

    func downloadSource(for file: RemoteFile) async throws -> DownloadSource {
        locked { _downloadRequests.append(file.id) }
        throw RemoteLibraryError.api("not a reading fake")
    }

    // MARK: IncrementallyEnumerable (so a reopen goes through the change feed)

    /// The page the next reopen reads; nil reports nothing changed.
    var nextChanges: RemoteLibraryChanges?
    func startCursor(forRoot rootID: String) async throws -> String { "c1" }
    private var _changesRequestedSince: [String] = []
    /// The cursor each `changes` call was asked from, in order.
    var changesRequestedSince: [String] { locked { _changesRequestedSince } }
    func changes(since cursor: String, forRoot rootID: String) async throws -> RemoteLibraryChanges {
        locked { _changesRequestedSince.append(cursor) }
        return nextChanges ?? RemoteLibraryChanges(changed: [], removed: [], cursor: cursor)
    }

    // MARK: Locked helpers

    private func mintLocked(_ prefix: String) -> String {
        nextID += 1
        return "\(prefix)-\(nextID)"
    }

    private func folderIDLocked(named name: String, parent: String) -> String? {
        folders.filter { $0.value.name == name && $0.value.parent == parent && !_trashedIDs.contains($0.key) }.keys.sorted().first
    }

    private func createFolderLocked(named name: String, parent: String) -> String {
        let id = mintLocked("folder")
        folders[id] = (name, parent)
        return id
    }
}
