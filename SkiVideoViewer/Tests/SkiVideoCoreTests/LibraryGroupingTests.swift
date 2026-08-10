import Foundation
import XCTest
@testable import SkiVideoCore

/// The grouping rules, tested on triples rather than on a directory tree, so
/// the same rules can be proven for the Google Drive scan — which walks folder
/// ids, not paths, and could never be exercised through `VideoLibrary.scan`.
final class LibraryGroupingTests: XCTestCase {
    private func video(_ name: String) -> URL {
        URL(fileURLWithPath: "/library/\(name)")
    }

    func testSameAthleteAtTwoEventsStaysTwoGroups() {
        let groups = LibraryGrouping.group([
            .init(video: video("a.mp4"), athlete: "Alice", event: "event-one"),
            .init(video: video("b.mp4"), athlete: "alice", event: "event-two"),
        ])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(Set(groups.map(\.event)), ["event-one", "event-two"])
    }

    func testSameAthleteWithinOneEventMergesAcrossCasingAndDiacritics() {
        let groups = LibraryGrouping.group([
            .init(video: video("a.mp4"), athlete: "Sofie", event: "neuss"),
            .init(video: video("b.mp4"), athlete: "sofié", event: "neuss"),
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "Sofie", "the first spelling seen wins")
        XCTAssertEqual(groups[0].videos.count, 2)
    }

    func testEventsSortDescendingSoTheNewestDateIsFirst() {
        let groups = LibraryGrouping.group([
            .init(video: video("a.mp4"), athlete: "Alice", event: "2026-07-16_Neuss"),
            .init(video: video("b.mp4"), athlete: "Alice", event: "2026-08-02_Oberhof"),
        ])

        XCTAssertEqual(groups.map(\.event), ["2026-08-02_Oberhof", "2026-07-16_Neuss"])
    }

    func testAthletesSortAlphabeticallyWithinAnEvent() {
        let groups = LibraryGrouping.group([
            .init(video: video("c.mp4"), athlete: "Chris", event: "neuss"),
            .init(video: video("a.mp4"), athlete: "Alice", event: "neuss"),
            .init(video: video("b.mp4"), athlete: "Bob", event: "neuss"),
        ])

        XCTAssertEqual(groups.map(\.name), ["Alice", "Bob", "Chris"])
    }

    func testEventlessGroupsSortLast() {
        let groups = LibraryGrouping.group([
            .init(video: video("a.mp4"), athlete: "Alice", event: nil),
            .init(video: video("b.mp4"), athlete: "Bob", event: "2026-08-02_Oberhof"),
        ])

        XCTAssertEqual(groups.map(\.name), ["Bob", "Alice"])
        XCTAssertNil(groups[1].event)
    }

    func testIdsAreEventScopedSoTwoSameNamedAthletesAreSelectableApart() {
        let groups = LibraryGrouping.group([
            .init(video: video("a.mp4"), athlete: "Alice", event: "one"),
            .init(video: video("b.mp4"), athlete: "Alice", event: "two"),
        ])

        XCTAssertEqual(Set(groups.map(\.id)).count, 2, "ids must not collide")
    }

    func testVideosWithinAGroupSortByPath() {
        let groups = LibraryGrouping.group([
            .init(video: video("C0002.mp4"), athlete: "Alice", event: "one"),
            .init(video: video("C0001.mp4"), athlete: "Alice", event: "one"),
        ])

        XCTAssertEqual(
            groups[0].videos.map(\.lastPathComponent),
            ["C0001.mp4", "C0002.mp4"]
        )
    }

    func testAnEmptyInputProducesNoGroups() {
        XCTAssertTrue(LibraryGrouping.group([]).isEmpty)
    }

    /// `sorted` is not a stable sort, so the comparator has to impose a total
    /// order on its own rather than leaning on the input's arrangement
    /// surviving. Shuffling the same entries must therefore always produce the
    /// same sidebar — including for the pairs the comparator handles in
    /// different branches: two events, an event-less group, and several
    /// athletes sharing one event.
    func testShufflingTheInputDoesNotChangeTheOrder() {
        let entries: [LibraryGrouping.Entry] = [
            .init(video: video("a.mp4"), athlete: "Chris", event: "2026-08-02_Oberhof"),
            .init(video: video("b.mp4"), athlete: "Alice", event: "2026-08-02_Oberhof"),
            .init(video: video("c.mp4"), athlete: "Bob", event: "2026-08-02_Oberhof"),
            .init(video: video("d.mp4"), athlete: "Bob", event: "2026-07-16_Neuss"),
            .init(video: video("e.mp4"), athlete: "Alice", event: "2026-07-16_Neuss"),
            .init(video: video("f.mp4"), athlete: "Dana", event: nil),
            .init(video: video("g.mp4"), athlete: "Alice", event: nil),
        ]
        let expected = [
            "2026-08-02_Oberhof/Alice",
            "2026-08-02_Oberhof/Bob",
            "2026-08-02_Oberhof/Chris",
            "2026-07-16_Neuss/Alice",
            "2026-07-16_Neuss/Bob",
            "Alice",
            "Dana",
        ]

        XCTAssertEqual(
            LibraryGrouping.group(entries).map { [$0.event, $0.name].compactMap { $0 }.joined(separator: "/") },
            expected
        )
        for _ in 0..<50 {
            let groups = LibraryGrouping.group(entries.shuffled())
            XCTAssertEqual(
                groups.map { [$0.event, $0.name].compactMap { $0 }.joined(separator: "/") },
                expected
            )
        }
    }
}
