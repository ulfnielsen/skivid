import Foundation

/// The one HTTP call the remote library makes, behind a seam.
///
/// Exists so provider tests can assert on the query parameters whose omission
/// fails *silently* against the real API — `supportsAllDrives`, `pageSize`,
/// `corpora` — without reaching the network. Those are precisely the mistakes
/// that surface as an empty library rather than as an error.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteLibraryError.api("The server's reply was not an HTTP response.")
        }
        return (data, http)
    }
}
