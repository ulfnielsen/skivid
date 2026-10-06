import Foundation

/// The club-Drive upload's write operations, in their own file because
/// `GoogleDriveProvider.swift` is already the largest in the module and these
/// share nothing with it but the authorised-request helper.
extension GoogleDriveProvider: ItemCreatable {
    /// How many times a failed upload is resumed before giving up. Bounded so
    /// a dead network ends as an error the caller can retry per clip, rather
    /// than a loop that never returns.
    static let maxUploadResumes = 3

    // MARK: - Find

    public func findFolder(named name: String, parent parentID: String) async throws -> RemoteItem? {
        try await find(named: name, parent: parentID, folders: true)
    }

    public func findFile(named name: String, parent parentID: String) async throws -> RemoteItem? {
        try await find(named: name, parent: parentID, folders: false)
    }

    private func find(named name: String, parent parentID: String, folders: Bool) async throws -> RemoteItem? {
        let kind = folders ? "=" : "!="
        let query = "name = '\(Self.escapeQueryLiteral(name))'"
            + " and '\(Self.escapeQueryLiteral(parentID))' in parents"
            + " and mimeType \(kind) '\(Self.folderMimeType)'"
            + " and trashed = false"
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
            // Per Drive's files.list documentation, items in a Shared Drive
            // are only searched with an `allDrives` or `drive` corpus; the
            // default corpus is the user's own. Not yet exercised against a
            // live Shared Drive.
            URLQueryItem(name: "corpora", value: "allDrives"),
            // Oldest first, so when two coaches raced and left duplicates
            // every client settles on the same one rather than an arbitrary
            // one — later clips must not scatter across the twins.
            URLQueryItem(name: "orderBy", value: "createdTime"),
            URLQueryItem(name: "fields", value: "incompleteSearch,files(id,name)"),
            URLQueryItem(name: "pageSize", value: "10"),
        ]
        let listing: Listing = try await get(components)
        // A partial result would read as "not there" and cause a duplicate
        // folder or upload; `sweep` treats the flag as fatal for the same reason.
        if listing.incompleteSearch == true {
            throw RemoteLibraryError.api(
                "Google Drive returned an incomplete search. Try again.")
        }
        return listing.files.first.map { RemoteItem(id: $0.id, name: $0.name) }
    }

    /// Drive omits `files` entirely when nothing matches — its reply is
    /// `{"kind":"drive#fileList","incompleteSearch":false}` — so absence
    /// means empty (see `DriveFileList` for the same rule on the sweep).
    private struct Listing: Decodable {
        struct Entry: Decodable { let id: String; let name: String }
        let incompleteSearch: Bool?
        let files: [Entry]

        enum CodingKeys: String, CodingKey { case incompleteSearch, files }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            incompleteSearch = try container.decodeIfPresent(Bool.self, forKey: .incompleteSearch)
            files = try container.decodeIfPresent([Entry].self, forKey: .files) ?? []
        }
    }

    /// Escapes a value for a single-quoted Drive `q` literal: backslash and
    /// single quote, backslash first so the quote's own escape survives. A
    /// name like "O'Brien" would otherwise end the literal early.
    static func escapeQueryLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    // MARK: - Create

    public func createFolder(named name: String, parent parentID: String) async throws -> RemoteItem {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            // Omitting this fails against a Shared Drive — see `replaceContents`.
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "fields", value: "id,name"),
        ]
        let body = try Self.metadataJSON(name: name, parent: parentID, mimeType: Self.folderMimeType)
        let (data, response) = try await authorized({ bearer in
            var request = Self.request(components, bearer: bearer, method: "POST")
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            return request
        }, send: { try await transport.data(for: $0) })
        return try Self.createdItem(data, response)
    }

    public func findOrCreateFolder(named name: String, parent parentID: String) async throws -> RemoteItem {
        if let existing = try await findFolder(named: name, parent: parentID) { return existing }
        return try await createFolder(named: name, parent: parentID)
    }

    // MARK: - Upload

    /// Resumable upload: a POST that opens a session, then the bytes to the
    /// session URI the reply's `Location` names.
    ///
    /// Resumable rather than `uploadType=media` because a dropped signal
    /// mid-clip is the normal case on a hill: the session lets a later
    /// request ask the server how much arrived and send only the rest.
    ///
    /// **One PUT of the remainder, not chunks.** A single request carries
    /// least overhead, and a failure costs nothing extra because recovery is
    /// the same either way — ask the server for its offset and send from
    /// there. Chunking would only bound how much is re-sent after a failure
    /// that left the server's offset behind, at the price of a round trip per
    /// chunk and the 256 KiB-multiple rule on non-final chunks.
    ///
    /// Drive's resumable-upload protocol (session at
    /// `upload/drive/v3/files?uploadType=resumable`, status query with
    /// `Content-Range: bytes */total` answered 308 with an optional `Range`)
    /// is taken from its documentation; it is covered here by a fake
    /// transport and has not been run against the live API.
    public func upload(fileAt url: URL, named name: String, parent parentID: String) async throws -> RemoteItem {
        let total = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard total > 0 else {
            throw RemoteLibraryError.api("The clip to upload is empty.")
        }

        let session = try await openUploadSession(name: name, parent: parentID, total: total)

        var offset: Int64 = 0
        var resumes = 0
        while true {
            do {
                let (data, response) = try await authorized({ bearer in
                    var request = URLRequest(url: session)
                    request.httpMethod = "PUT"
                    // The session URI identifies the session by itself; the
                    // bearer is sent as well so a refreshed token (after a
                    // 401) is what the retry carries.
                    request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
                    request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
                    request.setValue(
                        "bytes \(offset)-\(total - 1)/\(total)", forHTTPHeaderField: "Content-Range")
                    return request
                }, send: { try await transport.upload($0, fromFile: url, range: offset..<total) })
                if (200...299).contains(response.statusCode) {
                    return try Self.createdItem(data, response)
                }
                // Only a server-side hiccup is worth resuming; a 4xx is a
                // verdict, and repeating it would not change it.
                guard response.statusCode >= 500 else {
                    throw Self.uploadFailure(data: data, response: response)
                }
            } catch let error as RemoteLibraryError {
                throw error
            } catch let error as RemoteUploadError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw error
            } catch {
                // The connection dropped: fall through to resume.
            }

            resumes += 1
            guard resumes <= Self.maxUploadResumes else {
                throw RemoteUploadError.retryClip(
                    "The upload of \(name) was interrupted and could not be resumed. Try the clip again.")
            }
            // A failed status query is another attempt, not a reason to stop
            // early: the network may be back by the next one.
            do {
                switch try await uploadedOffset(session: session, total: total) {
                case .offset(let confirmed): offset = confirmed
                case .complete(let item): return item
                }
            } catch let error as RemoteUploadError {
                // The session is gone or the drive refuses us: asking again
                // changes nothing.
                throw error
            } catch {}
        }
    }

    private func openUploadSession(name: String, parent parentID: String, total: Int64) async throws -> URL {
        var components = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "resumable"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "fields", value: "id,name"),
        ]
        let body = try Self.metadataJSON(name: name, parent: parentID, mimeType: nil)
        let (data, response) = try await authorized({ bearer in
            var request = Self.request(components, bearer: bearer, method: "POST")
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.setValue("video/mp4", forHTTPHeaderField: "X-Upload-Content-Type")
            request.setValue(String(total), forHTTPHeaderField: "X-Upload-Content-Length")
            request.httpBody = body
            return request
        }, send: { try await transport.data(for: $0) })
        guard (200...299).contains(response.statusCode) else {
            throw Self.uploadFailure(data: data, response: response)
        }
        guard let location = response.value(forHTTPHeaderField: "Location"),
              let session = URL(string: location)
        else {
            throw RemoteLibraryError.api("Google Drive did not return an upload address.")
        }
        return session
    }

    private enum SessionState {
        case offset(Int64)
        case complete(RemoteItem)
    }

    /// Asks the server how much of the session it has. 308 with `Range:
    /// bytes=0-N` means N+1 bytes; 308 with no `Range` means none; a 2xx
    /// means the file had in fact arrived.
    private func uploadedOffset(session: URL, total: Int64) async throws -> SessionState {
        let (data, response) = try await authorized({ bearer in
            var request = URLRequest(url: session)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            request.setValue("bytes */\(total)", forHTTPHeaderField: "Content-Range")
            request.setValue("0", forHTTPHeaderField: "Content-Length")
            return request
        }, send: { try await transport.data(for: $0) })
        if (200...299).contains(response.statusCode) {
            return .complete(try Self.createdItem(data, response))
        }
        guard response.statusCode == 308 else {
            throw Self.uploadFailure(data: data, response: response)
        }
        guard let range = response.value(forHTTPHeaderField: "Range"),
              let last = range.split(separator: "-").last.flatMap({ Int64($0) })
        else { return .offset(0) }
        return .offset(last + 1)
    }

    // MARK: - Helpers

    /// Sorts an upload's refusal into what the caller should do about it:
    /// 403 stops the batch (no edit access — every further clip would fail
    /// the same way); 404/410 means the session expired, so the clip is
    /// retried and opens a fresh one. Anything else keeps the generic error.
    private static func uploadFailure(data: Data, response: HTTPURLResponse) -> Error {
        switch response.statusCode {
        case 403:
            guard case .api(let message) = describeWriteFailure(data: data, response: response) else {
                return describeWriteFailure(data: data, response: response)
            }
            return RemoteUploadError.stopBatch(message)
        case 404, 410:
            return RemoteUploadError.retryClip(
                "The upload session expired. Try the clip again to start a fresh one.")
        default:
            return describeWriteFailure(data: data, response: response)
        }
    }

    private static func request(_ components: URLComponents, bearer: String, method: String) -> URLRequest {
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func metadataJSON(name: String, parent: String, mimeType: String?) throws -> Data {
        var object: [String: Any] = ["name": name, "parents": [parent]]
        if let mimeType { object["mimeType"] = mimeType }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func createdItem(_ data: Data, _ response: HTTPURLResponse) throws -> RemoteItem {
        guard (200...299).contains(response.statusCode) else {
            throw describeWriteFailure(data: data, response: response)
        }
        struct Created: Decodable { let id: String; let name: String? }
        let created: Created = try decode(data)
        return RemoteItem(id: created.id, name: created.name ?? "")
    }
}
