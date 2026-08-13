/// Google's OAuth 2.0 flow for an installed app: PKCE, a presenter-supplied
/// redirect, and a refresh token in the Keychain.
///
/// Its own file because it is not about Drive. The same flow authorizes any
/// Google API, and keeping it beside the Drive client made a 510-line file
/// that did five jobs.

import CryptoKit
import Foundation
import Security

/// Public because the platform `OAuthPresenter` implementations throw it.
public enum DriveError: LocalizedError, Equatable {
    case oauthCallback(String)
    case tokenExchange(String)
    case api(String)
    case secureRandomnessUnavailable
    /// The account is outside the club's Workspace. Google refuses these
    /// outright for an Internal app — there is no request-access prompt — so
    /// the message has to say which account to use instead.
    case notInOrganisation
    /// A Workspace administrator has not allowed this app under
    /// Admin console → API controls. Nothing the coach can do.
    case blockedByAdministrator

    public var errorDescription: String? {
        switch self {
        case let .oauthCallback(message), let .tokenExchange(message), let .api(message):
            return message
        case .secureRandomnessUnavailable:
            return "Could not generate a secure random value for Google sign-in. Please try again."
        case .notInOrganisation:
            return "This Google account is not in the club's Workspace. Sign in with your club account."
        case .blockedByAdministrator:
            return "A Workspace administrator has to allow this app under Admin console → API controls before it can open the club's Drive."
        }
    }
}

/// How this platform receives the authorization redirect.
///
/// Not a detail: loopback has been blocked for iOS OAuth clients since
/// 21 October 2022, and the out-of-band paste-the-code flow is dead for every
/// client type since 31 January 2023. macOS uses a Desktop client and a
/// loopback listener; iPad uses an iOS client and a reverse-DNS scheme.
public enum GoogleRedirectKind: Sendable {
    case loopback
    case customScheme(String)
}

public struct GoogleOAuthConfiguration: Sendable {
    public let clientID: String
    /// Absent for an iOS client, which Google issues without one. The token
    /// request must then omit the field rather than send it empty.
    public let clientSecret: String?
    public let redirectKind: GoogleRedirectKind

    public init(clientID: String, clientSecret: String?, redirectKind: GoogleRedirectKind) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectKind = redirectKind
    }
}

enum GoogleOAuth {
    private static let scope = "https://www.googleapis.com/auth/drive.readonly"
    // Fixed Google endpoints. The client-secret JSON this flow used to read
    // carried the same two URLs for every installed-app client, so there is
    // nothing left to configure once the file is gone.
    private static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    /// Stands in for the loopback port in `redirectURI(for:)`. The redirect
    /// URI has to be built before the listener that owns the real port
    /// exists — it is a query parameter of the authorization URL, and the
    /// listener is what assigns the port in the first place — so whichever
    /// presenter drives the flow through this function is expected to
    /// substitute the real port for this token before using the result.
    ///
    /// No presenter does that substitution yet: `redirectURI(for:)` is not on
    /// the live path, and `AppKitOAuthPresenter` builds its own loopback URI
    /// directly (`AppKitOAuthPresenter.swift`). Task 3 routes `authorize`'s
    /// redirect through this function, at which point the substitution
    /// becomes the presenter's job — and `authorize` refuses a redirect URI
    /// that still carries this token, below, so a presenter that forgets
    /// fails loudly instead of sending Google a URL it can never match.
    static let loopbackPortPlaceholder = "PORT"

    /// The redirect URI Google should send its authorization response to.
    ///
    /// `.customScheme` is fully determined by configuration. `.loopback`
    /// cannot be: the actual port is only known once a listener is running,
    /// so this carries `loopbackPortPlaceholder` in its place.
    static func redirectURI(for configuration: GoogleOAuthConfiguration) -> String {
        switch configuration.redirectKind {
        case .loopback:
            return "http://127.0.0.1:\(loopbackPortPlaceholder)"
        case let .customScheme(scheme):
            return "\(scheme):/oauth2redirect"
        }
    }

    /// Rejects a redirect URI that still carries the loopback port
    /// placeholder. A presenter driving the flow through `redirectURI(for:)`
    /// is expected to substitute its listener's real port before handing the
    /// result back; one that forgot would otherwise send Google a
    /// `redirect_uri` it can never match, which surfaces as an opaque
    /// "redirect mismatch" rather than as the bug it is. `authorize` calls
    /// this on whatever redirect URI it is given, whatever its source.
    ///
    /// A free function rather than inline in `authorize` so it is testable
    /// without going through the Keychain lookup `authorize` starts with.
    static func requireCompleteRedirectURI(_ redirectURI: String) throws {
        guard !redirectURI.contains(loopbackPortPlaceholder) else {
            throw DriveError.oauthCallback(
                "Sign-in could not start: the redirect address was not completed with a port."
            )
        }
    }

    /// Maps the callback's `error` query parameter to the specific case it
    /// names, so a coach sees why sign-in failed rather than a generic
    /// message. Returns nil both when the callback carries no error and when
    /// it carries one this does not map (`access_denied`, for instance) — the
    /// caller falls back to a generic message for those, not to success.
    static func error(fromCallback url: URL) -> DriveError? {
        guard let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "error" })?.value
        else {
            return nil
        }
        switch code {
        case "org_internal":
            return .notInOrganisation
        case "admin_policy_enforced":
            return .blockedByAdministrator
        default:
            return nil
        }
    }

    /// `transport` and `tokenStore` default to the real network and the real
    /// Keychain, so a production call site names neither. Both are seams
    /// `GoogleDriveProvider`'s tests use to keep this off the network and out
    /// of the login Keychain: measured directly — a first draft that let this
    /// function reach the real `KeychainTokenStore` from a test took 3 seconds
    /// to fail (`SecItemCopyMatching` against the actual Keychain).
    static func authorize(
        configuration: GoogleOAuthConfiguration,
        presenter: OAuthPresenter,
        transport: HTTPTransport = URLSessionTransport(),
        tokenStore: OAuthTokenStore = KeychainTokenStore()
    ) async throws -> String {
        if let refreshToken = tokenStore.load(account: configuration.clientID) {
            do {
                return try await refreshAccessToken(
                    refreshToken: refreshToken, configuration: configuration, transport: transport
                )
            } catch {
                // A revoked or expired refresh token should not permanently prevent a new sign-in.
                tokenStore.remove(account: configuration.clientID)
            }
        }

        let redirectURI = try await presenter.prepareRedirectURI()
        try requireCompleteRedirectURI(redirectURI)
        let state = try randomURLSafeString(byteCount: 24)
        let verifier = try randomURLSafeString(byteCount: 48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        var components = URLComponents(string: authorizationEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let authorizationURL = components.url else {
            throw DriveError.oauthCallback("Could not build a Google sign-in authorization URL.")
        }

        let callback = try await presenter.authorize(
            authorizationURL: authorizationURL,
            redirectURI: redirectURI
        )
        guard let callbackComponents = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              callbackComponents.queryItems?.first(where: { $0.name == "state" })?.value == state
        else {
            throw DriveError.oauthCallback("Google sign-in response could not be verified.")
        }
        if let mapped = error(fromCallback: callback) {
            throw mapped
        }
        if let errorCode = callbackComponents.queryItems?.first(where: { $0.name == "error" })?.value {
            throw DriveError.oauthCallback("Google sign-in failed: \(errorCode)")
        }
        guard let code = callbackComponents.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw DriveError.oauthCallback("Google did not return an authorization code.")
        }

        let token = try await tokenRequest(
            configuration: configuration,
            values: [
                "code": code,
                "redirect_uri": redirectURI,
                "grant_type": "authorization_code",
                "code_verifier": verifier,
            ],
            transport: transport
        )
        guard let refreshToken = token.refreshToken else {
            throw DriveError.tokenExchange("Google did not return a refresh token. Try connecting again.")
        }
        try tokenStore.save(refreshToken, account: configuration.clientID)
        return token.accessToken
    }

    /// A fresh access token using whatever refresh token is already in the
    /// Keychain, without the interactive dance. Throws if there is none —
    /// callers that can present UI should fall back to `authorize`.
    static func accessToken(
        configuration: GoogleOAuthConfiguration,
        transport: HTTPTransport = URLSessionTransport(),
        tokenStore: OAuthTokenStore = KeychainTokenStore()
    ) async throws -> String {
        guard let refreshToken = tokenStore.load(account: configuration.clientID) else {
            throw DriveError.tokenExchange("No stored Google sign-in to refresh. Sign in again.")
        }
        return try await refreshAccessToken(refreshToken: refreshToken, configuration: configuration, transport: transport)
    }

    private static func refreshAccessToken(
        refreshToken: String,
        configuration: GoogleOAuthConfiguration,
        transport: HTTPTransport
    ) async throws -> String {
        try await tokenRequest(
            configuration: configuration,
            values: [
                "refresh_token": refreshToken,
                "grant_type": "refresh_token",
            ],
            transport: transport
        ).accessToken
    }

    /// The token endpoint's form-urlencoded body. Extracted from the request
    /// itself so it is testable without a network call: an iOS client has no
    /// secret at all, and Google rejects an empty `client_secret` rather than
    /// treating it as absent, so this has to omit the key entirely rather
    /// than interpolate an optional.
    static func tokenRequestBody(values: [String: String], configuration: GoogleOAuthConfiguration) -> String {
        var formValues = values
        formValues["client_id"] = configuration.clientID
        if let clientSecret = configuration.clientSecret {
            formValues["client_secret"] = clientSecret
        }
        return formValues
            .map { "\($0.key.urlFormEncoded)=\($0.value.urlFormEncoded)" }
            .sorted()
            .joined(separator: "&")
    }

    private static func tokenRequest(
        configuration: GoogleOAuthConfiguration,
        values: [String: String],
        transport: HTTPTransport
    ) async throws -> GoogleTokenResponse {
        var request = URLRequest(url: URL(string: tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = tokenRequestBody(values: values, configuration: configuration).data(using: .utf8)
        let (data, response) = try await transport.data(for: request)
        guard (200...299).contains(response.statusCode) else {
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

private struct GoogleTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

/// Where `GoogleOAuth` keeps the refresh token, abstracted so a test can
/// supply an in-memory stand-in instead of the real Keychain. `public`
/// because `GoogleDriveProvider`'s configuration-based initialiser — a
/// different type, constructed from the app target — takes one too, and a
/// public initialiser cannot have a parameter of a non-public type.
public protocol OAuthTokenStore: Sendable {
    func load(account: String) -> String?
    func save(_ token: String, account: String) throws
    func remove(account: String)
}

/// The real Keychain, behind `OAuthTokenStore`. Never constructed by a test —
/// every test that needs a token store injects its own in-memory one instead.
///
/// `public`, like its `init()`: it is `GoogleDriveProvider`'s configuration
/// initialiser's default `tokenStore` value, and a public initialiser's
/// default argument must be built from public symbols — the same reason
/// `OAuthTokenStore` above is public.
public struct KeychainTokenStore: OAuthTokenStore {
    private let service = "ch.ski.video-viewer.google-drive"

    public init() {}

    public func load(account: String) -> String? {
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

    public func save(_ token: String, account: String) throws {
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

    public func remove(account: String) {
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
    /// `.alphanumerics` alone under-allows: it excludes `-._~`, the RFC 3986
    /// unreserved punctuation, so every snake_case key (`client_id`,
    /// `grant_type`, …) and any dotted value came out with `_` and `.`
    /// percent-encoded. Google's parser would still have decoded that
    /// correctly, but it left the wire body needlessly unreadable — and
    /// `GoogleOAuthTests` now asserts the body directly, which caught it.
    var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlFormValueAllowed) ?? self
    }
}

private extension CharacterSet {
    static let urlFormValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
