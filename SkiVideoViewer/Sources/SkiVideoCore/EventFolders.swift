import Foundation

/// One entry in a library folder.
public struct FolderEntry: Equatable, Sendable {
    public let name: String
    public let isFolder: Bool

    public init(name: String, isFolder: Bool) {
        self.name = name
        self.isFolder = isFolder
    }
}

/// The folders of one library, addressed by names from its root — the seam
/// the event rename plans and writes through, so the same planner and runner
/// serve a Drive and a local library.
///
/// `rename` and `move` are no-ops when their source is already gone: that is
/// what makes a re-run after a partial failure finish the job instead of
/// failing on the steps that already happened. Neither ever overwrites.
public protocol EventFolderWriting: Sendable {
    /// Consent (Drive) or a writability check (local), before anything moves.
    func prepareToWrite() async throws
    func children(of path: [String]) async throws -> [FolderEntry]?
    func rename(_ path: [String], to newName: String) async throws
    func move(_ name: String, from source: [String], to destination: [String]) async throws
    /// Bins (Drive) or deletes (local) the folder only if it is empty *now*,
    /// checked here rather than trusted from a plan made earlier.
    func removeIfEmpty(_ path: [String]) async throws -> Bool
}

// MARK: - Local

public struct LocalEventFolders: EventFolderWriting {
    private let root: URL
    /// Test seam: runs between `removeIfEmpty`'s emptiness check and its
    /// final removal, to put a file there the way a sync or upload could.
    private let afterCheckingEmpty: (@Sendable (URL) -> Void)?

    public init(root: URL) { self.init(root: root, afterCheckingEmpty: nil) }

    init(root: URL, afterCheckingEmpty: (@Sendable (URL) -> Void)?) {
        self.root = root
        self.afterCheckingEmpty = afterCheckingEmpty
    }

    private func url(_ path: [String]) -> URL {
        path.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    public func prepareToWrite() async throws {
        guard FileManager.default.isWritableFile(atPath: root.path) else {
            throw RemoteUploadError.stopBatch(
                "“\(root.lastPathComponent)” is read-only, so its events cannot be renamed.")
        }
    }

    public func children(of path: [String]) async throws -> [FolderEntry]? {
        let folder = url(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ).map {
            FolderEntry(name: $0.lastPathComponent,
                        isFolder: (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
        }.sorted { $0.name < $1.name }
    }

    public func rename(_ path: [String], to newName: String) async throws {
        let source = url(path)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let destination = source.deletingLastPathComponent().appendingPathComponent(newName, isDirectory: true)
        if source.lastPathComponent.caseInsensitiveCompare(newName) == .orderedSame {
            // On a case-insensitive volume the destination "exists" because it
            // is the source, so the overwrite guard below would refuse a
            // case-only rename. Measured on this Mac's APFS volume: a single
            // moveItem(Hochybrig -> HochYbrig) succeeds. An earlier two-move
            // route through a hidden temporary name could strand the event
            // under that name if the second move failed or the app was
            // killed, and hidden folders are skipped by `children` and the
            // library scan, so the clips would vanish.
            try FileManager.default.moveItem(at: source, to: destination)
            return
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw RemoteUploadError.stopBatch("“\(newName)” already exists, so nothing was overwritten.")
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    public func move(_ name: String, from source: [String], to destination: [String]) async throws {
        let from = url(source).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: from.path) else { return }
        let to = url(destination).appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: to.path) else {
            throw RemoteUploadError.stopBatch("“\(name)” is already in the target, so nothing was overwritten.")
        }
        try FileManager.default.moveItem(at: from, to: to)
    }

    /// Hidden entries are listed here (unlike `children`), so anything hidden
    /// that is not known clutter (a user's dot-file, an iCloud `.name.icloud`
    /// placeholder for a clip not yet downloaded) keeps the folder.
    ///
    /// Nothing here deletes recursively. Clutter is only a *regular file*
    /// named `.DS_Store` or `._*`; a `._x` directory may hold anything, so it
    /// keeps the folder. The folder itself goes with `rmdir`, which refuses a
    /// non-empty folder: a clip that lands between the listing and the removal
    /// (an upload, a sync) survives. The final review measured the difference
    /// on this state — listed empty, then `IMG_1.MOV` written — `removeItem`
    /// deleted the clip, `rmdir` returned -1 ENOTEMPTY and it survived.
    public func removeIfEmpty(_ path: [String]) async throws -> Bool {
        let folder = url(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        let entries = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        let isClutter: (URL) -> Bool = { entry in
            let name = entry.lastPathComponent
            guard name == ".DS_Store" || name.hasPrefix("._") else { return false }
            return (try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
        guard entries.allSatisfy(isClutter) else { return false }
        for entry in entries where unlink(entry.path) != 0 && errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        afterCheckingEmpty?(folder)
        guard rmdir(folder.path) == 0 else {
            let code = errno
            // Something arrived (POSIX allows EEXIST for this too), or someone
            // else already removed it: either way, nothing of ours to delete.
            if code == ENOTEMPTY || code == EEXIST || code == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return true
    }
}

// MARK: - Drive

public struct DriveEventFolders: EventFolderWriting {
    private let writer: any ItemUpdatable
    private let rootID: String
    private let presenter: OAuthPresenter

    public init(writer: any ItemUpdatable, rootID: String, presenter: OAuthPresenter) {
        self.writer = writer
        self.rootID = rootID
        self.presenter = presenter
    }

    public func prepareToWrite() async throws {
        try await writer.authorizeWrites(presenter: presenter)
    }

    /// Walks names to an id from the root; nil when any step is missing.
    private func folderID(_ path: [String]) async throws -> String? {
        var current = rootID
        for name in path {
            guard let next = try await writer.findFolder(named: name, parent: current) else { return nil }
            current = next.id
        }
        return current
    }

    public func children(of path: [String]) async throws -> [FolderEntry]? {
        guard let id = try await folderID(path) else { return nil }
        return try await writer.listChildren(of: id).map { FolderEntry(name: $0.name, isFolder: $0.isFolder) }
    }

    public func rename(_ path: [String], to newName: String) async throws {
        guard let id = try await folderID(path) else { return }
        // Drive allows duplicate names, so without this a rename onto an
        // existing name would create twin folders. The id test lets a
        // case-only rename of the folder itself through.
        if let parentID = try await folderID(Array(path.dropLast())),
           let existing = try await writer.findFolder(named: newName, parent: parentID),
           existing.id != id {
            throw RemoteUploadError.stopBatch("“\(newName)” already exists, so nothing was overwritten.")
        }
        try await writer.rename(itemID: id, to: newName)
    }

    public func move(_ name: String, from source: [String], to destination: [String]) async throws {
        guard let from = try await folderID(source),
              let item = try await writer.listChildren(of: from).first(where: { $0.name == name })
        else { return }
        guard let to = try await folderID(destination) else {
            throw RemoteUploadError.retryClip("The target folder for “\(name)” was not found.")
        }
        if try await writer.listChildren(of: to).contains(where: { $0.name == name }) {
            throw RemoteUploadError.stopBatch("“\(name)” is already in the target, so nothing was overwritten.")
        }
        try await writer.move(itemID: item.id, from: from, to: to)
    }

    public func removeIfEmpty(_ path: [String]) async throws -> Bool {
        guard let id = try await folderID(path), try await writer.listChildren(of: id).isEmpty else {
            return false
        }
        try await writer.trash(itemID: id)
        return true
    }
}
