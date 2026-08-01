import Foundation
import SkiVideoCore

/// Google Drive is out of scope until phase 6, which replaces the loopback
/// flow with ASWebAuthenticationSession. Throwing here surfaces a normal
/// sign-in failure rather than pretending the flow succeeded.
@MainActor
final class UnavailableOAuthPresenter: OAuthPresenter {
    private struct Unavailable: LocalizedError {
        var errorDescription: String? {
            "Google Drive sign-in is not available on iPad yet."
        }
    }

    func prepareRedirectURI() async throws -> String {
        throw Unavailable()
    }

    func authorize(authorizationURL: URL, redirectURI: String) async throws -> URL {
        throw Unavailable()
    }
}
