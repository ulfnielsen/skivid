import Foundation
import XCTest
@testable import SkiVideoCore

final class VideoLibraryTests: XCTestCase {
    func testGroupsNestedVideosByAthleteFolder() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let alice = root.appendingPathComponent("2026-07-16_Neuss/Alice")
        let bob = root.appendingPathComponent("2026-07-16_Neuss/Bob")
        try FileManager.default.createDirectory(at: alice, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bob, withIntermediateDirectories: true)
        try Data().write(to: alice.appendingPathComponent("C0002.MP4"))
        try Data().write(to: alice.appendingPathComponent("C0001.mov"))
        try Data().write(to: alice.appendingPathComponent("notes.txt"))
        try Data().write(to: bob.appendingPathComponent("C0003.m4v"))

        let athletes = try VideoLibrary.scan(root)

        XCTAssertEqual(athletes.map(\.name), ["Alice", "Bob"])
        XCTAssertEqual(
            athletes[0].videos.map(\.lastPathComponent),
            ["C0001.mov", "C0002.MP4"]
        )
        XCTAssertEqual(athletes[1].videos.map(\.lastPathComponent), ["C0003.m4v"])
    }

    func testMergesSameAthleteAcrossEventsCaseInsensitively() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("event-one/Alice")
        let second = root.appendingPathComponent("event-two/alice")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data().write(to: first.appendingPathComponent("first.mp4"))
        try Data().write(to: second.appendingPathComponent("second.mp4"))

        let athletes = try VideoLibrary.scan(root)

        XCTAssertEqual(athletes.count, 1)
        XCTAssertEqual(
            athletes[0].videos.map(\.lastPathComponent),
            ["first.mp4", "second.mp4"]
        )
    }

    func testRejectsMissingDirectory() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try VideoLibrary.scan(missing))
    }

    func testSortingOnlyCollectsTopLevelRawVideos() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("C0002.MP4"))
        try Data().write(to: root.appendingPathComponent("C0001.mov"))
        let nested = root.appendingPathComponent("organized/Alice")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("already-sorted.mp4"))

        let videos = try SortingLibrary.rawVideos(in: root)

        XCTAssertEqual(videos.map(\.lastPathComponent), ["C0001.mov", "C0002.MP4"])
    }

    func testSortingUsesKnownAthleteCasingAndSanitizesEventFolder() throws {
        let names = ["Élise Martin", "Bob Jones"]
        XCTAssertEqual(
            SortingLibrary.bestAthleteName(for: "elise", names: names),
            "Élise Martin"
        )
        XCTAssertEqual(
            try SortingLibrary.eventFolder(date: Date(timeIntervalSince1970: 0), title: " Neuss / Indoor "),
            "1970-01-01_Neuss-Indoor"
        )
    }

    /// `.mkv` is not merely unsupported by the pipeline — `AVPlayer` cannot open
    /// it either. Listing it put files in the sidebar that fail on selection.
    /// Verified against a real Matroska file: `AVURLAsset.load(.isPlayable)`
    /// fails with "Cannot Open", where the same probe on an `.mp4` succeeds.
    func testTheLibraryDoesNotListFormatsAVFoundationCannotOpen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let athlete = root.appendingPathComponent("Idun", isDirectory: true)
        try FileManager.default.createDirectory(at: athlete, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["run.mp4", "run.mov", "run.m4v", "run.mkv", "run.webm", "run.avi"] {
            try Data("x".utf8).write(to: athlete.appendingPathComponent(name))
        }

        let groups = try VideoLibrary.scan(root)
        let listed = Set((groups.first?.videos ?? []).map { $0.lastPathComponent })
        XCTAssertEqual(listed, ["run.mp4", "run.mov", "run.m4v"])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
