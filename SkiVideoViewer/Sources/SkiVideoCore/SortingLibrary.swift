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

    /// The inverse of `eventFolder(date:title:)`, for pre-filling the rename
    /// sheet: `2026-08-08_Wittenburg-GS` gives that day and `Wittenburg GS`,
    /// which `eventFolder` joins back into the same name — so opening the
    /// sheet and changing nothing proposes no rename. Hyphens become spaces
    /// because `eventFolder` turned the title's spaces into hyphens.
    ///
    /// That round trip holds only for names `eventFolder` could have made: a
    /// real date, one underscore, and a title of letters and digits joined by
    /// single hyphens. Anything else comes back changed, because `eventFolder`
    /// cleans the title — `2026-02-14_Hoch_Ybrig` returns as
    /// `2026-02-14_Hoch-Ybrig`, a doubled or trailing hyphen collapses, and an
    /// undated name gains today's date — so for such a name an unchanged sheet
    /// does propose a rename.
    ///
    /// A name that does not start with a real `yyyy-MM-dd` before the first
    /// underscore has no date, and all of it is the title; the sheet then
    /// leaves the date picker on today, where the coach can see and change it.
    public static func eventFolderParts(_ name: String) -> (date: Date?, title: String) {
        let parts = name.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let first = parts.first, let date = formatter.date(from: first) else {
            return (nil, name)
        }
        let title = parts.count > 1 ? parts[1].replacingOccurrences(of: "-", with: " ") : ""
        return (date, title)
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
