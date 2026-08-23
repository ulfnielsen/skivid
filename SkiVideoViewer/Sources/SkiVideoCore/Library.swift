import Foundation

/// A library the coach has connected, and can open again without finding it.
///
/// Opening footage used to be an *action*: pick a folder, or sign in and browse
/// Drive, every launch, because nothing about the choice survived the app. The
/// heavy, rare step — consenting to Google, hunting through a shared drive —
/// was welded to the light, constant one, so the constant one cost what the rare
/// one costs.
///
/// A library is the noun that separates them. Connecting is rare and deliberate;
/// opening is a click on something that is already there.
public struct Library: Identifiable, Equatable, Codable, Sendable {

    /// Where the clips are.
    ///
    /// A Drive root is whatever node the coach was standing on when they
    /// connected — a whole shared drive or one folder inside it. Drive gives
    /// both an id and lists both the same way, so nothing here needs to know
    /// which it was.
    ///
    /// A folder carries a security-scoped bookmark rather than a path. On the
    /// Mac a path would do; on iPad it would not survive relaunch, which is the
    /// bug that makes "add a folder" pointless there today.
    public enum Kind: Equatable, Codable, Sendable {
        case drive(rootID: String)
        case folder(bookmark: Data)
    }

    public let id: UUID
    /// What the coach calls it. Seeded from the folder or drive name and
    /// editable, because "Videos" is what half of Google Drive is called.
    public var name: String
    public let kind: Kind
    /// Which dimension the folders are organised by. Held per library rather
    /// than as one global preference: athlete-then-event can be right for the
    /// club drive and wrong for a season folder on the desk.
    public var convention: FolderConvention?
    /// When it last opened successfully. Absent until it has.
    public var lastOpened: Date?

    /// Where a folder library lives, as a path.
    ///
    /// Bookmarks cannot answer "is this the same folder?". Both platforms mint
    /// different bytes for the same directory every time one is created, so
    /// comparing `Kind.folder(bookmark:)` by value made every re-add a brand
    /// new library — two identical "Snow" rows in the list, then three.
    /// Optional because a library written before this existed has no path, and
    /// falling back to comparing bookmarks is no worse than what it did then.
    public var folderPath: String?

    public init(id: UUID = UUID(),
                name: String,
                kind: Kind,
                convention: FolderConvention? = nil,
                lastOpened: Date? = nil,
                folderPath: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.convention = convention
        self.lastOpened = lastOpened
        self.folderPath = folderPath
    }

    /// Two entries pointing at the same place are the same library, whatever
    /// they are called or when they were made. Connecting a drive twice adds a
    /// row the first time and touches it every time after.
    public func isSamePlace(as other: Library) -> Bool {
        switch (kind, other.kind) {
        case let (.drive(lhs), .drive(rhs)):
            return lhs == rhs
        case (.folder, .folder):
            if let folderPath, let theirs = other.folderPath { return folderPath == theirs }
            return kind == other.kind
        default:
            return false
        }
    }
}

/// The libraries this machine knows about, in the order they were last opened.
///
/// `UserDefaults`, following `ViewerModel.sidebarGrouping`: a preference rather
/// than a secret, and injectable so tests never touch the real store. The Drive
/// tokens stay in the Keychain and the cached index stays where it is — keyed by
/// root id, so a reconnected library finds its own cache already warm.
/// What to call a library that lives on the machine the app is running on.
/// Said in three places — the landing list, its empty state, and the window
/// title — and they should not be able to disagree about which device this is.
///
/// `deviceName` is a `var` because Core cannot work it out. One iOS binary runs
/// on both an iPhone and an iPad, so the answer is `UIDevice`'s to give, and
/// `CorePurityTests` fails the build if anything under `SkiVideoCore` so much
/// as names UIKit. The app sets it at launch; the default is what to say if it
/// never does, which is wrong on a phone but never *false* the way "This Mac"
/// on an iPhone was.
public enum LocalSource {
    public static var deviceName: String = {
        #if os(macOS)
        return "Mac"
        #else
        return "Device"
        #endif
    }()

    /// Sentence-leading: a row's subtitle, a column heading. "This Mac".
    public static var name: String { "This \(deviceName)" }

    /// Mid-sentence: "…add a folder of clips from this iPhone." Written out
    /// rather than lowercasing `name`, which would say "this iphone".
    public static var inlineName: String { "this \(deviceName)" }
}

public struct LibraryStore: Sendable {

    public static let defaultsKey = "libraries"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Most recently opened first, then anything never opened. A library that
    /// has never been opened sorts last rather than first: it is usually the one
    /// just added, and it is already on screen.
    public func all() -> [Library] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let stored = try? JSONDecoder().decode([Library].self, from: data)
        else { return [] }
        let ordered = stored.sorted {
            switch ($0.lastOpened, $1.lastOpened) {
            case let (left?, right?): return left > right
            case (nil, _?):           return false
            case (_?, nil):           return true
            case (nil, nil):          return $0.name < $1.name
            }
        }
        // Collapse what earlier builds already wrote twice. `add` upserts by
        // place, so nothing new duplicates — but a store written while folder
        // identity was bookmark bytes holds rows this cannot un-write, and the
        // coach should not have to tidy up after a bug. Most recent wins,
        // because the list is already in that order.
        var seen: [Library] = []
        for library in ordered where !seen.contains(where: { $0.isSamePlace(as: library) }) {
            seen.append(library)
        }
        return seen
    }

    /// Adds a library, or updates the one already pointing at that place.
    @discardableResult
    public func add(_ library: Library) -> Library {
        var libraries = all()
        if let index = libraries.firstIndex(where: { $0.isSamePlace(as: library) }) {
            // The place is the identity, so the existing row keeps its id and
            // its history and takes the new name and convention. Reconnecting a
            // drive after signing out must not leave two rows for one folder.
            libraries[index].name = library.name
            libraries[index].convention = library.convention
            write(libraries)
            return libraries[index]
        }
        libraries.append(library)
        write(libraries)
        return library
    }

    /// Records that a library opened. Called on success only — a library that
    /// failed to open is not one to put at the top of the list.
    public func markOpened(_ id: UUID, at date: Date = Date()) {
        var libraries = all()
        guard let index = libraries.firstIndex(where: { $0.id == id }) else { return }
        libraries[index].lastOpened = date
        write(libraries)
    }

    public func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var libraries = all()
        guard let index = libraries.firstIndex(where: { $0.id == id }) else { return }
        libraries[index].name = trimmed
        write(libraries)
    }

    /// Forgets a library. The cached clips and index are left alone: a coach who
    /// disconnects a drive by accident should not pay to download it again, and
    /// clearing the cache is its own decision with its own number attached.
    public func remove(_ id: UUID) {
        write(all().filter { $0.id != id })
    }

    public func convention(for id: UUID) -> FolderConvention? {
        all().first { $0.id == id }?.convention
    }

    public func setConvention(_ convention: FolderConvention?, for id: UUID) {
        var libraries = all()
        guard let index = libraries.firstIndex(where: { $0.id == id }) else { return }
        libraries[index].convention = convention
        write(libraries)
    }

    private func write(_ libraries: [Library]) {
        guard let data = try? JSONEncoder().encode(libraries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
