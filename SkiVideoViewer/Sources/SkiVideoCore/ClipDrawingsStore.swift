import Foundation

public enum ClipDrawingsLoad: Equatable, Sendable {
    case none
    case drawings(ClipDrawings)
    /// Present but not parseable by this version — damaged, hand-edited, or
    /// written by a newer app. Never overwritten.
    case unreadable
}

public enum ClipDrawingsStoreError: Error, Equatable {
    case wouldOverwriteUnreadable
}

/// Reads and writes `<stem>.skidrawings.json`, shaped like
/// `ClipAnalysisStore`: beside a local clip so it travels with the footage
/// (and moves with it on an event rename, which carries every `<stem>.` file),
/// in the keyed store for a Drive clip, which has no folder of its own here.
public enum ClipDrawingsStore {
    public static let fileExtension = "skidrawings.json"

    public static func fileURL(for identity: ClipIdentity) -> URL {
        switch identity {
        case let .local(clip):
            return clip.deletingPathExtension().appendingPathExtension(fileExtension)
        case .remote:
            return ClipIdentity.keyedStoreRoot
                .appendingPathComponent(identity.pairKey)
                .appendingPathExtension(fileExtension)
        }
    }

    public static func load(for identity: ClipIdentity) -> ClipDrawingsLoad {
        let url = fileURL(for: identity)
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        guard let data = try? Data(contentsOf: url),
              let drawings = try? JSONDecoder().decode(ClipDrawings.self, from: data),
              drawings.version <= ClipDrawings.currentVersion
        else { return .unreadable }
        return .drawings(drawings)
    }

    /// Atomic. An empty set deletes the file rather than leaving `[]` behind.
    /// Refuses to replace or delete a file `load` could not read: it may be a
    /// newer version's, and this one cannot know what it would destroy.
    public static func save(_ drawings: ClipDrawings, for identity: ClipIdentity) throws {
        if load(for: identity) == .unreadable { throw ClipDrawingsStoreError.wouldOverwriteUnreadable }
        let url = fileURL(for: identity)
        if drawings.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        if identity.storeKey != nil {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(drawings).write(to: url, options: .atomic)
    }
}
