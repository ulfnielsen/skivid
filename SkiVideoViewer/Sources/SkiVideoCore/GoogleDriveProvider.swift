import Foundation

/// Google Drive as a remote library.
///
/// One flat paged sweep per Shared Drive, not a folder-by-folder walk: Drive
/// can list a whole drive with `corpora=drive`, so a 1,000-clip library is two
/// round trips rather than one per folder. The folder tree is rebuilt here
/// from each file's `parents`.
public struct GoogleDriveProvider: RemoteLibraryProvider {
    public static let identifier = "gdrive"

    private static let folderMimeType = "application/vnd.google-apps.folder"
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
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/drives")!
        components.queryItems = [
            // The default is 10, which would silently truncate the picker for
            // an account in more drives than that.
            URLQueryItem(name: "pageSize", value: "100"),
        ]
        let page: DriveListOfDrives = try await get(components)
        return page.drives.map { RemoteFolder(id: $0.id, name: $0.name) }
    }

    public func enumerate(_ folder: RemoteFolder) -> AsyncThrowingStream<RemoteFile, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let records = try await sweep(driveID: folder.id)
                    let folders = Dictionary(
                        uniqueKeysWithValues: records
                            .filter { $0.mimeType == Self.folderMimeType }
                            .map { ($0.id, $0) }
                    )
                    for record in records where record.mimeType != Self.folderMimeType {
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
        var seen: Set<String> = []
        var current = record.parents?.first
        while let id = current, id != rootID, !seen.contains(id), names.count <= folders.count {
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

// MARK: - Wire formats

struct DriveRecord: Decodable {
    let id: String
    let name: String
    let mimeType: String
    let size: String?
    let md5Checksum: String?
    let headRevisionId: String?
    let parents: [String]?
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

    let drives: [Drive]
}

private struct DriveAPIError: Decodable {
    struct Details: Decodable {
        let code: Int?
        let message: String?
    }

    let error: Details?
}
