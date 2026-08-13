import Foundation

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
    public private(set) var athletes: [AthleteGroup]

    private var filesByURL: [URL: RemoteFile]

    public init(
        providerIdentifier: String,
        rootName: String = "Unsorted",
        files: [RemoteFile]
    ) {
        self.providerIdentifier = providerIdentifier
        self.rootName = rootName

        var entries: [LibraryGrouping.Entry] = []
        var filesByURL: [URL: RemoteFile] = [:]

        for file in files {
            guard Self.supportedExtensions.contains(
                URL(fileURLWithPath: file.name).pathExtension.lowercased()
            ) else { continue }

            let url = Self.libraryURL(for: file, providerIdentifier: providerIdentifier)
            filesByURL[url] = file
            entries.append(
                LibraryGrouping.Entry(
                    video: url,
                    // The two folders nearest the clip, the same rule the
                    // local scanner applies to a path. A clip loose in the
                    // root has neither, and is grouped under the root's own
                    // name — the grouping *key*, not a caption, which is why
                    // a literal "Unsorted" would fold a real folder of that
                    // name together with the loose files.
                    athlete: file.path.last ?? rootName,
                    event: file.path.count >= 2 ? file.path[file.path.count - 2] : nil
                )
            )
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
        // Unreachable for Drive, whose ids are base64url and whose names are
        // percent-encoded by URLComponents. A provider that broke that
        // assumption would otherwise crash on a force-unwrap; this keeps the
        // clip out of the library instead, where the id still makes it unique.
        return URL(string: "\(providerIdentifier)://\(file.id)")
            ?? URL(fileURLWithPath: "/dev/null")
    }

    /// The file a library URL stands for, or nil when the URL is not this
    /// index's — a local clip, or one indexed before a refresh dropped it.
    public func file(for url: URL) -> RemoteFile? { filesByURL[url] }
}
