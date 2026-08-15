import AppKit
import AuthenticationServices
import Foundation
import SkiVideoCore

/// Picks how the Mac receives Google's redirect, because the two kinds of
/// client it can sign in with cannot receive it the same way.
///
/// The **built-in** client is a Desktop client, and Desktop clients may still
/// use a loopback redirect — that is `AppKitOAuthPresenter`, unchanged.
/// A **club-supplied** client is an iOS client, and loopback is blocked for
/// those: measured against the live endpoint on 2026-08-15, an iOS client
/// asking for `http://127.0.0.1:51234` is refused with *"The loopback flow has
/// been blocked in order to keep users secure."* So a club client comes back
/// through the custom scheme `ClubOAuthClientStore.redirectScheme` instead,
/// which `AppBundle/Info.plist` registers.
///
/// Asking each club to register a *second*, Desktop-type client just for the
/// Mac would avoid this class, at the cost of doubling the setup and adding a
/// client-secret field to the sheet. One client per club is worth one branch
/// here.
///
/// Not unit-testable end to end — both branches hand off to a browser and wait
/// for a human — which is the same limit `AppKitOAuthPresenter` and
/// `IOSOAuthPresenter` document. What is testable lives in
/// `ClubOAuthClientTests`: which configuration a given stored id produces, and
/// that the scheme this presenter names is one the app registers.
@MainActor
final class MacOAuthPresenter: NSObject, OAuthPresenter {
    private let store: ClubOAuthClientStore
    private let loopback = AppKitOAuthPresenter()

    /// Kept alive for the duration of the flow — `ASWebAuthenticationSession`
    /// does not retain itself, and a session deallocated mid-flight cancels
    /// silently. The same reason `IOSOAuthPresenter` holds its session.
    private var session: ASWebAuthenticationSession?

    /// Decided in `prepareRedirectURI` and reused by `authorize`, rather than
    /// read from the store twice. The redirect URI is a query parameter of the
    /// authorization URL, so a club id saved *between* the two calls would
    /// otherwise send Google one redirect and listen for another — a
    /// `redirect_uri_mismatch` that would look like a Google problem.
    private var routeInFlight: Route?

    private enum Route {
        case loopback
        case clubCustomScheme
    }

    init(store: ClubOAuthClientStore = ClubOAuthClientStore()) {
        self.store = store
        super.init()
    }

    func prepareRedirectURI() async throws -> String {
        let route: Route = store.clientID == nil ? .loopback : .clubCustomScheme
        routeInFlight = route
        switch route {
        case .loopback:
            return try await loopback.prepareRedirectURI()
        case .clubCustomScheme:
            // Matches the `.customScheme` branch of `GoogleOAuth.redirectURI(for:)`,
            // which is internal to SkiVideoCore and so unreachable from here —
            // the same duplication `IOSOAuthPresenter` accepts, for the same
            // reason: this presenter drives `authorize` directly.
            return "\(ClubOAuthClientStore.redirectScheme):/oauth2redirect"
        }
    }

    func authorize(authorizationURL: URL, redirectURI: String) async throws -> URL {
        switch routeInFlight {
        case .loopback:
            return try await loopback.authorize(
                authorizationURL: authorizationURL,
                redirectURI: redirectURI
            )
        case .clubCustomScheme:
            return try await authorizeThroughCustomScheme(authorizationURL)
        case nil:
            throw DriveError.oauthCallback("Redirect URI was not prepared.")
        }
    }

    private func authorizeThroughCustomScheme(_ authorizationURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: ClubOAuthClientStore.redirectScheme
            ) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                    return
                }
                if let error = error as? ASWebAuthenticationSessionError,
                   error.code == .canceledLogin {
                    continuation.resume(throwing: DriveError.oauthCallback("Google sign-in was cancelled."))
                    return
                }
                continuation.resume(throwing: DriveError.oauthCallback(
                    error?.localizedDescription ?? "Google sign-in did not return a callback URL."
                ))
            }
            session.presentationContextProvider = self
            // Shares cookies with Safari so a coach already signed into the
            // club's Google account there is not asked for a password again.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            guard session.start() else {
                continuation.resume(throwing: DriveError.oauthCallback("Could not start Google sign-in."))
                return
            }
        }
    }
}

extension MacOAuthPresenter: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // `keyWindow` can be nil while a sheet is up, which is exactly when
        // this runs — the drive sheet is on screen. Falling back to any window
        // keeps the browser anchored to the app rather than nowhere.
        NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first
            ?? ASPresentationAnchor()
    }
}
