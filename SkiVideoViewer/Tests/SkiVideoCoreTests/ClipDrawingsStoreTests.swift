import XCTest
@testable import SkiVideoCore

final class ClipDrawingsStoreTests: XCTestCase {
    private var directory: URL!
    private var savedKeyedRoot: URL!
    private var sample: ClipDrawings!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        savedKeyedRoot = ClipIdentity.keyedStoreRoot
        ClipIdentity.keyedStoreRoot = directory.appendingPathComponent("keyed", isDirectory: true)

        sample = ClipDrawings(drawings: [Drawing(kind: .line, color: .red,
                                        points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)], start: 1)])
    }

    override func tearDownWithError() throws {
        ClipIdentity.keyedStoreRoot = savedKeyedRoot
        try? FileManager.default.removeItem(at: directory)
    }

    private var clip: ClipIdentity { ClipIdentity(directory.appendingPathComponent("C0094.MP4")) }

    func testALocalClipsFileSitsBesideItByStem() {
        XCTAssertEqual(ClipDrawingsStore.fileURL(for: clip).lastPathComponent, "C0094.skidrawings.json")
        XCTAssertEqual(ClipDrawingsStore.fileURL(for: clip).deletingLastPathComponent().standardizedFileURL,
                       directory.standardizedFileURL)
    }

    func testNoFileReadsAsNone() {
        XCTAssertEqual(ClipDrawingsStore.load(for: clip), .none)
    }

    func testRoundTrip() throws {
        try ClipDrawingsStore.save(sample, for: clip)
        XCTAssertEqual(ClipDrawingsStore.load(for: clip), .drawings(sample))
    }

    func testADriveClipGoesToTheKeyedStore() throws {
        let remote = ClipIdentity.remote(provider: "drive", fileID: "abc")
        try ClipDrawingsStore.save(sample, for: remote)
        XCTAssertTrue(ClipDrawingsStore.fileURL(for: remote).path.hasPrefix(ClipIdentity.keyedStoreRoot.path))
        XCTAssertEqual(ClipDrawingsStore.load(for: remote), .drawings(sample))
    }

    func testSavingNothingDeletesTheFile() throws {
        try ClipDrawingsStore.save(sample, for: clip)
        try ClipDrawingsStore.save(ClipDrawings(), for: clip)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ClipDrawingsStore.fileURL(for: clip).path))
        XCTAssertEqual(ClipDrawingsStore.load(for: clip), .none)
    }

    func testAGarbledFileIsUnreadableAndNeverOverwritten() throws {
        let url = ClipDrawingsStore.fileURL(for: clip)
        try Data("{ not json".utf8).write(to: url)
        XCTAssertEqual(ClipDrawingsStore.load(for: clip), .unreadable)
        XCTAssertThrowsError(try ClipDrawingsStore.save(sample, for: clip)) {
            XCTAssertEqual($0 as? ClipDrawingsStoreError, .wouldOverwriteUnreadable)
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("{ not json".utf8))
    }

    /// Review Focus 4: a newer app's file must survive this one.
    func testAFileFromANewerVersionIsUnreadable() throws {
        let url = ClipDrawingsStore.fileURL(for: clip)
        try Data(#"{"version":2,"drawings":[]}"#.utf8).write(to: url)
        XCTAssertEqual(ClipDrawingsStore.load(for: clip), .unreadable)
        XCTAssertThrowsError(try ClipDrawingsStore.save(ClipDrawings(), for: clip))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "deleting is overwriting too")
    }

    /// A file with an impossible span (end before start) should be unreadable,
    /// and save should not overwrite it.
    func testAFileWithAnImpossibleSpanIsUnreadable() throws {
        let url = ClipDrawingsStore.fileURL(for: clip)
        // Create valid JSON structure but with end < start
        let jsonData = try JSONEncoder().encode(ClipDrawings(drawings: [
            Drawing(kind: .line, color: .red, points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)], start: 5, end: 2)
        ]))
        try jsonData.write(to: url)

        XCTAssertEqual(ClipDrawingsStore.load(for: clip), .unreadable)
        XCTAssertThrowsError(try ClipDrawingsStore.save(sample, for: clip)) {
            XCTAssertEqual($0 as? ClipDrawingsStoreError, .wouldOverwriteUnreadable)
        }
        // Verify the file still exists and has the original content
        XCTAssertEqual(try Data(contentsOf: url), jsonData)
    }
}
