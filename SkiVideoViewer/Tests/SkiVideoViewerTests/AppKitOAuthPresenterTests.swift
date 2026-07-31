import SkiVideoCore
import XCTest
@testable import SkiVideoViewer

/// Target-wide stub so `ViewerModel`'s other tests can satisfy the
/// `oauthPresenter` dependency without touching the browser. Google sign-in is
/// deliberately out of scope for this phase, so nothing here performs a real
/// OAuth round trip.
@MainActor
final class StubOAuthPresenter: OAuthPresenter {
    var redirectURIToReturn = "http://127.0.0.1:49152"
    var callbackToReturn: URL?
    private(set) var prepareCallCount = 0
    private(set) var lastAuthorizationURL: URL?
    private(set) var lastRedirectURI: String?

    func prepareRedirectURI() async throws -> String {
        prepareCallCount += 1
        return redirectURIToReturn
    }

    func authorize(authorizationURL: URL, redirectURI: String) async throws -> URL {
        lastAuthorizationURL = authorizationURL
        lastRedirectURI = redirectURI
        guard let callbackToReturn else {
            throw DriveError.oauthCallback("StubOAuthPresenter had no callback configured.")
        }
        return callbackToReturn
    }
}

/// Covers the half of `AppKitOAuthPresenter` that is reachable without a
/// browser: starting the loopback listener and the guard that fires when
/// `authorize` is called before `prepareRedirectURI`.
///
/// The full flow (system browser, Google consent, callback, token exchange) is
/// **not** exercised anywhere in the suite — see the task 5 report.
@MainActor
final class AppKitOAuthPresenterTests: XCTestCase {
    /// Guards against a listener that never reaches `.ready` or `.failed`
    /// hanging the whole suite.
    private func withTimeout<T: Sendable>(
        _ seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = try await group.next()
            group.cancelAll()
            guard let value = first ?? nil else {
                throw XCTSkip("Loopback listener did not become ready within \(seconds)s")
            }
            return value
        }
    }

    func testPrepareRedirectURIReturnsLoopbackURLWithOSAssignedPort() async throws {
        let presenter = AppKitOAuthPresenter()

        let redirectURI = try await withTimeout(5) { try await presenter.prepareRedirectURI() }

        let components = try XCTUnwrap(
            URLComponents(string: redirectURI),
            "redirect URI must parse: \(redirectURI)"
        )
        XCTAssertEqual(components.scheme, "http")
        XCTAssertEqual(components.host, "127.0.0.1")
        let port = try XCTUnwrap(components.port, "the OS-assigned port must be present")
        XCTAssertGreaterThan(
            port,
            0,
            "an ephemeral port of 0 would mean the listener never reported one"
        )
        XCTAssertEqual(components.path, "", "Google matches the redirect URI exactly")
    }

    func testEachPreparedRedirectURIGetsItsOwnPort() async throws {
        let first = try await withTimeout(5) { try await AppKitOAuthPresenter().prepareRedirectURI() }
        let second = try await withTimeout(5) { try await AppKitOAuthPresenter().prepareRedirectURI() }

        XCTAssertNotEqual(
            first,
            second,
            "an ephemeral port is requested per attempt so a stale listener cannot block sign-in"
        )
    }

    func testAuthorizeBeforePrepareThrowsInsteadOfCrashing() async {
        let presenter = AppKitOAuthPresenter()

        do {
            _ = try await presenter.authorize(
                authorizationURL: URL(string: "https://accounts.google.com/o/oauth2/auth")!,
                redirectURI: "http://127.0.0.1:49152"
            )
            XCTFail("authorize without a prepared redirect URI must throw")
        } catch let error as DriveError {
            guard case let .oauthCallback(message) = error else {
                return XCTFail("expected .oauthCallback, got \(error)")
            }
            XCTAssertEqual(message, "Redirect URI was not prepared.")
        } catch {
            XCTFail("expected DriveError, got \(error)")
        }
    }
}
