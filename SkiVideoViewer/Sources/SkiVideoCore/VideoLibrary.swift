import Foundation

public struct AthleteGroup: Identifiable, Equatable {
    public let id: String
    public let name: String
    /// The event folder this athlete's clips sat in, or nil when the athlete
    /// folder was directly under the chosen root. The sidebar groups by it; the
    /// clip caption and the comparison picker spell it out where there is no
    /// section header to carry it.
    public let event: String?
    public let videos: [URL]

    public init(id: String, name: String, event: String? = nil, videos: [URL]) {
        self.id = id
        self.name = name
        self.event = event
        self.videos = videos
    }
}

public enum VideoLibrary {
    /// Only what AVFoundation can actually open.
    ///
    /// `mkv`, `webm` and `avi` were listed until 2026-08-07, which put files in
    /// the sidebar that `AVPlayer` then refused to play — measured against a
    /// real Matroska file from the library, `AVURLAsset.load(.isPlayable)`
    /// fails with "Cannot Open" where the same probe on an `.mp4` returns true.
    /// Removing them fixes that rather than dropping a capability.
    public static let supportedExtensions: Set<String> = [
        "mp4", "mov", "m4v",
    ]

    public static func scan(_ root: URL) throws -> [AthleteGroup] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: root.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw ViewerError.invalidDirectory(root.path)
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw ViewerError.cannotReadDirectory(root.path)
        }

        var videos: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true,
                  supportedExtensions.contains(fileURL.pathExtension.lowercased())
            else {
                continue
            }
            videos.append(fileURL)
        }
        // Both spellings of the root, computed once. The enumerator was
        // measured to hand back URLs that keep whatever spelling `root` came
        // with — a trailing slash, `..`, or a symlinked path all survive into
        // the children — so standardizing is enough today. The resolved
        // spelling is here so that a root given as `/var/…` still matches
        // children reported as `/private/var/…` if that ever changes, and it
        // costs one `stat` for the whole scan rather than one per video.
        let rootPaths: Set<String> = [
            root.standardizedFileURL.path,
            root.resolvingSymlinksInPath().standardizedFileURL.path,
        ]
        return LibraryGrouping.group(
            videos.map { video in
                let athleteFolder = video.deletingLastPathComponent()
                let eventFolder = athleteFolder.deletingLastPathComponent()
                // The event is the folder *directly above* the athlete, and
                // only when there is one inside the chosen root. Taking the
                // first component under the root instead would name a season
                // rather than an event in a `root/2026/Event/Athlete` tree, and
                // would mistake the athlete's own folder for an event in a
                // `root/Athlete` one.
                //
                // The second test is for a clip loose at the top of the chosen
                // root: its "athlete folder" is the root itself, which makes its
                // "event folder" the root's *parent* — a directory the operator
                // never selected and that the scan never walked. Naming it would
                // put a section header like "Desktop" in the sidebar, and above
                // the date-prefixed real events at that, since letters sort
                // after digits under the descending event order.
                let hasEvent = !rootPaths.contains(eventFolder.standardizedFileURL.path)
                    && !rootPaths.contains(athleteFolder.standardizedFileURL.path)
                return LibraryGrouping.Entry(
                    video: video,
                    athlete: athleteFolder.lastPathComponent,
                    event: hasEvent ? eventFolder.lastPathComponent : nil
                )
            }
        )
    }
}

public enum ViewerError: LocalizedError {
    case invalidDirectory(String)
    case cannotReadDirectory(String)
    case noVideos

    public var errorDescription: String? {
        switch self {
        case let .invalidDirectory(path):
            return "Video directory not found: \(path)"
        case let .cannotReadDirectory(path):
            return "Could not read video directory: \(path)"
        case .noVideos:
            return "No supported videos were found in that directory."
        }
    }
}
