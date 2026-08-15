import Foundation

/// Why a pasted string was refused before it reached Google.
public enum ClubOAuthClientError: LocalizedError, Equatable {
    case notAClientID

    public var errorDescription: String? {
        switch self {
        case .notAClientID:
            return "That does not look like a Google client id. It should end in "
                + "\(ClubOAuthClientStore.clientIDSuffix) — check you copied the "
                + "Client ID and not the client secret or the project number."
        }
    }
}

/// The Google OAuth client a club registered for itself, so the app can serve
/// clubs other than the one it was written for.
///
/// The app's own consent screen has an **Internal** audience, which Google
/// exempts from verification — and Internal means the owning Workspace only,
/// so an account at another club cannot sign in with it at all. Going External
/// instead would trip Google's restricted-scope rules for `drive.readonly`: a
/// verification review, an annual CASA security assessment, and a 100-user cap
/// behind an "unverified app" warning until it passes. Rather than ask Google's
/// permission to serve every club, each club registers its own client in its own
/// project, keeps its own audience Internal, and pastes the id here.
///
/// Stored in `UserDefaults`, not the Keychain, and deliberately: an OAuth client
/// id is not a secret. Every iOS app shipping Google Sign-In carries one in
/// plain text inside its bundle, and Google documents that as expected — the
/// security comes from the redirect-URI restriction plus PKCE. Keychain storage
/// would imply a confidentiality this value does not have, and the Keychain is
/// already the *token* store; mixing a public identifier into it blurs a line
/// worth keeping sharp.
public struct ClubOAuthClientStore {
    /// The redirect scheme every club-supplied client uses — the same string
    /// for all of them, which is the only reason this feature is buildable.
    ///
    /// A custom URL scheme must be registered in `Info.plist` at build time, so
    /// a club pasting its own client id at runtime could never register
    /// `com.googleusercontent.apps.<their-id>`. Verified on 2026-08-15 against
    /// the live authorization endpoint: a Google **iOS** client accepts
    /// `<registered-bundle-id>:/oauth2redirect` as well as the reverse-DNS
    /// form, and rejects an unrelated scheme with `redirect_uri_mismatch`. So
    /// each club registers its client against this one fixed bundle id and the
    /// app ships a single unchanging scheme.
    ///
    /// It is the shipped Mac app's bundle identifier (`AppBundle/Info.plist`),
    /// which is also the string `docs/google-oauth-club-setup.md` tells a club
    /// to type into Google's Bundle ID field.
    public static let redirectScheme = "dk.dyregod.video-viewer"

    /// Every Google OAuth client id ends in this. Checked before storing so the
    /// predictable paste error — the client *secret*, or the bare project
    /// number — is caught where it happened, rather than surfacing three
    /// screens later as a `redirect_uri_mismatch` that reads like an app bug.
    public static let clientIDSuffix = ".apps.googleusercontent.com"

    /// Not namespaced under a reverse-DNS prefix because `UserDefaults.standard`
    /// is already per-application; the other keys this app stores follow the
    /// same convention.
    static let defaultsKey = "ClubGoogleOAuthClientID"

    private let defaults: UserDefaults

    /// Defaults to `.standard` so production call sites name nothing, while a
    /// test supplies its own suite and stays off the developer's real
    /// preferences — the seam pattern `GoogleClientSecretsLoader` already uses
    /// for its environment and directory.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Nil when no club client is configured, which is the signal to fall back
    /// to the built-in one. Re-trimmed on read rather than trusted: a value
    /// written by an older build, or by `defaults write`, has not been through
    /// `save`.
    public var clientID: String? {
        guard let raw = defaults.string(forKey: Self.defaultsKey) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Throws rather than storing anything, so a rejected paste leaves whatever
    /// was configured before intact. A club that mistypes over a working id
    /// should not be signed out by the typo.
    @discardableResult
    public func save(_ raw: String) throws -> String {
        let normalised = try Self.validated(raw)
        defaults.set(normalised, forKey: Self.defaultsKey)
        return normalised
    }

    /// Falls back to the built-in client rather than leaving the app with none.
    public func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    /// Only the suffix is checked. Whether the id exists, whether its audience
    /// is Internal, and whether the signing-in account belongs to that
    /// Workspace are Google's answers to give; guessing at them here would mean
    /// maintaining a second, worse copy of Google's rules.
    public static func validated(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > clientIDSuffix.count, trimmed.hasSuffix(clientIDSuffix) else {
            throw ClubOAuthClientError.notAClientID
        }
        return trimmed
    }

    /// The configuration sign-in should use: the club's client when one is
    /// configured, otherwise whatever the platform supplies as built-in.
    ///
    /// A club-supplied client is always an **iOS**-type client with no secret,
    /// on macOS as well as iPadOS. The alternative — a second, Desktop-type
    /// client so the Mac could keep its loopback listener — would double the
    /// setup and add a secret field, and loopback is blocked for iOS clients
    /// anyway ("The loopback flow has been blocked in order to keep users
    /// secure", measured 2026-08-15), so one client cannot serve both that way.
    public func configuration(
        fallingBackTo builtIn: GoogleOAuthConfiguration?
    ) -> GoogleOAuthConfiguration? {
        guard let clientID else { return builtIn }
        return GoogleOAuthConfiguration(
            clientID: clientID,
            clientSecret: nil,
            redirectKind: .customScheme(Self.redirectScheme)
        )
    }
}
