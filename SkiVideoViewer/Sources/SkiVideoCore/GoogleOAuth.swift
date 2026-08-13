/// Google's OAuth 2.0 flow for an installed app: PKCE, a presenter-supplied
/// redirect, and a refresh token in the Keychain.
///
/// Its own file because it is not about Drive. The same flow authorizes any
/// Google API, and keeping it beside the Drive client made a 510-line file
/// that did five jobs.

import CryptoKit
import Foundation
import Security

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

struct GoogleOAuthClient: Decodable {
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

enum GoogleOAuth {
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
