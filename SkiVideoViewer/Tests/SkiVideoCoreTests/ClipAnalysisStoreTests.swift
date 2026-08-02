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
}
