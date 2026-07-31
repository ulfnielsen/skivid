import AppKit
import Foundation
import Network
import SkiVideoCore

/// macOS runs the OAuth redirect through a short-lived loopback HTTP server and
/// the system browser. iOS will use `ASWebAuthenticationSession` instead.
///
/// Two-phase by necessity: the loopback port is assigned by the OS when the
/// server starts, and the redirect URI built from it is a query parameter of the
/// authorization URL, so it has to be known before that URL exists.
///
/// Not unit-testable end to end — `authorize` hands off to the system browser
/// and waits for a human — but `prepareRedirectURI()` starts a real listener and
/// is covered by `AppKitOAuthPresenterTests`.
@MainActor
final class AppKitOAuthPresenter: OAuthPresenter {
    private var server: OAuthCallbackServer?

    func prepareRedirectURI() async throws -> String {
        let server = try OAuthCallbackServer()
        self.server = server
        let port = try await server.start()
        return "http://127.0.0.1:\(port)"
    }

    func authorize(authorizationURL: URL, redirectURI: String) async throws -> URL {
        guard let server else {
            throw DriveError.oauthCallback("Redirect URI was not prepared.")
        }
        NSWorkspace.shared.open(authorizationURL)
        return try await server.waitForCallback()
    }
}

// Moved verbatim from GoogleDriveSupport.swift so the Drive client no longer
// depends on Network or AppKit.
private final class OAuthCallbackServer {
    private let listener: NWListener
    private var port: UInt16?
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var startResult: Result<UInt16, Error>?
    private var callbackResult: Result<URL, Error>?

    init() throws {
        // Let macOS choose an unused loopback port. This avoids a prior app launch or
        // another process on a fixed port leaving OAuth waiting forever.
        listener = try NWListener(using: .tcp)
    }

    func start() async throws -> UInt16 {
        if let startResult {
            return try startResult.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            beginListening()
        }
    }

    private func beginListening() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = self.listener.port?.rawValue else {
                    self.completeStart(.failure(DriveError.oauthCallback("Google sign-in callback did not receive a local port.")))
                    return
                }
                self.port = port
                self.completeStart(.success(port))
            case let .failed(error):
                let callbackError = DriveError.oauthCallback(
                    "Could not start the local Google sign-in callback: \(error.localizedDescription)"
                )
                self.completeStart(.failure(callbackError))
                self.completeCallback(.failure(callbackError))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.receiveCallback(on: connection)
        }
        listener.start(queue: .main)
    }

    func waitForCallback() async throws -> URL {
        if let callbackResult {
            return try callbackResult.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            callbackContinuation = continuation
        }
    }

    private func receiveCallback(on connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            defer { connection.cancel() }
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let requestLine = request.split(separator: "\n").first,
                  let target = requestLine.split(separator: " ").dropFirst().first,
                  let port = self.port,
                  let callback = URL(string: "http://127.0.0.1:\(port)\(target)")
            else {
                return
            }
            let html = "<html><body style='font-family:-apple-system;padding:2rem'><h2>Google Drive connected</h2><p>You can close this tab and return to Ski Video Viewer.</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in })
            self.completeCallback(.success(callback))
        }
    }

    private func completeStart(_ result: Result<UInt16, Error>) {
        guard startResult == nil else { return }
        startResult = result
        startContinuation?.resume(with: result)
        startContinuation = nil
    }

    private func completeCallback(_ result: Result<URL, Error>) {
        guard callbackResult == nil else { return }
        callbackResult = result
        listener.cancel()
        callbackContinuation?.resume(with: result)
        callbackContinuation = nil
    }
}
