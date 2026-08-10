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
        XCTAssertEqual(athletes.map(\.event), ["2026-07-16_Neuss", "2026-07-16_Neuss"])
        XCTAssertEqual(
            athletes[0].videos.map(\.lastPathComponent),
            ["C0001.mov", "C0002.MP4"]
        )
        XCTAssertEqual(athletes[1].videos.map(\.lastPathComponent), ["C0003.m4v"])
    }

    func testSplitsTheSameAthleteAcrossEvents() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("event-one/Alice")
        let second = root.appendingPathComponent("event-two/alice")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data().write(to: first.appendingPathComponent("first.mp4"))
        try Data().write(to: second.appendingPathComponent("second.mp4"))

        let athletes = try VideoLibrary.scan(root)

        XCTAssertEqual(athletes.count, 2, "an athlete at two events is two entries")
        XCTAssertEqual(athletes.map(\.event), ["event-two", "event-one"])
        XCTAssertEqual(athletes[0].videos.map(\.lastPathComponent), ["second.mp4"])
        XCTAssertEqual(athletes[1].videos.map(\.lastPathComponent), ["first.mp4"])
    }

    func testAnAthleteFolderDirectlyUnderTheRootHasNoEvent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let alice = root.appendingPathComponent("Alice")
        try FileManager.default.createDirectory(at: alice, withIntermediateDirectories: true)
        try Data().write(to: alice.appendingPathComponent("run.mp4"))

        let athletes = try VideoLibrary.scan(root)

        XCTAssertEqual(athletes.count, 1)
        XCTAssertNil(athletes[0].event)
        XCTAssertEqual(athletes[0].name, "Alice")
    }

    /// The root arrives from a folder picker, a bookmark or a defaults string,
    /// so it can spell the same directory differently from the URLs the
    /// enumerator hands back. None of those spellings may turn "directly under
    /// the root" into a spurious event.
    ///
    /// The `/private` case is not hypothetical and is not macOS trivia: every
    /// test here roots in `/var/folders/…`, and `FileManager.enumerator` was
    /// measured to hand back its children as `/private/var/folders/…`. The
    /// comparison survives because `standardizedFileURL` drops a leading
    /// `/private` when the shorter path exists — so it is standardization, not
    /// any spelling-preservation by the enumerator, that does the work.
    func testTheRootIsRecognisedThroughEverySpellingOfTheSamePath() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let alice = root.appendingPathComponent("Alice")
        try FileManager.default.createDirectory(at: alice, withIntermediateDirectories: true)
        try Data().write(to: alice.appendingPathComponent("run.mp4"))

        var spellings: [(String, URL)] = [
            ("as given", root),
            ("trailing slash", URL(fileURLWithPath: root.path + "/")),
            ("unstandardised path", root.appendingPathComponent("Alice/..")),
        ]
        let privatised = URL(fileURLWithPath: "/private" + root.path)
        if FileManager.default.fileExists(atPath: privatised.path) {
            spellings.append(("/private prefix", privatised))
        }

        for (label, spelling) in spellings {
            let groups = try VideoLibrary.scan(spelling)
            // Asserting the count first: `scan` returns an empty array rather
            // than throwing when it finds nothing, so `first?.event` is nil for
            // a gutted scan too and the nil assertion alone passes vacuously.
            // That vacuity hid a real result here — a symlinked root enumerates
            // as empty, so it is not one of the spellings under test.
            XCTAssertEqual(groups.count, 1, label)
            XCTAssertNil(groups.first?.event, label)
            XCTAssertEqual(groups.first?.name, "Alice", label)
        }
    }

    /// A clip loose at the top of the chosen root has no athlete folder, so it
    /// has no event either — its parent *is* the root. Before this was pinned,
    /// the root's own parent became the event: pick `~/Desktop/Ski clips` and
    /// the sidebar grew a "Desktop" section, above the real date-prefixed
    /// events because letters sort after digits under the descending order,
    /// and the app auto-selects the first group on open.
    func testALooseClipAtTheRootHasNoEventAndIsNamedAfterTheRoot() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Ski clips", isDirectory: true)
        let nested = root.appendingPathComponent("2026-08-02_Oberhof/Alice")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("loose.mp4"))
        try Data().write(to: nested.appendingPathComponent("run.mp4"))

        let athletes = try VideoLibrary.scan(root)

        XCTAssertEqual(athletes.map(\.name), ["Alice", "Ski clips"])
        XCTAssertEqual(athletes[0].event, "2026-08-02_Oberhof")
        XCTAssertNil(athletes[1].event, "the root's own parent is not an event")
    }

    /// The event is the folder directly above the athlete, not the first
    /// component under the root. Taking the first component would call this
    /// athlete's event "2026", which is a season, not an event.
    func testTheEventIsTheFolderDirectlyAboveTheAthlete() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let alice = root.appendingPathComponent("2026/2026-08-02_Oberhof/Alice")
        try FileManager.default.createDirectory(at: alice, withIntermediateDirectories: true)
        try Data().write(to: alice.appendingPathComponent("run.mp4"))

        let athletes = try VideoLibrary.scan(root)

        XCTAssertEqual(athletes.count, 1)
        XCTAssertEqual(athletes[0].event, "2026-08-02_Oberhof")
        XCTAssertEqual(athletes[0].name, "Alice")
    }

    func testAMixedDepthTreeGroupsEachAthleteByItsOwnParent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = root.appendingPathComponent("2026-08-02_Oberhof/Alice")
        let loose = root.appendingPathComponent("Bob")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("a.mp4"))
        try Data().write(to: loose.appendingPathComponent("b.mp4"))

        let athletes = try VideoLibrary.scan(root)

        XCTAssertEqual(athletes.map(\.name), ["Alice", "Bob"])
        XCTAssertEqual(athletes[0].event, "2026-08-02_Oberhof")
        XCTAssertNil(athletes[1].event, "the event-less group sorts last")
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
