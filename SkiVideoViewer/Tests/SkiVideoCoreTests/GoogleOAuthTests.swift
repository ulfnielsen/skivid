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
    // running listener does — so it carries a documented placeholder that a
    // presenter driving the flow through this function is expected to
    // substitute once its listener has a port. No presenter does that yet:
    // `AppKitOAuthPresenter` builds its own loopback URI directly, and this
    // function is not yet on the live path (Task 3).

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

    /// Nothing currently produces a redirect URI carrying the placeholder —
    /// `authorize` takes its redirect from the presenter, not from
    /// `redirectURI(for:)` — but a future presenter (Task 3) that forgot the
    /// substitution would hand `authorize` exactly this string, and Google
    /// would answer with an opaque "redirect_uri_mismatch" rather than naming
    /// the real bug. `authorize` calls `requireCompleteRedirectURI` on
    /// whatever the presenter returns, before it is ever sent to Google.
    ///
    /// Calls the guard directly rather than through `authorize`, which starts
    /// with a Keychain lookup — tests here may not touch the real Keychain.
    ///
    /// Fails without the guard: the call would return normally instead of
    /// throwing, so `XCTAssertThrowsError` would have no error to inspect.
    func testARedirectURIStillCarryingThePortPlaceholderIsRefused() {
        XCTAssertThrowsError(
            try GoogleOAuth.requireCompleteRedirectURI("http://127.0.0.1:PORT")
        ) { error in
            guard let driveError = error as? DriveError, case let .oauthCallback(message) = driveError else {
                return XCTFail("expected .oauthCallback naming the missing port, got \(error)")
            }
            XCTAssertTrue(message.lowercased().contains("port"), "got \(message)")
        }
    }

    /// A real, substituted redirect URI must pass through untouched — pins
    /// that the guard checks for the placeholder specifically, not anything
    /// that merely looks like a loopback address.
    func testACompletedRedirectURIIsNotRefused() {
        XCTAssertNoThrow(try GoogleOAuth.requireCompleteRedirectURI("http://127.0.0.1:54321"))
    }

    // MARK: - What each sign-in asks Google for

    /// Drives the interactive branch far enough to capture the authorization
    /// URL and no further: the token store is empty, so `authorize` cannot
    /// refresh, and the presenter returns a callback carrying no code, so the
    /// exchange throws. `lastAuthorizationURL` is recorded before any of that,
    /// which is why the throw is discarded rather than asserted on — the URL
    /// is the whole subject here.
    @MainActor
    private func scopeRequested(byAuthorizing authorize: (FakeOAuthPresenter) async throws -> Void)
        async throws -> String
    {
        let presenter = FakeOAuthPresenter()
        presenter.callbackToReturn = URL(string: "http://127.0.0.1:49152/callback")!
        try? await authorize(presenter)
        let url = try XCTUnwrap(presenter.lastAuthorizationURL)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return try XCTUnwrap(components.queryItems?.first { $0.name == "scope" }?.value)
    }

    /// Watching costs nothing extra. A coach who never repairs a clip must
    /// never see a consent screen asking for write access to their Drive —
    /// the difference between "see and download your files" and "see, edit,
    /// create and delete all of your files" on the Google consent screen.
    @MainActor
    func testTheOrdinarySignInAsksOnlyForReadAccess() async throws {
        let scope = try await scopeRequested { presenter in
            _ = try await GoogleOAuth.authorize(
                configuration: configuration(secret: "s"),
                presenter: presenter,
                transport: FakeHTTPTransport(),
                tokenStore: InMemoryOAuthTokenStore()
            )
        }

        XCTAssertEqual(scope, "https://www.googleapis.com/auth/drive.readonly")
        XCTAssertFalse(
            scope.contains("auth/drive "), "the read-only sign-in must not request write access"
        )
    }

    /// The upgrade asks for both, not just the new one: Google returns a token
    /// carrying exactly the scopes requested, so omitting the read scope here
    /// would trade the app's ability to read the library for its ability to
    /// write one file.
    @MainActor
    func testTheWriteUpgradeAsksForReadAndWriteTogether() async throws {
        let scope = try await scopeRequested { presenter in
            _ = try await GoogleOAuth.authorize(
                configuration: configuration(secret: "s"),
                presenter: presenter,
                transport: FakeHTTPTransport(),
                tokenStore: InMemoryOAuthTokenStore(),
                scope: .readAndWrite
            )
        }

        XCTAssertTrue(scope.contains("https://www.googleapis.com/auth/drive.readonly"), scope)
        XCTAssertTrue(
            scope.split(separator: " ").contains("https://www.googleapis.com/auth/drive"), scope
        )
    }

    /// What makes the upgrade *incremental*: without it Google mints a token
    /// carrying only the scopes named in this request, and any scope the coach
    /// granted in an earlier consent is silently dropped.
    @MainActor
    func testTheWriteUpgradeAsksGoogleToKeepAlreadyGrantedScopes() async throws {
        let presenter = FakeOAuthPresenter()
        presenter.callbackToReturn = URL(string: "http://127.0.0.1:49152/callback")!
        _ = try? await GoogleOAuth.authorize(
            configuration: configuration(secret: "s"),
            presenter: presenter,
            transport: FakeHTTPTransport(),
            tokenStore: InMemoryOAuthTokenStore(),
            scope: .readAndWrite
        )

        let url = try XCTUnwrap(presenter.lastAuthorizationURL)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(
            components.queryItems?.first { $0.name == "include_granted_scopes" }?.value, "true"
        )
    }
}
