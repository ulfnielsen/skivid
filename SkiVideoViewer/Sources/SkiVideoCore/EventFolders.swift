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

    public init(root: URL) { self.root = root }

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
            // Review Focus 1: on a case-insensitive volume the destination
            // "exists" because it is the source. Two moves, via a name no
            // one else uses.
            let step = source.deletingLastPathComponent()
                .appendingPathComponent(".rename-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.moveItem(at: source, to: step)
            try FileManager.default.moveItem(at: step, to: destination)
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

    public func removeIfEmpty(_ path: [String]) async throws -> Bool {
        guard let children = try await children(of: path), children.isEmpty else { return false }
        try FileManager.default.removeItem(at: url(path))
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
