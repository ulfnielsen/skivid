import Foundation

/// Google Drive as a remote library.
///
/// One flat paged sweep per Shared Drive, not a folder-by-folder walk: Drive
/// can list a whole drive with `corpora=drive`, so a 1,000-clip library is two
/// round trips rather than one per folder. The folder tree is rebuilt here
/// from each file's `parents`.
public struct GoogleDriveProvider: RemoteLibraryProvider {
    public static let identifier = "gdrive"

    static let folderMimeType = "application/vnd.google-apps.folder"
    /// Drive returns a minimal field set unless asked. Every field here is
    /// used: `headRevisionId` is the cache-validity key, `md5Checksum` the
    /// post-download check, `parents` the tree, `size` the progress bar.
    private static let fileFields =
        "nextPageToken,incompleteSearch,files(id,name,mimeType,size,md5Checksum,headRevisionId,parents)"

    private let transport: HTTPTransport
    private let token: @Sendable () -> String?

    /// `token` is read per request rather than captured once, so a refresh
    /// between calls is picked up without rebuilding the provider.
    public init(transport: HTTPTransport = URLSessionTransport(), token: @escaping @Sendable () -> String?) {
        self.transport = transport
        self.token = token
    }

    public func connect(presenter: OAuthPresenter) async throws {
        // Sign-in lands in plan 3, which owns the client registration and the
        // two platform redirect paths. Until then the token closure supplies
        // credentials obtained elsewhere.
        throw RemoteLibraryError.notSignedIn
    }

    public func roots() async throws -> [RemoteFolder] {
        var found: [RemoteFolder] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/drives")!
            components.queryItems = [
                // The default is 10, which would silently truncate the picker
                // for an account in more drives than that. 100 is the maximum,
                // so the paging below is what actually removes the ceiling.
                URLQueryItem(name: "pageSize", value: "100"),
            ]
            if let pageToken {
                components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            let page: DriveListOfDrives = try await get(components)
            found.append(contentsOf: page.drives.map { RemoteFolder(id: $0.id, name: $0.name) })
            pageToken = page.nextPageToken
        } while pageToken != nil
        return found
    }

    /// Every video in one Shared Drive.
    ///
    /// `folder` must be a root from `roots()` — its id is used as `driveId`,
    /// so a subfolder would be rejected by the API. Filtering to a subtree is
    /// the index's job, done in memory against the parents graph, because
    /// Drive has no recursive-subtree query and one whole-drive sweep costs
    /// the same as one folder listing.
    public func enumerate(_ folder: RemoteFolder) -> AsyncThrowingStream<RemoteFile, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let records = try await sweep(driveID: folder.id)
                    let folders = Dictionary(
                        records.filter { $0.mimeType == Self.folderMimeType }.map { ($0.id, $0) },
                        // Drive can report one record twice — results shift
                        // mid-pagination, and a multi-page change drain can
                        // repeat a file. `uniqueKeysWithValues` traps on that,
                        // which would crash the app on a routine refresh.
                        uniquingKeysWith: { first, _ in first }
                    )
                    for record in records where record.mimeType != Self.folderMimeType {
                        // Cosmetic by the time execution reaches here: `sweep`
                        // has already paged through the whole drive and
                        // `records` is fully in memory, so a cancellation
                        // caught in this loop only skips a few in-memory
                        // yields. The check that actually matters — the one
                        // that stops an abandoned browse from paging on to
                        // the end of a thousand-clip drive — is the one
                        // inside `sweep`'s own page loop, below.
                        try Task.checkCancellation()
                        continuation.yield(
                            RemoteFile(
                                id: record.id,
                                name: record.name,
                                path: Self.folderPath(of: record, in: folders, rootID: folder.id),
                                size: Int64(record.size ?? "") ?? 0,
                                contentVersion: record.headRevisionId,
                                md5: record.md5Checksum
                            )
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // A consumer that stops iterating — the view torn down, the coach
            // picking a different drive — must stop the sweep with it.
            // Without this the task pages on to the end of a thousand-clip
            // drive, spending the operator's bandwidth on a stream nobody is
            // listening to.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func downloadSource(for file: RemoteFile) async throws -> DownloadSource {
        guard let token = token() else { throw RemoteLibraryError.notSignedIn }
        var components = URLComponents(
            string: "https://www.googleapis.com/drive/v3/files"
        )!
        // Appended through `path` so an id that is not URL-safe is encoded
        // rather than reshaping the request.
        components.path += "/\(file.id)"
        components.queryItems = [
            URLQueryItem(name: "alt", value: "media"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
        ]
        guard let url = components.url else {
            throw RemoteLibraryError.api("That Drive file id cannot be used in a request.")
        }
        return DownloadSource(url: url, headers: ["Authorization": "Bearer \(token)"])
    }

    // MARK: - The sweep

    private func sweep(driveID: String) async throws -> [DriveRecord] {
        var records: [DriveRecord] = []
        var pageToken: String?
        repeat {
            // Checked per page, so abandoning a browse stops the sweep at the
            // next page boundary rather than at the end of the drive.
            try Task.checkCancellation()
            var components = URLComponents(
                string: "https://www.googleapis.com/drive/v3/files"
            )!
            components.queryItems = [
                URLQueryItem(name: "corpora", value: "drive"),
                URLQueryItem(name: "driveId", value: driveID),
                // Omitting either excludes shared-drive items *silently*,
                // which reads as an empty library rather than as an error.
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
                // Defaults to 100 for a shared drive; 1000 makes a
                // 1,000-clip library two requests instead of eleven.
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "q", value: "trashed = false"),
                URLQueryItem(name: "fields", value: Self.fileFields),
            ]
            if let pageToken {
                components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            let page: DriveFileList = try await get(components)
            // Drive can drop files from a result without erroring. Reporting a
            // partial library as whole is the one outcome worth failing over.
            if page.incompleteSearch == true {
                throw RemoteLibraryError.api(
                    "Google Drive returned an incomplete listing for this drive. Try again."
                )
            }
            records.append(contentsOf: page.files)
            pageToken = page.nextPageToken
        } while pageToken != nil
        return records
    }

    /// The folder names from the drive root down to this record's parent.
    ///
    /// Bounded by the number of known folders, not by trust in the data: a
    /// parent cycle would otherwise spin forever, and nothing in production
    /// would catch it because Drive should never produce one. A record whose
    /// parent is missing — trashed folder, lost access — keeps the path that
    /// could be resolved rather than being dropped, because losing a clip is
    /// worse than filing it one level shallow.
    static func folderPath(
        of record: DriveRecord, in folders: [String: DriveRecord], rootID: String
    ) -> [String] {
        var names: [String] = []
        // `seen` is what terminates this: each folder id can be consumed once,
        // so the walk is bounded by the number of known folders whether or not
        // the parent links form a cycle.
        var seen: Set<String> = []
        var current = record.parents?.first
        while let id = current, id != rootID, !seen.contains(id) {
            seen.insert(id)
            guard let folder = folders[id] else { break }
            names.append(folder.name)
            current = folder.parents?.first
        }
        return names.reversed()
    }

    // MARK: - Requests

    private func get<T: Decodable>(_ components: URLComponents) async throws -> T {
        guard let token = token() else { throw RemoteLibraryError.notSignedIn }
        guard let url = components.url else {
            throw RemoteLibraryError.api("Could not build a request to Google Drive.")
        }
        var request = URLRequest(url: url)
        // Never a query parameter. Measured 2026-08-13: on the media path a
        // query-string token is refused with an HTML block page.
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await transport.data(for: request)
        guard (200...299).contains(response.statusCode) else {
            throw Self.describeFailure(data: data, response: response)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RemoteLibraryError.api(
                "Google Drive returned an unexpected reply: \(error.localizedDescription)"
            )
        }
    }

    /// Google answers some failures with an HTML anti-abuse page rather than a
    /// JSON error object. A caller that assumes non-200 means JSON would
    /// mis-parse that, so the two are told apart before decoding.
    static func describeFailure(data: Data, response: HTTPURLResponse) -> RemoteLibraryError {
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        if !contentType.contains("json") {
            return .unexpectedResponseBody(
                """
                Google Drive answered with a \(response.statusCode) web page rather than an \
                API reply. This usually means the request was not authenticated.
                """
            )
        }
        let decoded = try? JSONDecoder().decode(DriveAPIError.self, from: data)
        let message = decoded?.error?.message ?? "No detail returned by Google."
        return .api("Google Drive returned HTTP \(response.statusCode): \(message)")
    }
}

extension GoogleDriveProvider: IncrementallyEnumerable {
    public func startCursor(forRoot rootID: String) async throws -> String {
        var components = URLComponents(
            string: "https://www.googleapis.com/drive/v3/changes/startPageToken"
        )!
        components.queryItems = [
            URLQueryItem(name: "driveId", value: rootID),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
        ]
        let response: DriveStartPageToken = try await get(components)
        return response.startPageToken
    }

    public func changes(
        since cursor: String, forRoot rootID: String
    ) async throws -> RemoteLibraryChanges {
        var changed: [DriveRecord] = []
        var removed: [String] = []
        var pageToken = cursor
        var nextCursor: String?

        // Drain until Drive hands back the token to resume from next time.
        // Page tokens never expire, so a client that has been closed for
        // months still resyncs in a bounded number of calls.
        while nextCursor == nil {
            var components = URLComponents(
                string: "https://www.googleapis.com/drive/v3/changes"
            )!
            components.queryItems = [
                URLQueryItem(name: "pageToken", value: pageToken),
                // The *drive* log, not the user log: files moved into a shared
                // drive stop appearing in the user log entirely.
                URLQueryItem(name: "driveId", value: rootID),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
                // Without both, a removal never arrives and the sidebar keeps
                // offering clips that are gone.
                URLQueryItem(name: "includeRemoved", value: "true"),
                URLQueryItem(name: "includeCorpusRemovals", value: "true"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(
                    name: "fields",
                    value: "nextPageToken,newStartPageToken,changes(fileId,removed,file(\(Self.changeFileFields)))"
                ),
            ]
            let page: DriveChangeList = try await get(components)
            for change in page.changes {
                // `trashed` counts as removed. Google's docs define `removed`
                // only as "removed from this list of changes, for example by
                // deletion or loss of access" and say nothing about trashing,
                // so this handles both readings: if Drive reports a trashed
                // clip as an ordinary change it is caught here, and if it
                // reports one as `removed` the first branch already had it.
                // Getting this wrong the other way would leave a clip a coach
                // deleted sitting in the sidebar until Drive purged it.
                if change.removed == true || change.file == nil || change.file?.trashed == true {
                    removed.append(change.fileId)
                } else if let record = change.file {
                    changed.append(record)
                }
            }
            if let next = page.nextPageToken {
                // A server repeating a token would otherwise re-issue the same
                // request forever, which is the one way this loop's "bounded
                // number of calls" claim could be false.
                guard next != pageToken else {
                    throw RemoteLibraryError.api(
                        "Google Drive repeated a change-feed page token. Refresh again in a moment."
                    )
                }
                pageToken = next
            } else if let newStart = page.newStartPageToken {
                nextCursor = newStart
            } else {
                // Neither token: without this the loop would spin on an
                // unchanged `pageToken`.
                throw RemoteLibraryError.api(
                    "Google Drive returned a change page with neither a next page nor a new start token."
                )
            }
        }

        // A change gives a file id and its parents, not a path. Resolving the
        // folder names needs the tree, which only a sweep has — so a changed
        // file arrives with the parent chain this page could resolve, and a
        // caller wanting more must re-sweep. In practice a new clip's folders
        // are already in the index from the last sweep.
        let folders = Dictionary(
            changed.filter { $0.mimeType == Self.folderMimeType }.map { ($0.id, $0) },
            // Drive can report one record twice — results shift mid-pagination,
            // and a multi-page change drain can repeat a file.
            // `uniqueKeysWithValues` traps on that, which would crash the app
            // on a routine refresh.
            uniquingKeysWith: { first, _ in first }
        )
        return RemoteLibraryChanges(
            changed: changed
                .filter { $0.mimeType != Self.folderMimeType }
                .map { record in
                    RemoteFile(
                        id: record.id,
                        name: record.name,
                        path: Self.folderPath(of: record, in: folders, rootID: rootID),
                        size: Int64(record.size ?? "") ?? 0,
                        contentVersion: record.headRevisionId,
                        md5: record.md5Checksum
                    )
                },
            removed: removed,
            cursor: nextCursor ?? cursor
        )
    }

    /// `trashed` is requested because the sweep excludes trashed files with
    /// `q: trashed = false` and the change feed has no equivalent — without
    /// the field there is no way to tell a trashed clip from a live one.
    static let changeFileFields = "id,name,mimeType,size,md5Checksum,headRevisionId,parents,trashed"
}

// MARK: - Wire formats

struct DriveRecord: Decodable {
    let id: String
    let name: String
    let mimeType: String
    let size: String?
    let md5Checksum: String?
    let headRevisionId: String?
    let parents: [String]?
    /// Only requested by the change feed. The sweep filters trashed files out
    /// server-side with `q: trashed = false`, so it never needs to read this.
    let trashed: Bool?
}

private struct DriveFileList: Decodable {
    let nextPageToken: String?
    let incompleteSearch: Bool?
    let files: [DriveRecord]
}

private struct DriveListOfDrives: Decodable {
    struct Drive: Decodable {
        let id: String
        let name: String
    }

    let nextPageToken: String?
    let drives: [Drive]
}

private struct DriveAPIError: Decodable {
    struct Details: Decodable {
        let code: Int?
        let message: String?
    }

    let error: Details?
}

private struct DriveStartPageToken: Decodable {
    let startPageToken: String
}

private struct DriveChangeList: Decodable {
    struct Change: Decodable {
        let fileId: String
        let removed: Bool?
        let file: DriveRecord?
    }

    let nextPageToken: String?
    let newStartPageToken: String?
    let changes: [Change]
}
