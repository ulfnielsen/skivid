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

    /// Sends `request` with bytes `range` of a file as the body.
    ///
    /// For resuming a resumable upload: after a dropped connection the server
    /// reports how much it has, and only the rest should be sent. Same
    /// streaming concern as `upload(_:fromFile:)`.
    func upload(
        _ request: URLRequest, fromFile file: URL, range: Range<Int64>
    ) async throws -> (Data, HTTPURLResponse)
}

public extension HTTPTransport {
    /// Reads just the range and sends it as an ordinary body — the test
    /// fakes' counterpart of the default above.
    func upload(
        _ request: URLRequest, fromFile file: URL, range: Range<Int64>
    ) async throws -> (Data, HTTPURLResponse) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        var request = request
        request.httpBody = try handle.read(upToCount: Int(range.count)) ?? Data()
        return try await data(for: request)
    }

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

    /// `URLSession` can only stream a whole file, so the range is first copied
    /// to a temporary file in small buffers — constant memory, however large
    /// the clip — and that is streamed. A range starting at 0 and covering the
    /// file skips the copy.
    public func upload(
        _ request: URLRequest, fromFile file: URL, range: Range<Int64>
    ) async throws -> (Data, HTTPURLResponse) {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? -1
        if range.lowerBound == 0 && range.upperBound == size {
            return try await upload(request, fromFile: file)
        }
        let slice = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).upload")
        FileManager.default.createFile(atPath: slice.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: slice) }
        let input = try FileHandle(forReadingFrom: file)
        let output = try FileHandle(forWritingTo: slice)
        defer { try? input.close(); try? output.close() }
        try input.seek(toOffset: UInt64(range.lowerBound))
        var remaining = Int(range.count)
        while remaining > 0 {
            guard let chunk = try input.read(upToCount: min(remaining, 1 << 20)), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            remaining -= chunk.count
        }
        return try await upload(request, fromFile: slice)
    }
}
