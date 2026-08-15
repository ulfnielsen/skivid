import Foundation

public enum SortingLibrary {
    public static func rawVideos(in directory: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ViewerError.invalidDirectory(directory.path)
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isHiddenKey]
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        return files.filter { url in
            let values = try? url.resourceValues(forKeys: keys)
            return values?.isRegularFile == true
                && VideoLibrary.supportedExtensions.contains(url.pathExtension.lowercased())
        }.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent)
                == .orderedAscending
        }
    }

    public static func eventFolder(date: Date, title: String) throws -> String {
        let cleanedTitle = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !cleanedTitle.isEmpty else {
            throw SortingError.missingEventTitle
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(formatter.string(from: date))_\(cleanedTitle)"
    }

    public static func suggestedEventDate(from video: URL) -> Date {
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
        let values = try? video.resourceValues(forKeys: keys)
        return values?.creationDate ?? values?.contentModificationDate ?? Date()
    }

    public static func athleteFolderName(_ athlete: String) throws -> String {
        let cleaned = athlete
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !cleaned.isEmpty else { throw SortingError.missingAthlete }
        return cleaned
    }

    public static func athleteNames(from url: URL?) -> [String] {
        guard let url, let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        var seen: Set<String> = []
        return contents.components(separatedBy: .newlines).compactMap { rawName in
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalized(name)
            guard !name.isEmpty, seen.insert(key).inserted else { return nil }
            return name
        }
    }

    public static func bestAthleteName(for query: String, names: [String]) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalized(trimmed)
        if let exact = names.first(where: { normalized($0) == key }) {
            return exact
        }
        let matches = names.filter { normalized($0).contains(key) }
        return matches.count == 1 ? matches[0] : trimmed
    }

    public static func matches(for query: String, names: [String]) -> [String] {
        let key = normalized(query)
        guard !key.isEmpty else { return Array(names.prefix(8)) }
        return names.filter { normalized($0).contains(key) }.prefix(8).map { $0 }
    }

    /// Case-insensitive comparison key for an athlete name. Deliberately does
    /// *not* trim: `matches(for:names:)`, right above, relies on a
    /// whitespace-only query folding to a non-empty key, so it is treated as
    /// real search text (and, for these names, matches nothing) rather than
    /// as an empty query, which shows the first 8 names instead. Callers that
    /// need whitespace insensitivity too — `bestAthleteName` above, and
    /// `AthleteRoster.deduplicated` in this module's other file — trim before
    /// calling this.
    ///
    /// Internal rather than private: `AthleteRoster` de-duplicates a library
    /// name against a locally-added one with the same case-folding, and must
    /// not grow a second normaliser that could drift from this one.
    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

public enum SortingError: LocalizedError {
    case missingEventTitle
    case missingAthlete
    case outputExists(String)
    /// The resize job finished without recording either success or failure.
    /// Unreachable in practice — the semaphore in `SortingModel.enqueueResize`
    /// is only signalled after the result has been stored — but a resize that
    /// somehow lands here must not be reported as a missing-videos error.
    case resizeProducedNoResult

    public var errorDescription: String? {
        switch self {
        case .missingEventTitle:
            return "Enter an event title before starting the sort."
        case .missingAthlete:
            return "Enter or select an athlete name."
        case let .outputExists(path):
            return "A file already exists at \(path). It was not overwritten."
        case .resizeProducedNoResult:
            return "The resize finished without reporting a result. The clip was moved but not resized."
        }
    }
}
