import XCTest
@testable import SkiVideoCore

/// Writes bytes to the destination without a network, and records what it was
/// asked for — including the headers, which is where the credential lives.
final class FakeClipDownloader: ClipDownloader, @unchecked Sendable {
    var bytesByFileID: [String: Data] = [:]
    var errorToThrow: Error?
    /// Limits how many times `errorToThrow` is thrown for a given file id,
    /// keyed by that id — so a retry test for one file is not disturbed by
    /// unrelated downloads (a neighbour's prefetch, a coalesced in-flight
    /// request) that happen to reach `download` first. A file id with no
    /// entry here throws on every call, which is what every pre-existing use
    /// of `errorToThrow` needs.
    var errorThrowLimitByFileID: [String: Int] = [:]
    private var errorThrowCountByFileID: [String: Int] = [:]
    private(set) var requestedFileIDs: [String] = []
    private(set) var lastHeaders: [String: String] = [:]
    /// Blocks each download until it is released, for the coalescing and
    /// cancellation tests. Keyed by file id — rather than one bare
    /// continuation — so two different clips can be held open
    /// independently, which is what a test of overlapping fetches needs.
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    /// File ids `release(_:)` was asked to open before `download` had
    /// reached the gate for them — a caller that fires a `Task` and then
    /// releases it in the same synchronous stretch cannot know whether the
    /// `Task` has reached `download` yet, since `ViewerModel`'s fetches are
    /// MainActor-isolated and get no time at all until the caller itself
    /// suspends (a `changeVideo` call followed immediately by `release`,
    /// with no `await` between them, is exactly this). Measured: without
    /// this, such a `release` is silently a no-op, and the gate it should
    /// have opened blocks forever once `download` finally runs. A real gate
    /// or semaphore has this property for the same reason — `signal` before
    /// `wait` still counts — so this fake matches it instead of requiring
    /// every caller to insert an artificial yield.
    private var preReleased: Set<String> = []
    var shouldWait = false
    /// Resumed the moment `download` sets a file's gate — i.e. the moment
    /// it is genuinely blocked, not merely "the `Task` that would fetch it
    /// exists". A caller that fires a fetch through an unstructured `Task`
    /// (every `ViewerModel` selection-change fetch does) has no guarantee
    /// that `Task` has run even one line by the time its own next statement
    /// executes — `ViewerModel`'s fetches are MainActor-isolated and get no
    /// time until the caller itself suspends. `waitUntilGated` is what lets
    /// a test construct a *real* race (one selection's fetch genuinely
    /// in flight when the next selection lands) instead of an accidental
    /// one where both `Task`s run only after every synchronous statement in
    /// the test has already executed. Not signalled on the pre-armed path
    /// (`preReleased`) — no test needs that combination today.
    private var arrivalContinuations: [String: CheckedContinuation<Void, Never>] = [:]

    func download(_ source: DownloadSource, of file: RemoteFile, to destination: URL) async throws {
        requestedFileIDs.append(file.id)
        lastHeaders = source.headers
        if shouldWait, preReleased.remove(file.id) == nil {
            await withCheckedContinuation { continuation in
                gates[file.id] = continuation
                arrivalContinuations.removeValue(forKey: file.id)?.resume()
            }
        }
        if let errorToThrow {
            if let limit = errorThrowLimitByFileID[file.id] {
                let count = errorThrowCountByFileID[file.id, default: 0]
                if count < limit {
                    errorThrowCountByFileID[file.id] = count + 1
                    throw errorToThrow
                }
            } else {
                throw errorToThrow
            }
        }
        try (bytesByFileID[file.id] ?? Data(repeating: 0, count: Int(file.size)))
            .write(to: destination)
    }

    /// Releases every currently held download. Pre-arming is per-file (see
    /// `preReleased`), so this only affects downloads already gated.
    func release() {
        let held = gates.values
        gates.removeAll()
        held.forEach { $0.resume() }
    }

    /// Releases only the named download, leaving any others held. If
    /// `download` has not reached the gate for this file id yet, this
    /// records the release so the gate opens immediately once it does — see
    /// `preReleased`.
    func release(_ fileID: String) {
        guard let continuation = gates.removeValue(forKey: fileID) else {
            preReleased.insert(fileID)
            return
        }
        continuation.resume()
    }

    /// Suspends until `download` has been called for `fileID` and is
    /// genuinely blocked on its gate. See `arrivalContinuations` for why
    /// this exists instead of a `Task.sleep`: it is the difference between
    /// "the fetch has actually started and is in flight" and "some `Task`
    /// that may or may not have run yet exists".
    func waitUntilGated(_ fileID: String) async {
        if gates[fileID] != nil { return }
        await withCheckedContinuation { arrivalContinuations[fileID] = $0 }
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

    /// Reproduced against the unfixed cache: after a failed refresh to a new
    /// `contentVersion`, the original file was still on disk, but the catch
    /// block had already removed its manifest entry — `cachedURL` returned
    /// nil and `bytesOnDisk()` returned 0, so a coach offline lost a clip
    /// that worked seconds ago, and its megabytes became invisible to the
    /// budget and unevictable forever.
    func testAFailedRefreshLeavesThePriorVersionCachedAndPlayable() async throws {
        _ = try await cache.materialize(file("a"), source: source)

        downloader.errorToThrow = RemoteLibraryError.api("network down")
        let updated = RemoteFile(id: "a", name: "a.mp4", path: ["E", "Ada"],
                                 size: 100, contentVersion: "v2", md5: nil)
        _ = try? await cache.materialize(updated, source: source)

        let cached = await cache.cachedURL(for: .remote(provider: "gdrive", fileID: "a"))
        XCTAssertNotNil(cached, "the previous, still-playable copy must remain cached")
        let total = await cache.bytesOnDisk()
        XCTAssertEqual(total, 100, "the surviving clip's bytes must still be counted toward the budget")
    }

    /// Same family as C3: a Drive rename that changes the extension
    /// (`.mp4` → `.mov`) points the entry at a *different* `fileURL`, so the
    /// plain overwrite in `fetch` never touches the old file. Without the
    /// explicit cleanup it survives on disk, untracked and counted nowhere.
    func testARenameThatChangesTheExtensionRemovesTheOldFile() async throws {
        let url = try await cache.materialize(file("a"), source: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "precondition")

        let renamed = RemoteFile(id: "a", name: "a.mov", path: ["E", "Ada"],
                                 size: 100, contentVersion: "v2", md5: nil)
        let newURL = try await cache.materialize(renamed, source: source)

        XCTAssertNotEqual(url, newURL, "precondition: the extension change moved the file")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "the old .mp4 file must not be left orphaned on disk"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
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
        await cache.pin(.remote(provider: "gdrive", fileID: "a"))
        _ = try await cache.materialize(file("b"), source: source)
        _ = try await cache.materialize(file("c"), source: source)

        let a = await cache.cachedURL(for: .remote(provider: "gdrive", fileID: "a"))
        XCTAssertNotNil(a, "a pinned clip is never evicted")
    }

    func testUnpinningLetsAClipBeEvictedAgain() async throws {
        await cache.setBudget(250)
        _ = try await cache.materialize(file("a"), source: source)
        await cache.pin(.remote(provider: "gdrive", fileID: "a"))
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

    /// Reproduced against the unfixed cache: with `a` pinned and filling the
    /// budget, materialising `b` had `evictToFit` delete `b` itself right
    /// after writing it — the only unpinned entry `evictToFit` could see. The
    /// caller got back a path to nothing, and every retry would re-download
    /// and re-evict it forever.
    func testMaterializingDoesNotEvictTheClipItJustReturned() async throws {
        await cache.setBudget(150)
        _ = try await cache.materialize(file("a", size: 100), source: source)
        await cache.pin(.remote(provider: "gdrive", fileID: "a"))

        let url = try await cache.materialize(file("b", size: 100), source: source)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                       "the clip just materialised must exist on disk")
        let cachedB = await cache.cachedURL(for: .remote(provider: "gdrive", fileID: "b"))
        XCTAssertNotNil(cachedB, "cachedURL must find the clip fetch just returned")
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
