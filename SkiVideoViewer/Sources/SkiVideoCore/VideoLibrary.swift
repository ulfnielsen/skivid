import Foundation

public struct AthleteGroup: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let videos: [URL]

    public init(id: String, name: String, videos: [URL]) {
        self.id = id
        self.name = name
        self.videos = videos
    }
}

public enum VideoLibrary {
    public static let supportedExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "webm",
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
        videos.sort {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }

        var names: [String: String] = [:]
        var grouped: [String: [URL]] = [:]
        for video in videos {
            let athleteName = video.deletingLastPathComponent().lastPathComponent
            let key = athleteName.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            names[key] = names[key] ?? athleteName
            grouped[key, default: []].append(video)
        }

        return grouped.keys
            .sorted {
                (names[$0] ?? $0).localizedCaseInsensitiveCompare(names[$1] ?? $1)
                    == .orderedAscending
            }
            .map { key in
                AthleteGroup(
                    id: key,
                    name: names[key] ?? key,
                    videos: grouped[key] ?? []
                )
            }
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
