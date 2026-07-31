import AppKit
import CryptoKit
import Foundation
import Network
import Security
import SkiVideoCore

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

enum DriveError: LocalizedError {
    case missingConfiguration
    case invalidClientSecrets
    case oauthCallback(String)
    case tokenExchange(String)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Choose an OAuth client-secret JSON file and enter a Shared Drive folder ID."
        case .invalidClientSecrets:
            return "That file is not a valid Google desktop OAuth client-secret JSON file."
        case let .oauthCallback(message), let .tokenExchange(message), let .api(message):
            return message
        }
    }
}

struct GoogleDriveClient {
    private static let folderMimeType = "application/vnd.google-apps.folder"
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]

    private let accessToken: String

    static func connect(clientSecretsURL: URL) async throws -> GoogleDriveClient {
        let client = try GoogleOAuthClient.load(from: clientSecretsURL)
        let token = try await GoogleOAuth.authorize(client: client)
        return GoogleDriveClient(accessToken: token)
    }

    func scanSharedDrive(folderID: String) async throws -> DriveLibrary {
        var groups: [String: [URL]] = [:]
        var names: [String: String] = [:]
        var mediaByURL: [URL: DriveMedia] = [:]

        func scan(folderID: String, parentName: String?) async throws {
            for file in try await listChildren(of: folderID) {
                if file.mimeType == Self.folderMimeType {
                    try await scan(folderID: file.id, parentName: file.name)
                    continue
                }
                guard file.canDownload,
                      Self.videoExtensions.contains(URL(fileURLWithPath: file.name).pathExtension.lowercased())
                else {
                    continue
                }

                let athleteName = parentName ?? "Unsorted"
                let key = athleteName.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )
                let streamURL = URL(string: "drivevideo://\(file.id)")!
                    .appendingPathComponent(file.name)
                let media = DriveMedia(
                    fileID: file.id,
                    name: file.name,
                    mimeType: file.mimeType,
                    size: Int64(file.size ?? "") ?? 0,
                    accessToken: accessToken
                )
                names[key] = names[key] ?? athleteName
                groups[key, default: []].append(streamURL)
                mediaByURL[streamURL] = media
            }
        }

        try await scan(folderID: folderID, parentName: nil)
        let athletes = groups.keys
            .sorted {
                (names[$0] ?? $0).localizedCaseInsensitiveCompare(names[$1] ?? $1)
                    == .orderedAscending
            }
            .map { key in
                AthleteGroup(
                    id: key,
                    name: names[key] ?? key,
                    videos: groups[key, default: []].sorted {
                        $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent)
                            == .orderedAscending
                    }
                )
            }
        return DriveLibrary(athletes: athletes, mediaByURL: mediaByURL)
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

    static func authorize(client: GoogleOAuthClient.Details) async throws -> String {
        if let refreshToken = KeychainTokenStore.load(account: client.clientID) {
            do {
                return try await refreshAccessToken(refreshToken: refreshToken, client: client)
            } catch {
                // A revoked or expired refresh token should not permanently prevent a new sign-in.
                KeychainTokenStore.remove(account: client.clientID)
            }
        }

        let server = try OAuthCallbackServer()
        let callbackPort = try await server.start()
        let state = randomURLSafeString(byteCount: 24)
        let verifier = randomURLSafeString(byteCount: 48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let redirectURI = "http://127.0.0.1:\(callbackPort)"
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
        NSWorkspace.shared.open(authorizationURL)

        let callback = try await server.waitForCallback()
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

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
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

private final class OAuthCallbackServer {
    private let listener: NWListener
    private var port: UInt16?
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var startResult: Result<UInt16, Error>?
    private var callbackResult: Result<URL, Error>?

    init() throws {
        // Let macOS choose an unused loopback port. This avoids a prior app launch or
        // another process on a fixed port leaving OAuth waiting forever.
        listener = try NWListener(using: .tcp)
    }

    func start() async throws -> UInt16 {
        if let startResult {
            return try startResult.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            beginListening()
        }
    }

    private func beginListening() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = self.listener.port?.rawValue else {
                    self.completeStart(.failure(DriveError.oauthCallback("Google sign-in callback did not receive a local port.")))
                    return
                }
                self.port = port
                self.completeStart(.success(port))
            case let .failed(error):
                let callbackError = DriveError.oauthCallback(
                    "Could not start the local Google sign-in callback: \(error.localizedDescription)"
                )
                self.completeStart(.failure(callbackError))
                self.completeCallback(.failure(callbackError))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.receiveCallback(on: connection)
        }
        listener.start(queue: .main)
    }

    func waitForCallback() async throws -> URL {
        if let callbackResult {
            return try callbackResult.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            callbackContinuation = continuation
        }
    }

    private func receiveCallback(on connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            defer { connection.cancel() }
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let requestLine = request.split(separator: "\n").first,
                  let target = requestLine.split(separator: " ").dropFirst().first,
                  let port = self.port,
                  let callback = URL(string: "http://127.0.0.1:\(port)\(target)")
            else {
                return
            }
            let html = "<html><body style='font-family:-apple-system;padding:2rem'><h2>Google Drive connected</h2><p>You can close this tab and return to Ski Video Viewer.</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in })
            self.completeCallback(.success(callback))
        }
    }

    private func completeStart(_ result: Result<UInt16, Error>) {
        guard startResult == nil else { return }
        startResult = result
        startContinuation?.resume(with: result)
        startContinuation = nil
    }

    private func completeCallback(_ result: Result<URL, Error>) {
        guard callbackResult == nil else { return }
        callbackResult = result
        listener.cancel()
        callbackContinuation?.resume(with: result)
        callbackContinuation = nil
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
