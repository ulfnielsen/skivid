import Foundation
@testable import SkiVideoCore

/// Canned HTTP, so provider tests never reach the network.
///
/// Records every request, which is how the tests assert on query parameters —
/// `supportsAllDrives`, `pageSize` and `corpora` are exactly the parameters
/// whose omission fails *silently* against the real API.
final class FakeHTTPTransport: HTTPTransport, @unchecked Sendable {
    struct Response {
        let status: Int
        let body: Data
        let contentType: String
        /// Thrown instead of answering, so a queued entry can stand for a
        /// request that never completed — no connectivity, a timeout, DNS
        /// gone — as opposed to one the server answered and refused.
        ///
        /// The distinction is not decorative: whether a stored refresh token
        /// survives a failed resume turns on exactly it, and a fake that
        /// could only produce HTTP statuses cannot express "the request did
        /// not complete" at all. Queued in sequence rather than set as a flag
        /// on the whole transport so a test can fail one request and let the
        /// next succeed, which is what the fall-back paths do.
        let failure: Error?

        init(status: Int = 200, json: String, contentType: String = "application/json") {
            self.status = status
            self.body = Data(json.utf8)
            self.contentType = contentType
            self.failure = nil
        }

        init(failure: Error) {
            self.status = 0
            self.body = Data()
            self.contentType = ""
            self.failure = failure
        }
    }

    /// Consumed in order, one per request. Tests set this before issuing any
    /// request, never concurrently with one, so it needs no lock of its own.
    var responses: [Response] = []
    private(set) var requests: [URLRequest] = []
    /// Guards `requests`/`responses` inside `data(for:)` only — the single-
    /// flight refresh test fires two requests concurrently, and without this
    /// two overlapping calls could interleave the append-then-removeFirst
    /// sequence below, corrupting which response each request gets (or
    /// tripping Swift's exclusivity checking outright).
    private let lock = NSLock()

    /// `NSLock.lock`/`.unlock` are flagged when called directly inside an
    /// `async` function, so the pair is wrapped in one synchronous closure
    /// rather than written inline in `data(for:)`, which is `async`.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response: Response? = withLock {
            requests.append(request)
            guard !responses.isEmpty else { return nil }
            return responses.removeFirst()
        }
        guard let response else {
            throw RemoteLibraryError.api("FakeHTTPTransport ran out of responses")
        }
        if let failure = response.failure {
            throw failure
        }
        let http = HTTPURLResponse(
            url: request.url!, statusCode: response.status,
            httpVersion: nil, headerFields: ["Content-Type": response.contentType]
        )!
        return (response.body, http)
    }

    /// The query items of the nth request, for assertions.
    func queryItems(of index: Int) -> [String: String] {
        guard requests.indices.contains(index),
              let url = requests[index].url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return [:] }
        return Dictionary(items.compactMap { item in
            item.value.map { (item.name, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }
}
