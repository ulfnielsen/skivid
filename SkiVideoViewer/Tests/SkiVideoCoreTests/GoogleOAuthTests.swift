import XCTest
@testable import SkiVideoCore

final class GoogleOAuthTests: XCTestCase {
    private func configuration(secret: String?) -> GoogleOAuthConfiguration {
        GoogleOAuthConfiguration(
            clientID: "123.apps.googleusercontent.com",
            clientSecret: secret,
            redirectKind: .loopback
        )
    }

    /// An iOS client has no secret at all, so the exchange must be able to
    /// omit it — not send an empty one, which Google rejects.
    ///
    /// Fails if the body is built by unconditionally interpolating the secret:
    /// the assertion is that the key is *absent*, not that it is empty.
    func testATokenRequestOmitsTheSecretEntirelyWhenThereIsNone() throws {
        let body = GoogleOAuth.tokenRequestBody(
            values: ["grant_type": "refresh_token"],
            configuration: configuration(secret: nil)
        )
        XCTAssertFalse(body.contains("client_secret"), "got \(body)")
        XCTAssertTrue(body.contains("client_id="))
    }

    func testATokenRequestIncludesTheSecretWhenThereIsOne() throws {
        let body = GoogleOAuth.tokenRequestBody(
            values: ["grant_type": "refresh_token"],
            configuration: configuration(secret: "shh")
        )
        XCTAssertTrue(body.contains("client_secret=shh"), "got \(body)")
    }

    /// Both of these are policy problems that no amount of retrying fixes, and
    /// a coach reading "sign-in failed" would try again forever. Each gets a
    /// message naming what has to change and who can change it.
    func testAnOrgInternalErrorSaysTheAccountIsWrongNotThatSignInFailed() {
        let message = DriveError.notInOrganisation.errorDescription ?? ""
        XCTAssertTrue(message.lowercased().contains("account"), "got \(message)")
        XCTAssertFalse(message.lowercased().contains("try again"), "got \(message)")
    }

    func testAnAdminPolicyErrorNamesTheAdministrator() {
        let message = DriveError.blockedByAdministrator.errorDescription ?? ""
        XCTAssertTrue(message.lowercased().contains("administrator"), "got \(message)")
    }

    /// The callback carries the reason in a query parameter; mapping it is how
    /// the two cases above ever get constructed.
    func testTheCallbacksErrorParameterMapsToTheSpecificCase() {
        XCTAssertEqual(
            GoogleOAuth.error(fromCallback: URL(string: "x://cb?error=org_internal")!),
            .notInOrganisation
        )
        XCTAssertEqual(
            GoogleOAuth.error(fromCallback: URL(string: "x://cb?error=admin_policy_enforced")!),
            .blockedByAdministrator
        )
        XCTAssertNil(GoogleOAuth.error(fromCallback: URL(string: "x://cb?code=abc")!))
    }

    // MARK: - redirectURI(for:)
    //
    // Needed now so Task 7's iOS presenter has a shared, tested place to build
    // its custom-scheme redirect, rather than each platform reimplementing the
    // format. The loopback case cannot know its real port here — only a
    // running listener does — so it carries a documented placeholder that the
    // presenter substitutes once the listener has one.

    /// A custom-scheme redirect is fully determined by configuration, so it
    /// can be built without a listener.
    ///
    /// Fails if the scheme is dropped, mis-cased, or the callback path is
    /// wrong — asserted on the whole string, not a prefix.
    func testACustomSchemeConfigurationProducesItsReverseDNSRedirectWithACallbackPath() {
        let configuration = GoogleOAuthConfiguration(
            clientID: "123-abc.apps.googleusercontent.com",
            clientSecret: nil,
            redirectKind: .customScheme("com.googleusercontent.apps.123-abc")
        )
        XCTAssertEqual(
            GoogleOAuth.redirectURI(for: configuration),
            "com.googleusercontent.apps.123-abc:/oauth2redirect"
        )
    }

    /// Fails if a loopback configuration is built with a concrete port baked
    /// in, or with the wrong scheme/host — asserted against the exact
    /// documented placeholder string, not merely a prefix.
    func testALoopbackConfigurationCarriesAPortPlaceholderNotAGuessedPort() {
        XCTAssertEqual(
            GoogleOAuth.redirectURI(for: configuration(secret: "shh")),
            "http://127.0.0.1:PORT"
        )
    }
}
