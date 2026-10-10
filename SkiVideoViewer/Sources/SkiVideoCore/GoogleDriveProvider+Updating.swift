import Foundation

/// The event rename's writes, beside `+Creating` and sharing its helpers.
/// Every request carries `supportsAllDrives=true`: without it a Shared Drive
/// answers 404 (see `replaceContents`).
extension GoogleDriveProvider: ItemUpdatable {
    public func listChildren(of folderID: String) async throws -> [RemoteChild] {
        var children: [RemoteChild] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            var items = [
                URLQueryItem(name: "q", value: "'\(Self.escapeQueryLiteral(folderID))' in parents and trashed = false"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
                URLQueryItem(name: "corpora", value: "allDrives"),
                URLQueryItem(name: "fields", value: "nextPageToken,incompleteSearch,files(id,name,mimeType)"),
                URLQueryItem(name: "pageSize", value: "1000"),
            ]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = items
            let page: ChildPage = try await get(components)
            if page.incompleteSearch == true {
                throw RemoteLibraryError.api("Google Drive returned an incomplete listing. Try again.")
            }
            children += page.files.map {
                RemoteChild(id: $0.id, name: $0.name, isFolder: $0.mimeType == Self.folderMimeType)
            }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return children
    }

    public func rename(itemID: String, to newName: String) async throws {
        try await patch(itemID, query: [], body: ["name": newName])
    }

    public func move(itemID: String, from oldParentID: String, to newParentID: String) async throws {
        try await patch(itemID, query: [
            URLQueryItem(name: "addParents", value: newParentID),
            URLQueryItem(name: "removeParents", value: oldParentID),
        ], body: [:])
    }

    public func trash(itemID: String) async throws {
        try await patch(itemID, query: [], body: ["trashed": true])
    }

    private func patch(_ itemID: String, query: [URLQueryItem], body: [String: Any]) async throws {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(itemID)")!
        components.queryItems = query + [
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "fields", value: "id,name"),
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await authorized({ bearer in
            var request = Self.request(components, bearer: bearer, method: "PATCH")
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload
            return request
        }, send: { try await transport.data(for: $0) })
        guard (200...299).contains(response.statusCode) else {
            // Not `uploadFailure`: its 404/410 wording is about upload sessions.
            if response.statusCode == 403 { throw Self.forbidden(data: data, response: response) }
            throw Self.describeWriteFailure(data: data, response: response)
        }
    }

    /// Drive omits `files` when the folder is empty; absence means none.
    private struct ChildPage: Decodable {
        struct Entry: Decodable { let id: String; let name: String; let mimeType: String }
        let nextPageToken: String?
        let incompleteSearch: Bool?
        let files: [Entry]

        enum CodingKeys: String, CodingKey { case nextPageToken, incompleteSearch, files }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            nextPageToken = try c.decodeIfPresent(String.self, forKey: .nextPageToken)
            incompleteSearch = try c.decodeIfPresent(Bool.self, forKey: .incompleteSearch)
            files = try c.decodeIfPresent([Entry].self, forKey: .files) ?? []
        }
    }
}
