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
    /// Must match the `CFBundleURLTypes` entry `iPad-Info.plist` registers
    /// for the iPad target, or Google's redirect goes to a scheme the app
    /// never receives. Pinned by `IOSRedirectTests`.
    ///
    /// A placeholder: Google issues an iOS OAuth client's id already reversed
    /// into exactly this form (`com.googleusercontent.apps.<client-id>`), and
    /// no such client is registered yet for bundle id
    /// `ch.ski.video-viewer.ipad` — the human partner has a Desktop client
    /// only. Sign-in cannot succeed until one is registered and this string
    /// is replaced with the real reversed client id.
    static let callbackScheme = "com.googleusercontent.apps.REPLACE-WITH-IOS-CLIENT-ID"

    /// Kept alive for the duration of the flow — `ASWebAuthenticationSession`
    /// does not retain itself, and a session deallocated mid-flight cancels
    /// silently.
    private var session: ASWebAuthenticationSession?

    func prepareRedirectURI() async throws -> String {
        // Matches the `.customScheme` branch of `GoogleOAuth.redirectURI(for:)`
        // (`SkiVideoCore`, internal to that module and so not reachable from
        // here) exactly, the same duplication `AppKitOAuthPresenter` accepts
        // for its loopback URI: this presenter drives `authorize` directly
        // rather than through that function.
        "\(Self.callbackScheme):/oauth2redirect"
    }

    func authorize(authorizationURL: URL, redirectURI: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: Self.callbackScheme
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
