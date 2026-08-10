import CryptoKit
import Foundation
import Security

struct DriveMedia: Hashable {
    let fileID: String
    let name: String
    let mimeType: String
    let size: Int64
    let accessToken: String

    /// Google Drive accepts OAuth access tokens on its HTTPS media endpoint. Using
    /// this native URL lets AVPlayer perform normal range requests itself.
    var streamingURL: URL {
        var components = URLComponents(
            string: "https://www.googleapis.com/drive/v3/files/\(fileID)"
        )!
        components.queryItems = [
            URLQueryItem(name: "alt", value: "media"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "access_token", value: accessToken),
        ]
        return components.url!
    }
}

struct DriveLibrary {
    let athletes: [AthleteGroup]
    let mediaByURL: [URL: DriveMedia]
}

/// Public because the platform `OAuthPresenter` implementations throw it —
/// `DriveMedia`, `DriveLibrary` and `GoogleDriveClient` stay internal, since
/// only `ViewerModel` touches them and it now lives in this module too.
public enum DriveError: LocalizedError {
    case missingConfiguration
    case invalidClientSecrets
    case oauthCallback(String)
    case tokenExchange(String)
    case api(String)
    case secureRandomnessUnavailable

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Choose an OAuth client-secret JSON file and enter a Shared Drive folder ID."
        case .invalidClientSecrets:
            return "That file is not a valid Google desktop OAuth client-secret JSON file."
        case let .oauthCallback(message), let .tokenExchange(message), let .api(message):
            return message
        case .secureRandomnessUnavailable:
            return "Could not generate a secure random value for Google sign-in. Please try again."
        }
    }
}

struct GoogleDriveClient {
    private static let folderMimeType = "application/vnd.google-apps.folder"

    private let accessToken: String

    static func connect(
        clientSecretsURL: URL,
        presenter: OAuthPresenter
    ) async throws -> GoogleDriveClient {
        let client = try GoogleOAuthClient.load(from: clientSecretsURL)
        let token = try await GoogleOAuth.authorize(client: client, presenter: presenter)
        return GoogleDriveClient(accessToken: token)
    }

    func scanSharedDrive(folderID: String) async throws -> DriveLibrary {
        var entries: [LibraryGrouping.Entry] = []
        var mediaByURL: [URL: DriveMedia] = [:]

        // A clip sitting loose in the chosen root has no athlete folder to be
        // named after, so ask Drive what the root itself is called:
        // `VideoLibrary.scan` names that group after the chosen folder, and this
        // is the closest Drive can come to it. The literal "Unsorted" stood here
        // until 2026-08-09, which was wrong because the name is the grouping
        // *key*, not a caption — a Drive folder genuinely named `Unsorted` and
        // the loose files silently became one athlete.
        //
        // Deliberately non-fatal. The name is a label for one group that many
        // libraries never even produce, so it must not be able to fail a scan
        // that would otherwise succeed — a folder whose *children* are shared
        // with the operator but whose own record is not would list fine here and
        // 403 on the `files.get`. Falling back to the pasted folder id keeps a
        // unique key, which is the whole reason "Unsorted" had to go.
        //
        // UNVERIFIED, and it needs credentials to settle: whether `files.get`
        // returns a name when `folderID` is a Shared Drive's own id rather than
        // a folder inside it. With `try?` the answer stops mattering — either
        // the name arrives or the id is used — which is why this does not wait
        // on someone measuring it.
        let rootName = (try? await folderName(of: folderID)) ?? folderID

        // Both names are carried, not just the athlete's: the event is the
        // folder directly above the athlete, so the recursion has to remember
        // one more level than it used to. `VideoLibrary.scan` reads the same
        // two components out of the path — the rule is one rule, applied to
        // whatever each scanner can see.
        func scan(folderID: String, parentName: String?, grandparentName: String?) async throws {
            for file in try await listChildren(of: folderID) {
                if file.mimeType == Self.folderMimeType {
                    try await scan(
                        folderID: file.id,
                        parentName: file.name,
                        grandparentName: parentName
                    )
                    continue
                }
                // The same list the local library uses, deliberately not a copy.
                // Drive kept its own set until 2026-08-08, still naming avi, mkv
                // and webm after the local one dropped them — so Drive offered
                // files that `AVPlayer` cannot open and the sidebar would not
                // have listed. One source of truth cannot drift like that.
                guard file.canDownload,
                      VideoLibrary.supportedExtensions
                          .contains(URL(fileURLWithPath: file.name).pathExtension.lowercased())
                else {
                    continue
                }

                // The folder hierarchy is absent from this URL: the host is the
                // file id and the path is just `/<name>`. So where a local scan
                // sorts clips by folder-then-name, both inside `LibraryGrouping`
                // and within a group, Drive clips sort by file name alone. Two
                // sibling folders that fold alike (`Andre/`, `André/`) therefore
                // take their winning spelling from whichever folder holds the
                // alphabetically first *file* name, and their clips interleave
                // instead of staying in folder blocks. Deterministic run to run
                // — `pathOrder` is a total order and breaks the file-name tie on
                // the full URL — just not the local scanner's order.
                let streamURL = URL(string: "drivevideo://\(file.id)")!
                    .appendingPathComponent(file.name)
                mediaByURL[streamURL] = DriveMedia(
                    fileID: file.id,
                    name: file.name,
                    mimeType: file.mimeType,
                    size: Int64(file.size ?? "") ?? 0,
                    accessToken: accessToken
                )
                entries.append(
                    LibraryGrouping.Entry(
                        video: streamURL,
                        athlete: parentName ?? rootName,
                        // A file loose in the chosen root has neither an athlete
                        // folder nor an event; one in `root/Athlete` has an
                        // athlete but no event, exactly as locally. The latter
                        // holds because the top-level call seeds *both* names
                        // nil: seeding `parentName` with the root's own name
                        // instead would read the root as an event one level
                        // down, which is the mistake the local scanner had to
                        // fix. Nothing here can catch that — this comment is the
                        // guard, so keep the seeding as it is.
                        event: grandparentName
                    )
                )
            }
        }

        try await scan(folderID: folderID, parentName: nil, grandparentName: nil)
        return DriveLibrary(
            athletes: LibraryGrouping.group(entries),
            mediaByURL: mediaByURL
        )
    }

    /// The chosen root folder's own name, which is all the loose clips at the
    /// top of it have to be grouped under.
    ///
    /// Throws like every other call here, but the one caller swallows it: see
    /// `scanSharedDrive` for why a label that most libraries never display must
    /// not be able to fail a scan. It costs one request per scan, next to the
    /// many `files.list` calls the walk makes.
    private func folderName(of folderID: String) async throws -> String {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        // Appended through `path` rather than interpolated into the string, so a
        // pasted id that is not URL-safe gets percent-encoded instead of
        // reshaping the request.
        components.path += "/\(folderID)"
        components.queryItems = [
            URLQueryItem(name: "fields", value: "name"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
        ]
        guard let url = components.url else {
            throw DriveError.api("That Shared Drive folder ID cannot be used in a request to Google.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else {
            throw GoogleAPIError.describe(
                data: data,
                response: response,
                action: "open this Shared Drive folder"
            )
        }
        do {
            return try JSONDecoder().decode(DriveFolderName.self, from: data).name
        } catch {
            throw DriveError.api("Google Drive returned an unexpected folder record: \(error.localizedDescription)")
        }
    }

    private func listChildren(of folderID: String) async throws -> [DriveFile] {
        var files: [DriveFile] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            components.queryItems = [
                URLQueryItem(name: "q", value: "'\(folderID)' in parents and trashed = false"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,size,capabilities(canDownload))"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
            ]
            if let pageToken {
                components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode)
            else {
                throw GoogleAPIError.describe(
                    data: data,
                    response: response,
                    action: "list this Shared Drive folder"
                )
            }
            let page: DriveListResponse
            do {
                page = try JSONDecoder().decode(DriveListResponse.self, from: data)
            } catch {
                throw DriveError.api("Google Drive returned an unexpected folder listing: \(error.localizedDescription)")
            }
            files.append(contentsOf: page.files)
            pageToken = page.nextPageToken
        } while pageToken != nil
        return files
    }
}

/// Its own type rather than a `DriveFile` decode, because the folder record is
/// fetched with `fields=name` alone: everything `DriveFile` requires beyond the
/// name is absent from that response.
private struct DriveFolderName: Decodable {
    let name: String
}

private struct DriveListResponse: Decodable {
    let nextPageToken: String?
    let files: [DriveFile]
}

private struct DriveFile: Decodable {
    let id: String
    let name: String
    let mimeType: String
    let size: String?
    let capabilities: DriveCapabilities?

    var canDownload: Bool { capabilities?.canDownload ?? false }
}

private struct GoogleAPIError: Decodable {
    struct Details: Decodable {
        let code: Int?
        let message: String?
        let status: String?
    }

    let error: Details?

    static func describe(data: Data, response: URLResponse, action: String) -> DriveError {
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        let decoded = try? JSONDecoder().decode(GoogleAPIError.self, from: data)
        let message = decoded?.error?.message ?? "No detail returned by Google."
        let status = statusCode.map { " (HTTP \($0))" } ?? ""
        return .api("Google Drive could not \(action)\(status): \(message)")
    }
}

private struct DriveCapabilities: Decodable {
    let canDownload: Bool
}

private struct GoogleOAuthClient: Decodable {
    struct Details: Decodable {
        let clientID: String
        let clientSecret: String
        let authURI: String
        let tokenURI: String

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case clientSecret = "client_secret"
            case authURI = "auth_uri"
            case tokenURI = "token_uri"
        }
    }

    let installed: Details?

    static func load(from url: URL) throws -> Details {
        let decoded = try JSONDecoder().decode(GoogleOAuthClient.self, from: Data(contentsOf: url))
        guard let installed = decoded.installed else { throw DriveError.invalidClientSecrets }
        return installed
    }
}

private enum GoogleOAuth {
    private static let scope = "https://www.googleapis.com/auth/drive.readonly"

    static func authorize(
        client: GoogleOAuthClient.Details,
        presenter: OAuthPresenter
    ) async throws -> String {
        if let refreshToken = KeychainTokenStore.load(account: client.clientID) {
            do {
                return try await refreshAccessToken(refreshToken: refreshToken, client: client)
            } catch {
                // A revoked or expired refresh token should not permanently prevent a new sign-in.
                KeychainTokenStore.remove(account: client.clientID)
            }
        }

        let redirectURI = try await presenter.prepareRedirectURI()
        let state = try randomURLSafeString(byteCount: 24)
        let verifier = try randomURLSafeString(byteCount: 48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        var components = URLComponents(string: client.authURI)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let authorizationURL = components.url else { throw DriveError.invalidClientSecrets }

        let callback = try await presenter.authorize(
            authorizationURL: authorizationURL,
            redirectURI: redirectURI
        )
        guard let callbackComponents = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              callbackComponents.queryItems?.first(where: { $0.name == "state" })?.value == state
        else {
            throw DriveError.oauthCallback("Google sign-in response could not be verified.")
        }
        if let error = callbackComponents.queryItems?.first(where: { $0.name == "error" })?.value {
            throw DriveError.oauthCallback("Google sign-in failed: \(error)")
        }
        guard let code = callbackComponents.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw DriveError.oauthCallback("Google did not return an authorization code.")
        }

        let token = try await tokenRequest(
            client: client,
            values: [
                "code": code,
                "redirect_uri": redirectURI,
                "grant_type": "authorization_code",
                "code_verifier": verifier,
            ]
        )
        guard let refreshToken = token.refreshToken else {
            throw DriveError.tokenExchange("Google did not return a refresh token. Try connecting again.")
        }
        try KeychainTokenStore.save(refreshToken, account: client.clientID)
        return token.accessToken
    }

    private static func refreshAccessToken(
        refreshToken: String,
        client: GoogleOAuthClient.Details
    ) async throws -> String {
        try await tokenRequest(
            client: client,
            values: [
                "refresh_token": refreshToken,
                "grant_type": "refresh_token",
            ]
        ).accessToken
    }

    private static func tokenRequest(
        client: GoogleOAuthClient.Details,
        values: [String: String]
    ) async throws -> GoogleTokenResponse {
        var formValues = values
        formValues["client_id"] = client.clientID
        formValues["client_secret"] = client.clientSecret
        var request = URLRequest(url: URL(string: client.tokenURI)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formValues
            .map { "\($0.key.urlFormEncoded)=\($0.value.urlFormEncoded)" }
            .sorted()
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else {
            throw GoogleAPIError.describe(
                data: data,
                response: response,
                action: "complete the Google sign-in"
            )
        }
        do {
            return try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
        } catch {
            throw DriveError.tokenExchange("Google returned an unexpected sign-in response: \(error.localizedDescription)")
        }
    }

    private static func randomURLSafeString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw DriveError.secureRandomnessUnavailable
        }
        return Data(bytes).base64URLEncodedString()
    }
}

private struct GoogleTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

private enum KeychainTokenStore {
    private static let service = "ch.ski.video-viewer.google-drive"

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String, account: String) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let value: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(attributes as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var item = attributes
            item[kSecValueData as String] = Data(token.utf8)
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw DriveError.tokenExchange("Could not save the Google sign-in token in Keychain.")
            }
        } else if status != errSecSuccess {
            throw DriveError.tokenExchange("Could not update the Google sign-in token in Keychain.")
        }
    }

    static func remove(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self
    }
}
