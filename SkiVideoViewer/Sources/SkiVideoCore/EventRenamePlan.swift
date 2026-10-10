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
            // Folder names match ignoring case: a local volume treats `B` and
            // `b` as one folder, so a "new" name differing only in case
            // already exists. The source itself is excluded, which keeps a
            // case-only rename (`a` to `A`) a plain rename. Merging goes into
            // the existing folder's actual name, since moving into a
            // differently-cased spelling is refused and would never converge.
            if let existing = siblings.first(where: {
                $0.isFolder && $0.name != oldName && $0.name.caseInsensitiveCompare(newName) == .orderedSame
            }) {
                plan.mergesIntoExisting = true
                try await merge(path, into: parent + [existing.name], folders: folders, plan: &plan)
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
        let inTarget = try await folders.children(of: target) ?? []
        let existing = Dictionary(inTarget.map { ($0.name.lowercased(), $0) },
                                  uniquingKeysWith: { first, _ in first })
        // Sidecars are keyed by stem (`<stem>.skianalysis.json`,
        // `<stem>--<other>.skialignment.json`), not by the clip's full name.
        // So a whole stem stays together, or none of it moves, when either
        //  (a) some incoming file of the stem clashes by name with the target, or
        //  (b) the target already holds any file of the stem.
        // Otherwise a moved clip would load a sidecar that is not its own
        // (leaving its own stranded), or a moved sidecar would become the
        // analysis of a clip already there. Decided before any entry is planned.
        let stayingStems = Set(incoming
            .filter { !$0.isFolder && isVideo($0.name) }
            .map { ($0.name as NSString).deletingPathExtension }
            .filter { stem in
                incoming.contains { !$0.isFolder && belongs($0.name, to: stem) && existing[$0.name.lowercased()] != nil }
                    || inTarget.contains { !$0.isFolder && belongs($0.name, to: stem) }
            })
        // Videos are planned before everything else. Name order puts
        // `<stem>--<other>.skialignment.json` ahead of `<stem>.mov` ("-" sorts
        // before "."), and Drive's order is not guaranteed at all. A run
        // stopped after a sidecar moved but before its clip would leave the
        // target holding a file of the stem, so rule (b) would keep the clip
        // behind on every re-plan. With videos first, a stopped run leaves
        // only sidecars whose video already moved; those form no staying stem
        // (stems come from incoming videos), so the next run moves them.
        let ordered = incoming.filter { !$0.isFolder && isVideo($0.name) }
            + incoming.filter { $0.isFolder || !isVideo($0.name) }
        for entry in ordered {
            let clash = existing[entry.name.lowercased()]
            if entry.isFolder {
                if let clash, clash.isFolder {
                    try await merge(source + [entry.name], into: target + [clash.name],
                                    folders: folders, plan: &plan)
                    plan.steps.append(.removeIfEmpty(source + [entry.name]))
                } else if clash != nil {
                    plan.leftInPlace.append(source + [entry.name])
                } else {
                    plan.steps.append(.move(entry.name, from: source, to: target))
                }
            } else if clash != nil || stayingStems.contains(where: { belongs(entry.name, to: $0) }) {
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
        // Ignoring case, like the clash lookup: on a case-insensitive volume
        // `img_1.mov` would load `IMG_1.skianalysis.json` as its own.
        let name = name.lowercased(), stem = stem.lowercased()
        return name.hasPrefix(stem + ".") || name.hasPrefix(stem + "--")
    }
}
