import Foundation

/// The athlete roster a sorting session offers for autocomplete, built from
/// whichever library is open plus any names a coach has added locally that
/// have no clips yet.
///
/// A remote library is `<athlete>/<event>/clip.mp4`; `ViewerModel` parses it
/// into `AthleteGroup`s, one per (athlete, event) pair. Deriving the roster
/// from that is correct by construction — a tagged name is guaranteed to
/// match the folder the clip belongs in — but it has one gap: an athlete with
/// no clips yet, a new joiner or the first session of a season. Those names
/// have nowhere to come from but the coach, so they are kept locally,
/// per-device, and merged on top of the library on every read.
public enum AthleteRoster {
    /// Where locally-added names are stored. Injectable so tests never write
    /// to the developer's real Application Support — the same reason
    /// `ClipIdentity.keyedStoreRoot` is a settable static.
    ///
    /// Defaults beside `RemoteLibraryIndex`'s store, under the same
    /// `SkiVideoViewer` folder in Application Support.
    public static var storeRoot: URL = defaultStoreRoot()

    private static func defaultStoreRoot() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SkiVideoViewer", isDirectory: true)
    }

    /// Local additions are per-device and small — nothing syncs them. Sharing
    /// a roster between coaches needs a writable Drive file, out of scope
    /// here.
    private static var localNamesURL: URL {
        storeRoot.appendingPathComponent("LocalAthletes.json")
    }

    /// Unique athlete names from an open library, sorted. `AthleteGroup` is
    /// one (athlete, event) pair, so an athlete with clips at several events
    /// appears once per event in `athletes` and must be de-duplicated here.
    public static func names(inLibrary athletes: [AthleteGroup]) -> [String] {
        deduplicated(athletes.map(\.name))
    }

    /// Library names merged with locally-added ones, de-duplicated and
    /// sorted. When a name collides — case- or whitespace-insensitively —
    /// the library's spelling wins, since it is the one every clip on disk
    /// actually agrees with.
    public static func merged(library: [AthleteGroup]) -> [String] {
        deduplicated(names(inLibrary: library) + localNames())
    }

    /// Remembers a name that has no clips yet. Idempotent: adding the same
    /// name twice, in any case or with different surrounding whitespace,
    /// leaves one entry.
    public static func addLocally(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var names = localNames()
        let key = SortingLibrary.normalized(trimmed)
        guard !names.contains(where: { SortingLibrary.normalized($0) == key }) else { return }
        names.append(trimmed)
        try save(names)
    }

    /// Case- and whitespace-insensitive de-duplication, matching
    /// `SortingLibrary.normalized(_:)` — first occurrence wins, so a
    /// caller that wants the library's spelling to win over a locally-added
    /// one must list the library's names first.
    private static func deduplicated(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for name in names {
            let key = SortingLibrary.normalized(name)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(name)
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func localNames() -> [String] {
        guard let data = try? Data(contentsOf: localNamesURL),
              let names = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return names
    }

    private static func save(_ names: [String]) throws {
        try FileManager.default.createDirectory(
            at: storeRoot, withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(names)
        try data.write(to: localNamesURL, options: .atomic)
    }
}
