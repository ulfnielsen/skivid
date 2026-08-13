import XCTest
@testable import SkiVideoCore

final class ClipAnalysisStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func clip(_ name: String = "C0094.MP4") -> URL {
        directory.appendingPathComponent(name)
    }

    private var sample: ClipAnalysis {
        ClipAnalysis(
            version: 1,
            analysedAt: Date(timeIntervalSince1970: 1_754_121_660),
            parameters: AnalysisParameters(
                fps: 25, detectionWidth: 320, initialJump: 0.06, speedMultiplier: 4.0,
                maxHeightRatio: 1.15, maxMisses: 10, cutOnAmbiguity: true, minSamples: 8
            ),
            segments: [],
            subject: nil
        )
    }

    func testSidecarSitsBesideTheClipAndKeepsItsStem() {
        XCTAssertEqual(
            ClipAnalysisStore.sidecarURL(for: clip()).lastPathComponent,
            "C0094.skianalysis.json"
        )
        XCTAssertEqual(
            ClipAnalysisStore.sidecarURL(for: clip()).deletingLastPathComponent().path,
            directory.path
        )
    }

    func testLoadReturnsNilWhenThereIsNoSidecar() {
        XCTAssertNil(ClipAnalysisStore.load(for: clip()))
    }

    func testSaveThenLoadRoundTrips() throws {
        try ClipAnalysisStore.save(sample, for: clip())
        XCTAssertEqual(ClipAnalysisStore.load(for: clip())?.parameters.fps, 25)
    }

    func testLoadReturnsNilForAnUnparseableSidecarAndLeavesItAlone() throws {
        let url = ClipAnalysisStore.sidecarURL(for: clip())
        try Data("{ not json".utf8).write(to: url)

        XCTAssertNil(ClipAnalysisStore.load(for: clip()))
        // Never silently replace a file we could not read: it may be a newer
        // version, or hand-edited, and overwriting it would destroy work.
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{ not json")
    }

    func testSaveThrowsRatherThanFailingSilentlyWhenTheFolderIsUnwritable() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: directory.path
            )
        }

        XCTAssertThrowsError(try ClipAnalysisStore.save(sample, for: clip()))
    }

    // MARK: - Identity-keyed storage

    /// Points the keyed store at a temporary directory for one test and puts
    /// it back afterwards, so a test run never writes into real Application
    /// Support and two tests cannot see each other's sidecars.
    private func withTemporaryKeyedStore(_ body: (URL) throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let previous = ClipIdentity.keyedStoreRoot
        ClipIdentity.keyedStoreRoot = root
        defer {
            ClipIdentity.keyedStoreRoot = previous
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }

    // `withTemporaryKeyedStore` is `rethrows`, so a test whose closure calls
    // nothing throwing must omit both `try` and `throws` — otherwise the
    // compiler warns "no calls to throwing functions occur within 'try'".
    func testRemoteSidecarLivesInTheKeyedStoreUnderItsKey() {
        withTemporaryKeyedStore { root in
            let identity = ClipIdentity.remote(provider: "gdrive", fileID: "1AbC")
            let url = ClipAnalysisStore.sidecarURL(for: identity)
            XCTAssertEqual(url.deletingLastPathComponent().path, root.path)
            XCTAssertEqual(url.lastPathComponent, "gdrive-1AbC.skianalysis.json")
        }
    }

    func testRemoteAnalysisRoundTrips() throws {
        try withTemporaryKeyedStore { _ in
            let identity = ClipIdentity.remote(provider: "gdrive", fileID: "1AbC")
            try ClipAnalysisStore.save(sample, for: identity)
            XCTAssertEqual(ClipAnalysisStore.load(for: identity)?.parameters.fps, 25)
        }
    }

    /// The store directory does not exist on a fresh install. Saving has to
    /// create it rather than throw, or the first analysis a coach ever runs on
    /// a cloud clip is lost.
    func testSavingRemoteAnalysisCreatesTheStoreDirectory() throws {
        try withTemporaryKeyedStore { root in
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
            try ClipAnalysisStore.save(
                sample, for: .remote(provider: "gdrive", fileID: "1AbC")
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        }
    }

    // `withTemporaryKeyedStore` is `rethrows`, so a test whose closure calls
    // nothing throwing must omit both `try` and `throws` — otherwise the
    // compiler warns "no calls to throwing functions occur within 'try'".
    func testMissingRemoteAnalysisReadsAsAbsent() {
        withTemporaryKeyedStore { _ in
            XCTAssertNil(
                ClipAnalysisStore.load(for: .remote(provider: "gdrive", fileID: "nope"))
            )
        }
    }

    /// Two providers that happen to issue the same file id must not share a
    /// sidecar.
    func testRemoteAnalysisIsScopedToItsProvider() throws {
        try withTemporaryKeyedStore { _ in
            try ClipAnalysisStore.save(
                sample, for: .remote(provider: "gdrive", fileID: "shared")
            )
            XCTAssertNil(
                ClipAnalysisStore.load(for: .remote(provider: "dropbox", fileID: "shared"))
            )
        }
    }

    /// The URL-taking API is the identity-taking one with `.local` supplied —
    /// not a second implementation that could drift from it.
    ///
    /// This cannot fail today: `sidecarURL(for: URL)` is defined as
    /// `sidecarURL(for: ClipIdentity(clip))`, so the two sides are the same
    /// call. It only guards against a future rewrite of the URL overload into
    /// a parallel code path that quietly stops agreeing with the identity one.
    func testLocalIdentityResolvesToTheSameSidecarAsTheURLAPI() {
        XCTAssertEqual(
            ClipAnalysisStore.sidecarURL(for: ClipIdentity(clip())),
            ClipAnalysisStore.sidecarURL(for: clip())
        )
    }
}
