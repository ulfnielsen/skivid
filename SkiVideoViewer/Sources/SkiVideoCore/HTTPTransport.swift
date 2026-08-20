import Foundation

/// The one HTTP call the remote library makes, behind a seam.
///
/// Exists so provider tests can assert on the query parameters whose omission
/// fails *silently* against the real API — `supportsAllDrives`, `pageSize`,
/// `corpora` — without reaching the network. Those are precisely the mistakes
/// that surface as an empty library rather than as an error.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Sends `request` with a file's contents as the body.
    ///
    /// Separate from `data(for:)` because the body is a re-encoded clip — tens
    /// of megabytes, and hundreds for a long one. `URLSession.upload(fromFile:)`
    /// streams it from disk; setting `httpBody` would read the whole thing into
    /// memory first, on a device where that is a real cost.
    func upload(_ request: URLRequest, fromFile file: URL) async throws -> (Data, HTTPURLResponse)
}

public extension HTTPTransport {
    /// Reads the file and sends it as an ordinary body.
    ///
    /// The default exists for the test fakes: they record whatever
    /// `URLRequest` they are handed, and a streamed upload would give them a
    /// request whose body they cannot inspect. Their bodies are a few bytes,
    /// so reading them costs nothing — and `URLSessionTransport` overrides
    /// this with the streaming call, which is where the size actually matters.
    func upload(
        _ request: URLRequest, fromFile file: URL
    ) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.httpBody = try Data(contentsOf: file)
        return try await data(for: request)
    }
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

    /// Streams the body from disk rather than reading it into memory — see the
    /// protocol requirement for why that matters here and not elsewhere.
    public func upload(
        _ request: URLRequest, fromFile file: URL
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.upload(for: request, fromFile: file)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteLibraryError.api("The server's reply was not an HTTP response.")
        }
        return (data, http)
    }
}
