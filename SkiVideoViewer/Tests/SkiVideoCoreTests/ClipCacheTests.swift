import XCTest
@testable import SkiVideoCore

/// Writes bytes to the destination without a network, and records what it was
/// asked for — including the headers, which is where the credential lives.
final class FakeClipDownloader: ClipDownloader, @unchecked Sendable {
    var bytesByFileID: [String: Data] = [:]
    var errorToThrow: Error?
    private(set) var requestedFileIDs: [String] = []
    private(set) var lastHeaders: [String: String] = [:]
    /// Blocks each download until `release()` is called, for the coalescing
    /// and cancellation tests.
    var gate: CheckedContinuation<Void, Never>?
    var shouldWait = false

    func download(_ source: DownloadSource, of file: RemoteFile, to destination: URL) async throws {
        requestedFileIDs.append(file.id)
        lastHeaders = source.headers
        if shouldWait {
            await withCheckedContinuation { gate = $0 }
        }
        if let errorToThrow { throw errorToThrow }
        try (bytesByFileID[file.id] ?? Data(repeating: 0, count: Int(file.size)))
            .write(to: destination)
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

final class ClipCacheTests: XCTestCase {
    private var root: URL!
    private var downloader: FakeClipDownloader!
    private var cache: ClipCache!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        downloader = FakeClipDownloader()
        cache = ClipCache(root: root, downloader: downloader, budget: 1_000_000)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ id: String, size: Int64 = 100, md5: String? = nil) -> RemoteFile {
        RemoteFile(id: id, name: "\(id).mp4", path: ["E", "Ada"],
                   size: size, contentVersion: "v1", md5: md5)
    }

    private var source: DownloadSource {
        DownloadSource(url: URL(string: "https://example.invalid/x")!,
                       headers: ["Authorization": "Bearer test"])
    }

    // MARK: - Materialising

    func testAClipIsNotCachedBeforeItIsMaterialised() async {
        let cached = await cache.cachedURL(for: .remote(provider: "gdrive", fileID: "a"))
        XCTAssertNil(cached)
    }

    func testMaterialisingProducesAReadableLocalFile() async throws {
        let url = try await cache.materialize(file("a"), source: source)
        XCTAssertTrue(url.isFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url).count, 100)
    }

    /// The whole point: what AVPlayer opens is an ordinary file, so every
    /// AVAssetReader-based feature works on a cloud clip.
    func testTheCachedURLIsAFileURLWithThePlayableExtension() async throws {
        let url = try await cache.materialize(file("a"), source: source)
        XCTAssertEqual(url.pathExtension, "mp4")
        XCTAssertEqual(url.scheme, "file")
    }

    func testASecondRequestReusesTheCachedFileWithoutDownloadingAgain() async throws {
        _ = try await cache.materialize(file("a"), source: source)
        _ = try await cache.materialize(file("a"), source: source)
        XCTAssertEqual(downloader.requestedFileIDs, ["a"])
    }

    /// A clip whose bytes changed in Drive must be fetched again. The key is
    /// `contentVersion` — `headRevisionId`, which changes only on a content
    /// change, so a rename does not trigger a re-download.
    func testANewContentVersionForcesAFreshDownload() async throws {
        _ = try await cache.materialize(file("a"), source: source)
        let edited = RemoteFile(id: "a", name: "a.mp4", path: ["E", "Ada"],
                                size: 100, contentVersion: "v2", md5: nil)
        _ = try await cache.materialize(edited, source: source)
        XCTAssertEqual(downloader.requestedFileIDs, ["a", "a"])
    }

    func testARenameDoesNotForceAFreshDownload() async throws {
        _ = try await cache.materialize(file("a"), source: source)
        let renamed = RemoteFile(id: "a", name: "a-final.mp4", path: ["E", "Bea"],
                                 size: 100, contentVersion: "v1", md5: nil)
        _ = try await cache.materialize(renamed, source: source)
        XCTAssertEqual(downloader.requestedFileIDs, ["a"])
    }

    /// A file with no content version can never be confirmed current, so it is
    /// re-fetched rather than trusted.
    func testAFileWithNoContentVersionIsNeverReused() async throws {
        let unversioned = RemoteFile(id: "a", name: "a.mp4", path: [],
                                     size: 100, contentVersion: nil, md5: nil)
        _ = try await cache.materialize(unversioned, source: source)
        _ = try await cache.materialize(unversioned, source: source)
        XCTAssertEqual(downloader.requestedFileIDs, ["a", "a"])
    }

    func testTheDownloaderIsGivenTheCredentialHeaders() async throws {
        _ = try await cache.materialize(file("a"), source: source)
        XCTAssertEqual(downloader.lastHeaders["Authorization"], "Bearer test")
    }

    // MARK: - Failure

    func testAFailedDownloadLeavesNothingBehind() async {
        downloader.errorToThrow = RemoteLibraryError.api("network down")
        _ = try? await cache.materialize(file("a"), source: source)

        let cached = await cache.cachedURL(for: .remote(provider: "gdrive", fileID: "a"))
        XCTAssertNil(cached, "a half-written clip must not read as cached")
    }

    /// A truncated download must not be served to AVPlayer as a whole clip.
    func testASizeMismatchIsRejected() async {
        downloader.bytesByFileID["a"] = Data(repeating: 0, count: 50)
        do {
            _ = try await cache.materialize(file("a", size: 100), source: source)
            XCTFail("expected a size mismatch to throw")
        } catch {
            let cached = await cache.cachedURL(for: .remote(provider: "gdrive", fileID: "a"))
            XCTAssertNil(cached)
        }
    }

    // MARK: - Eviction

    /// Eviction order must not depend on the wall clock. Two clips
    /// materialised in the same instant — plausible on a fast machine, and
    /// certain with an in-memory downloader — would share a `Date`, and a sort
    /// on that alone breaks ties arbitrarily. Pinning the order with a frozen
    /// clock is what proves the counter, not the timestamp, decides.
    func testEvictionOrderDoesNotDependOnTheClock() async throws {
        let frozen = Date(timeIntervalSince1970: 1_754_121_660)
        let cache = ClipCache(
            root: root, downloader: downloader, budget: 250, now: { frozen }
        )
        _ = try await cache.materialize(file("a"), source: source)
        _ = try await cache.materialize(file("b"), source: source)
        await cache.recordPlayback(of: .remote(provider: "gdrive", fileID: "a"))
        _ = try await cache.materialize(file("c"), source: source)

        let a = await cache.cachedURL(for: .remote(provider: "gdrive", fileID: "a"))
        let b = await cache.cachedURL(for: .remote(provider: "gdrive", fileID: "b"))
        XCTAssertNotNil(a, "a was played most recently, even with a stopped clock")
        XCTAssertNil(b, "b was the least recently used")
    }

    func testEvictionDropsTheLeastRecentlyPlayedFirst() async throws {
        await cache.setBudget(250)
        _ = try await cache.materialize(file("a"), source: source)
        _ = try await cache.materialize(file("b"), source: source)
        await cache.recordPlayback(of: .remote(provider: "gdrive", fileID: "a"))
        _ = try await cache.materialize(file("c"), source: source)

        let a = await cache.cachedURL(for: .remote(provider: "gdrive", fileID: "a"))
        let b = await cache.cachedURL(for: .remote(provider: "gdrive", fileID: "b"))
        let c = await cache.cachedURL(for: .remote(provider: "gdrive", fileID: "c"))
        XCTAssertNotNil(a, "a was played most recently")
        XCTAssertNil(b, "b was the least recently used")
        XCTAssertNotNil(c)
    }

    func testAPinnedClipSurvivesEviction() async throws {
        await cache.setBudget(250)
        _ = try await cache.materialize(file("a"), source: source)
        try await cache.pin(.remote(provider: "gdrive", fileID: "a"))
        _ = try await cache.materialize(file("b"), source: source)
        _ = try await cache.materialize(file("c"), source: source)

        let a = await cache.cachedURL(for: .remote(provider: "gdrive", fileID: "a"))
        XCTAssertNotNil(a, "a pinned clip is never evicted")
    }

    func testUnpinningLetsAClipBeEvictedAgain() async throws {
        await cache.setBudget(250)
        _ = try await cache.materialize(file("a"), source: source)
        try await cache.pin(.remote(provider: "gdrive", fileID: "a"))
        await cache.unpin(.remote(provider: "gdrive", fileID: "a"))
        _ = try await cache.materialize(file("b"), source: source)
        _ = try await cache.materialize(file("c"), source: source)

        let a = await cache.cachedURL(for: .remote(provider: "gdrive", fileID: "a"))
        XCTAssertNil(a)
    }

    /// Lowering the budget must take effect immediately, not at the next
    /// download — a coach freeing disk space expects the space back.
    func testLoweringTheBudgetEvictsImmediately() async throws {
        _ = try await cache.materialize(file("a"), source: source)
        _ = try await cache.materialize(file("b"), source: source)
        await cache.setBudget(150)

        let total = await cache.bytesOnDisk()
        XCTAssertLessThanOrEqual(total, 150)
    }

    /// A clip larger than the whole budget must still play. Refusing it would
    /// make the largest clips in the library permanently unopenable.
    func testAClipBiggerThanTheBudgetStillMaterialises() async throws {
        await cache.setBudget(50)
        let url = try await cache.materialize(file("a", size: 100), source: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Coalescing

    func testTwoRequestsForOneClipShareASingleDownload() async throws {
        downloader.shouldWait = true
        async let first = cache.materialize(file("a"), source: source)
        async let second = cache.materialize(file("a"), source: source)

        // Let both reach the actor and coalesce before releasing the gate.
        try await Task.sleep(nanoseconds: 50_000_000)
        downloader.release()

        _ = try await (first, second)
        XCTAssertEqual(downloader.requestedFileIDs, ["a"], "one download, not two")
    }
}
