import Foundation

/// Why a sorted clip has nowhere to go in Drive. Typed so the sorting UI can
/// ask *before* the coach tags anything, and worded for someone standing in a
/// lift queue: what is wrong, then what to do.
public enum UploadRefusal: Error, Equatable, LocalizedError, Sendable {
    case noLibraryOpen
    case libraryIsAFolder(libraryName: String)
    case layoutUnknown(libraryName: String)
    /// The library is a drive, but what it was opened with cannot create
    /// files. Not reachable with `GoogleDriveProvider`, which can; here so a
    /// read-only provider is refused in words rather than by a cast that
    /// quietly fails.
    case cannotWrite(libraryName: String)

    public var errorDescription: String? {
        switch self {
        case .noLibraryOpen:
            return "Open your club's Google Drive library first. Clips can only be uploaded into a library that is open."
        case let .libraryIsAFolder(name):
            return "\(name) is a folder on this device, not a Google Drive. Open your club's Drive library to upload."
        case let .layoutUnknown(name):
            return "The app cannot tell whether \(name) is filed by event then athlete, or athlete then event. Use Connect Google Drive… and pick its Folder layout before choosing \(name) again."
        case let .cannotWrite(name):
            return "This app cannot add clips to \(name)."
        }
    }
}

/// Where in Drive a sorted clip goes: a root id and which of event / athlete
/// nests first. A pure value; the upload walk (`findOrCreateFolder` down
/// `folderNames`) belongs to the caller.
public struct UploadDestination: Equatable, Sendable {
    public let rootID: String
    public let libraryName: String
    public let convention: FolderConvention

    /// Layout is `library.convention`, else `indexConvention` (the open
    /// index's, when it is actually known), else a refusal. Never a default:
    /// a clip filed the wrong way round is worse than one not uploaded.
    public static func resolve(
        library: Library?, indexConvention: FolderConvention?
    ) throws -> UploadDestination {
        guard let library else { throw UploadRefusal.noLibraryOpen }
        guard case let .drive(rootID) = library.kind else {
            throw UploadRefusal.libraryIsAFolder(libraryName: library.name)
        }
        guard let convention = library.convention ?? indexConvention else {
            throw UploadRefusal.layoutUnknown(libraryName: library.name)
        }
        return UploadDestination(rootID: rootID, libraryName: library.name, convention: convention)
    }

    /// Folder names to find-or-create under `rootID`, outermost first.
    public func folderNames(event: String, athlete: String) -> [String] {
        switch convention {
        case .eventThenAthlete: return [event, athlete]
        case .athleteThenEvent: return [athlete, event]
        }
    }

    public func folderNames(for clip: SortedClip) -> [String] {
        folderNames(event: clip.event, athlete: clip.athlete)
    }
}

/// One resized clip on disk with the event and athlete it was tagged with.
public struct SortedClip: Equatable, Sendable {
    public let event: String
    public let athlete: String
    public let file: URL
}

public enum SortedOutput {
    /// Reads `<root>/<event>/<athlete>/<clip>` back, which is exactly what
    /// `ReadOnlySourcePublisher` (and `LocalFolderPublisher`'s resized tree)
    /// writes. Sorted by event, athlete, file name so the order is stable.
    ///
    /// What it lists is finished clips only: the resize writes to a hidden
    /// `.resize-*` file and moves it into place on success
    /// (`AVFoundationMediaPipeline.resize`), and this skips hidden files, so an
    /// in-flight, failed or killed resize never appears. Files whose extension
    /// is not in `VideoLibrary.supportedExtensions` (case-insensitive) are
    /// skipped too. Anything not at that depth is ignored; a missing root is
    /// simply empty.
    public static func clips(in root: URL) throws -> [SortedClip] {
        try children(root, directories: true).flatMap { try clips(inEventFolder: $0) }
    }

    /// One event's clips: `<eventFolder>/<athlete>/<clip>`, the event being
    /// the folder's own name. Same filtering as `clips(in:)`. What the tray
    /// at the end of a sorting session reads, so that session's screen is
    /// about that session and not every event this device has ever sorted.
    public static func clips(inEventFolder eventFolder: URL) throws -> [SortedClip] {
        var result: [SortedClip] = []
        for athlete in try children(eventFolder, directories: true) {
            for file in try children(athlete, directories: false)
            where VideoLibrary.supportedExtensions.contains(file.pathExtension.lowercased()) {
                result.append(SortedClip(event: eventFolder.lastPathComponent,
                                         athlete: athlete.lastPathComponent, file: file))
            }
        }
        return result
    }

    private static func children(_ url: URL, directories: Bool) throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return [] }
        return try fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter {
            ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) == directories
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
