import XCTest
@testable import SkiVideoCore

final class ClipPublisherTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("publisher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    /// Fails if the local publisher stops moving the original, which is how a
    /// Mac session archives full-quality footage.
    func testTheLocalPublisherMovesTheOriginalIntoTheEventAthleteLayout() throws {
        let source = try makeFile("C0001.MP4")
        let publisher = LocalFolderPublisher(
            organizedRoot: root.appendingPathComponent("organized"),
            resizedRoot: root.appendingPathComponent("organized_resize")
        )

        let targets = try publisher.prepare(source: source, athlete: "Ada", event: "2026-01-14_Brunni")

        XCTAssertEqual(
            targets.resizeSource.path,
            root.appendingPathComponent("organized/2026-01-14_Brunni/Ada/C0001.MP4").path
        )
        XCTAssertEqual(
            targets.resizeDestination.path,
            root.appendingPathComponent("organized_resize/2026-01-14_Brunni/Ada/C0001.MP4").path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: targets.resizeSource.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: source.path),
            "the original is moved, not copied"
        )
    }

    /// **The reason this plan exists.** Fails if the read-only publisher moves,
    /// copies, or creates anything at the source — which on an SD card would
    /// mean rearranging the only archive of a training session.
    func testTheReadOnlyPublisherLeavesTheSourceUntouched() throws {
        let card = root.appendingPathComponent("DCIM")
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        let source = card.appendingPathComponent("C0001.MP4")
        try Data(repeating: 0, count: 16).write(to: source)
        let before = try FileManager.default.contentsOfDirectory(atPath: card.path)

        let publisher = ReadOnlySourcePublisher(resizedRoot: root.appendingPathComponent("out"))
        let targets = try publisher.prepare(source: source, athlete: "Ada", event: "2026-01-14_Brunni")

        XCTAssertEqual(targets.resizeSource.path, source.path, "the resize reads the card directly")
        XCTAssertEqual(
            targets.resizeDestination.path,
            root.appendingPathComponent("out/2026-01-14_Brunni/Ada/C0001.MP4").path
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: card.path), before,
            "nothing may be added to, removed from, or moved within the source directory"
        )
    }

    /// Fails if the metadata gate is dropped: `SortingModel` writes an athlete
    /// tag into the *original* before resizing, and on a card that is a write.
    func testOnlyTheLocalPublisherPermitsWritingToTheSource() {
        XCTAssertFalse(
            LocalFolderPublisher(
                organizedRoot: root.appendingPathComponent("organized"),
                resizedRoot: root.appendingPathComponent("organized_resize")
            ).maySkipSourceMetadata
        )
        XCTAssertTrue(ReadOnlySourcePublisher(resizedRoot: root).maySkipSourceMetadata)
    }

    /// Today's collision behaviour, preserved. Fails if a second session
    /// silently overwrites the first athlete's clip of the same name.
    func testAnExistingOutputIsRefused() throws {
        let source = try makeFile("C0001.MP4")
        let publisher = LocalFolderPublisher(
            organizedRoot: root.appendingPathComponent("organized"),
            resizedRoot: root.appendingPathComponent("organized_resize")
        )
        _ = try publisher.prepare(source: source, athlete: "Ada", event: "E")

        let second = try makeFile("C0001.MP4")
        XCTAssertThrowsError(try publisher.prepare(source: second, athlete: "Ada", event: "E"))
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 0, count: 16).write(to: url)
        return url
    }
}
