import Foundation

/// What renaming one event will do, worked out from the folders as they are
/// *now* — so planning again after a partial run yields only what is left.
public struct EventRenamePlan: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case rename([String], to: String)
        case move(String, from: [String], to: [String])
        case removeIfEmpty([String])
    }

    public var steps: [Step] = []
    /// Files that stay where they are because the target already holds the
    /// same name — a clip together with its sidecars. Never overwritten.
    public var leftInPlace: [[String]] = []
    /// True when the new name already exists somewhere this rename touches,
    /// which is what the "Merge?" question is about.
    public var mergesIntoExisting = false
}

public enum EventRenamePlanner {
    /// - Parameter eventFolders: every folder of the event, as names from the
    ///   library root (one for an event-first library, one per athlete for an
    ///   athlete-first one).
    public static func plan(
        eventFolders: [[String]], newName: String, in folders: any EventFolderWriting
    ) async throws -> EventRenamePlan {
        var plan = EventRenamePlan()
        for path in eventFolders.sorted(by: { $0.joined(separator: "/") < $1.joined(separator: "/") }) {
            guard let oldName = path.last, oldName != newName,
                  try await folders.children(of: path) != nil else { continue }
            let parent = Array(path.dropLast())
            let siblings = try await folders.children(of: parent) ?? []
            let target = parent + [newName]
            if siblings.contains(where: { $0.isFolder && $0.name == newName }) {
                plan.mergesIntoExisting = true
                try await merge(path, into: target, folders: folders, plan: &plan)
                plan.steps.append(.removeIfEmpty(path))
            } else {
                plan.steps.append(.rename(path, to: newName))
            }
        }
        return plan
    }

    private static func merge(
        _ source: [String], into target: [String],
        folders: any EventFolderWriting, plan: inout EventRenamePlan
    ) async throws {
        let incoming = try await folders.children(of: source) ?? []
        let existing = Dictionary((try await folders.children(of: target) ?? []).map { ($0.name, $0) },
                                  uniquingKeysWith: { first, _ in first })
        // A clip that stays keeps its sidecars (`<stem>.skianalysis.json`,
        // `<stem>--<other>.skialignment.json`) with it: moving them alone
        // would file one clip's analysis beside another.
        let stayingStems = incoming
            .filter { !$0.isFolder && existing[$0.name] != nil && isVideo($0.name) }
            .map { ($0.name as NSString).deletingPathExtension }
        for entry in incoming {
            if let clash = existing[entry.name] {
                if entry.isFolder && clash.isFolder {
                    try await merge(source + [entry.name], into: target + [entry.name],
                                    folders: folders, plan: &plan)
                    plan.steps.append(.removeIfEmpty(source + [entry.name]))
                } else {
                    plan.leftInPlace.append(source + [entry.name])
                }
            } else if !entry.isFolder, stayingStems.contains(where: { belongs(entry.name, to: $0) }) {
                plan.leftInPlace.append(source + [entry.name])
            } else {
                plan.steps.append(.move(entry.name, from: source, to: target))
            }
        }
    }

    private static func isVideo(_ name: String) -> Bool {
        VideoLibrary.supportedExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private static func belongs(_ name: String, to stem: String) -> Bool {
        name.hasPrefix(stem + ".") || name.hasPrefix(stem + "--")
    }
}
