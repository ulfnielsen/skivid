import AuthenticationServices
import Foundation
import SkiVideoCore
import UIKit

/// Signs in on iPad.
///
/// `ASWebAuthenticationSession` rather than a webview inside the app: Google
/// blocks authorization requests from embedded webviews with
/// `disallowed_useragent`, naming WKWebView explicitly. And a custom scheme
/// rather than the Mac's loopback listener (`AppKitOAuthPresenter`), because
/// loopback redirects have been blocked for iOS OAuth clients since
/// 21 October 2022.
///
/// Not unit-testable end to end, same as `AppKitOAuthPresenter` — `authorize`
/// hands off to the system browser and waits for a human. `IOSRedirectTests`
/// covers what can be covered without one: that `callbackScheme` is a
/// reversed-domain string and that it matches what `iPad-Info.plist`
/// registers.
@MainActor
final class IOSOAuthPresenter: NSObject, OAuthPresenter {
    /// The **built-in** client's redirect: Google issues an iOS client's id
    /// already reversed into exactly this form
    /// (`com.googleusercontent.apps.<client-id>`).
    ///
    /// That client was registered against bundle id `ch.ski.video-viewer.ipad`,
    /// which this app no longer uses — and it keeps working anyway, because the
    /// reverse-DNS redirect is derived from the *client id*, not the bundle id.
    /// Only the `<bundle-id>:/oauth2redirect` form depends on what was
    /// registered, and nothing here uses that form for the built-in client.
    /// A club-supplied client does, which is why `ClubOAuthClientStore` has to
    /// name a bundle id clubs actually register against.
    ///
    /// Must match a `CFBundleURLTypes` entry in `iPad-Info.plist`, or Google's
    /// redirect goes to a scheme the app never receives. Pinned by
    /// `IOSRedirectTests`.
    ///
    /// A club-supplied client does **not** use this — see `schemeForThisFlow`.
    static let callbackScheme = "com.googleusercontent.apps.1075094033080-autj2djudlifsgtr0rd51910531ig1qt"

    private let store: ClubOAuthClientStore

    /// Kept alive for the duration of the flow — `ASWebAuthenticationSession`
    /// does not retain itself, and a session deallocated mid-flight cancels
    /// silently.
    private var session: ASWebAuthenticationSession?

    /// Chosen in `prepareRedirectURI` and reused by `authorize` rather than
    /// recomputed. The redirect URI is a query parameter of the authorization
    /// URL, so a club id saved *between* the two calls would otherwise send
    /// Google one scheme and listen on another — a `redirect_uri_mismatch`
    /// that would read as a Google problem rather than a race here.
    private var schemeInFlight: String?

    init(store: ClubOAuthClientStore = ClubOAuthClientStore()) {
        self.store = store
        super.init()
    }

    /// The built-in client keeps its own reverse-DNS scheme; a club-supplied
    /// client comes back through the one shared scheme every club registers
    /// its client against. Both are in `iPad-Info.plist`.
    private var schemeForThisFlow: String {
        store.clientID == nil ? Self.callbackScheme : ClubOAuthClientStore.redirectScheme
    }

    func prepareRedirectURI() async throws -> String {
        // Matches the `.customScheme` branch of `GoogleOAuth.redirectURI(for:)`
        // (`SkiVideoCore`, internal to that module and so not reachable from
        // here) exactly, the same duplication `AppKitOAuthPresenter` accepts
        // for its loopback URI: this presenter drives `authorize` directly
        // rather than through that function.
        let scheme = schemeForThisFlow
        schemeInFlight = scheme
        return "\(scheme):/oauth2redirect"
    }

    func authorize(authorizationURL: URL, redirectURI: String) async throws -> URL {
        let scheme = schemeInFlight ?? schemeForThisFlow
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: scheme
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
            // Sharing cookies with Safari lets a coach who is already signed
            // into the club's Google account there skip the password prompt
            // here too; nothing about this flow needs session isolation.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            guard session.start() else {
                continuation.resume(throwing: DriveError.oauthCallback("Could not start Google sign-in."))
                return
            }
        }
    }
}

extension IOSOAuthPresenter: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // UIWindowScene has no `keyWindow` property (that lives on
        // UIApplication and has been deprecated since iOS 13) — only
        // `windows`, filtered here by each window's own `isKeyWindow`.
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first(where: \.isKeyWindow) }
            .first ?? ASPresentationAnchor()
    }
}
