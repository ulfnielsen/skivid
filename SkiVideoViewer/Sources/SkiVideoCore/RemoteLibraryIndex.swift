import Foundation

/// Which of the two folders nearest a clip is the athlete and which is the
/// event.
///
/// `.eventThenAthlete` reads `<event>/<athlete>/clip.mp4` — the local
/// convention, and the only shape `VideoLibrary.scan` ever produces.
/// `.athleteThenEvent` reads `<athlete>/<event>/clip.mp4` — measured against
/// this user's Shared Drive, which nests the other way round.
///
/// A property of one physical library, not of the app: a coach's local
/// folders and their Shared Drive genuinely differ, so this travels with
/// `RemoteLibraryIndex` and is persisted per root rather than kept as a
/// single app-wide setting.
public enum FolderConvention: String, Codable, Equatable, Sendable {
    case eventThenAthlete
    case athleteThenEvent
}

/// A cloud library as the sidebar sees it: the files, the groups they form,
/// and the way back from a group's URL to the file it came from.
///
/// A value type computed once from a flat file list. The folder *tree* is not
/// stored — Drive's flat sweep already hands each file the names of the
/// folders above it, so there is nothing to walk.
public struct RemoteLibraryIndex: Equatable {
    /// The same list the local scanner uses, deliberately not a copy. Drive
    /// kept its own set until 2026-08-08, still naming avi, mkv and webm after
    /// the local one dropped them — so Drive offered files `AVPlayer` cannot
    /// open. One source of truth cannot drift like that.
    public static var supportedExtensions: Set<String> { VideoLibrary.supportedExtensions }

    public let providerIdentifier: String
    /// What a clip loose in the root is grouped under. Stored, not just a
    /// parameter, because Task 5 reloads an index from disk and it has to
    /// group those clips the same way the sweep that built it did.
    public let rootName: String
    /// Which of the two nearest folders is the athlete and which is the
    /// event, for this root. Stored for the same reason `rootName` is: a
    /// reload must derive athlete and event the same way the sweep that
    /// built the index did.
    public let convention: FolderConvention
    public private(set) var athletes: [AthleteGroup]
    /// Where the change feed resumes, or nil before the first sweep.
    public private(set) var cursor: String?

    private var filesByURL: [URL: RemoteFile]

    public init(
        providerIdentifier: String,
        rootName: String = "Unsorted",
        files: [RemoteFile],
        cursor: String? = nil,
        convention: FolderConvention = .eventThenAthlete
    ) {
        self.providerIdentifier = providerIdentifier
        self.rootName = rootName
        self.cursor = cursor
        self.convention = convention

        var entries: [LibraryGrouping.Entry] = []
        var filesByURL: [URL: RemoteFile] = [:]

        for file in files {
            guard Self.supportedExtensions.contains(
                URL(fileURLWithPath: file.name).pathExtension.lowercased()
            ) else { continue }

            let url = Self.libraryURL(for: file, providerIdentifier: providerIdentifier)
            filesByURL[url] = file

            // The two folders nearest the clip, the same rule the local
            // scanner applies to a path — `convention` only decides which of
            // the two is the athlete and which is the event. A clip loose in
            // the root has neither, and is grouped under the root's own name
            // — the grouping *key*, not a caption, which is why a literal
            // "Unsorted" would fold a real folder of that name together with
            // the loose files.
            let nearest = file.path.last
            let aboveNearest = file.path.count >= 2 ? file.path[file.path.count - 2] : nil
            let athlete: String
            let event: String?
            switch convention {
            case .eventThenAthlete:
                athlete = nearest ?? rootName
                event = aboveNearest
            case .athleteThenEvent:
                athlete = aboveNearest ?? rootName
                event = nearest
            }
            entries.append(LibraryGrouping.Entry(video: url, athlete: athlete, event: event))
        }

        self.filesByURL = filesByURL
        self.athletes = LibraryGrouping.group(entries)
    }

    /// The URL the sidebar, the comparison picker and the analysis stores all
    /// carry for this clip.
    ///
    /// The file id is the host and the folder path is the URL path. Both parts
    /// are load-bearing. The id makes two clips that share a name distinct and
    /// survives a rename in Drive. The folder path is what
    /// `LibraryGrouping.pathOrder` sorts on — with only the file name there,
    /// as the old client had it, Drive clips sorted by name alone and sibling
    /// folders interleaved instead of staying in blocks.
    ///
    /// A Drive folder name may contain `/`, which adds URL path components and
    /// so sorts the clip as if nested deeper. Grouping is unaffected: athlete
    /// and event come from `RemoteFile.path`, never from parsing this URL.
    public static func libraryURL(
        for file: RemoteFile, providerIdentifier: String
    ) -> URL {
        var components = URLComponents()
        components.scheme = providerIdentifier
        components.host = file.id
        components.path = "/" + (file.path + [file.name]).joined(separator: "/")
        if let url = components.url { return url }

        // Drive ids are base64url and always form a host, but an id carrying a
        // space, ":", "\", "[" or "]" makes URLComponents refuse. Digesting it
        // gives a host that is always URL-safe and still unique per file, so
        // the clip stays in the library instead of colliding with every other
        // unbuildable one. Nothing parses this host back — `file(for:)` is a
        // dictionary lookup — so a digest reads as badly and works as well.
        components.host = StorageName.forIdentifier(file.id)
        if let url = components.url { return url }

        // Reaching here means the *scheme* is unusable, which is a provider
        // bug rather than bad data: identifiers are compile-time constants.
        // Still per-file unique, because the alternative is two clips sharing
        // one URL and one of them vanishing from the sidebar.
        return URL(fileURLWithPath: "/\(StorageName.forIdentifier(file.id))")
    }

    /// The file a library URL stands for, or nil when the URL is not this
    /// index's — a local clip, or one indexed before a refresh dropped it.
    public func file(for url: URL) -> RemoteFile? { filesByURL[url] }

    /// The file with this id, or nil when the index holds none. For a
    /// comparison pane, which knows a clip only by the `ClipIdentity` it was
    /// given — unlike `file(for:)`, the sidebar's hot path, this is a linear
    /// scan, but it runs once per comparison pick rather than once per clip,
    /// so a thousand-file library costs nothing worth indexing for.
    func file(forID id: String) -> RemoteFile? {
        filesByURL.values.first { $0.id == id }
    }

    /// Bumped whenever the stored shape changes. A stored index from any
    /// other version — older *or newer* — is refused rather than adapted,
    /// the same rule `AlignmentTrackStore` applies to a stale track:
    /// refusing costs one sweep, adapting silently costs a library that is
    /// subtly wrong. A newer version matters too: a build ahead of this one
    /// could have changed the stored shape in a way today's decoder cannot
    /// detect, only misread.
    public static let currentVersion = 1

    /// Where indexes are written. Application Support rather than Caches: an
    /// index is cheap to rebuild but a purge would turn every launch into a
    /// full sweep. Settable so tests never write to the real directory.
    public static var storeRoot: URL = defaultStoreRoot()

    private static func defaultStoreRoot() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("SkiVideoViewer", isDirectory: true)
            .appendingPathComponent("RemoteLibrary", isDirectory: true)
    }

    /// One file per root, named by a digest of the root id — see
    /// `StorageName` for why a digest rather than the id itself.
    static func storeURL(forRoot rootID: String) -> URL {
        storeRoot
            .appendingPathComponent(StorageName.forIdentifier(rootID))
            .appendingPathExtension("skiindex.json")
    }

    public func save(forRoot rootID: String) throws {
        let url = Self.storeURL(forRoot: rootID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let stored = Stored(
            version: Self.currentVersion,
            providerIdentifier: providerIdentifier,
            rootName: rootName,
            files: Array(filesByURL.values).sorted { $0.id < $1.id },
            cursor: cursor,
            convention: convention
        )
        try JSONEncoder().encode(stored).write(to: url, options: .atomic)
    }

    /// The stored index, or nil when there is none, it cannot be read, or it
    /// was written by a different version — older or newer. All three mean
    /// the same thing to the caller: sweep the drive.
    public static func load(forRoot rootID: String) -> RemoteLibraryIndex? {
        guard let data = try? Data(contentsOf: storeURL(forRoot: rootID)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == currentVersion
        else { return nil }
        return RemoteLibraryIndex(
            providerIdentifier: stored.providerIdentifier,
            rootName: stored.rootName,
            files: stored.files,
            cursor: stored.cursor,
            convention: stored.convention ?? .eventThenAthlete
        )
    }

    /// A copy of this index carrying `cursor`. For the sweep path: a fresh
    /// sweep builds an index with no cursor, and `startCursor` is only known
    /// once the sweep is already under way — `applying` sets its own cursor
    /// from the change feed, so this exists only for that first sweep.
    public func withCursor(_ cursor: String) -> RemoteLibraryIndex {
        var copy = self
        copy.cursor = cursor
        return copy
    }

    /// The index this one becomes after a refresh.
    ///
    /// Upsert by file id, so replaying a change is harmless — Drive's log is
    /// coalesced per file and a resumed cursor can hand back one already
    /// applied. A rename arrives as a change to the same id, so it replaces
    /// rather than duplicates.
    public func applying(_ changes: RemoteLibraryChanges) -> RemoteLibraryIndex {
        var byID = Dictionary(
            filesByURL.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        for file in changes.changed { byID[file.id] = file }
        for id in changes.removed { byID.removeValue(forKey: id) }
        return RemoteLibraryIndex(
            providerIdentifier: providerIdentifier,
            rootName: rootName,
            files: Array(byID.values),
            cursor: changes.cursor,
            convention: convention
        )
    }

    private struct Stored: Codable {
        let version: Int
        let providerIdentifier: String
        let rootName: String
        let files: [RemoteFile]
        let cursor: String?
        /// Optional so a file written before this field existed still
        /// decodes — see `load`, which falls back to `.eventThenAthlete`,
        /// today's only convention, when it is absent.
        let convention: FolderConvention?
    }
}
