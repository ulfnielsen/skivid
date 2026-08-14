import Foundation
import XCTest
@testable import SkiVideoCore

/// The two things the sidebar-pivot task changes: `RemoteLibraryIndex`
/// deriving athlete/event from whichever `FolderConvention` a library
/// actually uses, and `LibraryGrouping`/`EventGroup` re-ordering and
/// re-sectioning an already-built group list on whichever dimension leads —
/// the "pivot" a coach can flip in the sidebar at any time.
///
/// The discriminating fixture below — three rows over two athletes and two
/// events — is deliberately not shrunk to one athlete or one event: either
/// would make the two pivot modes produce the same section headers, the same
/// section order, or the same row order, and a test built on it could not
/// tell a broken pivot from a working one. See
/// `/Users/ulfnielsen/Ski/script/.superpowers/sdd/2026-08-13-sign-in-and-fetch-on-select/sidebar-grouping-brief.md`.
@MainActor
final class SidebarGroupingTests: XCTestCase {
    /// Ada @ Sölden 2025, Ada @ Neuss 2026, Bea @ Neuss 2026. Built through
    /// `LibraryGrouping.group(_:)` — unaffected by this task — so these are
    /// exactly the `AthleteGroup` values a real scan would hand the pivot.
    private func fixtureGroups() -> [AthleteGroup] {
        LibraryGrouping.group([
            .init(video: URL(fileURLWithPath: "/lib/1.mp4"), athlete: "Ada", event: "Sölden 2025"),
            .init(video: URL(fileURLWithPath: "/lib/2.mp4"), athlete: "Ada", event: "Neuss 2026"),
            .init(video: URL(fileURLWithPath: "/lib/3.mp4"), athlete: "Bea", event: "Neuss 2026"),
        ])
    }

    // MARK: - 1. Leading event

    /// Verified independently of this test: `"Sölden 2025"
    /// .localizedCaseInsensitiveCompare("Neuss 2026")` returns
    /// `.orderedDescending`, so "Sölden 2025" sorts before "Neuss 2026" under
    /// the descending order this pins.
    ///
    /// Fails if event sections stop sorting descending, or if the athletes
    /// inside a section stop sorting alphabetically — either is a plausible
    /// slip when generalising `LibraryGrouping`'s old, event-only sort into a
    /// pivotable `order(_:by:)`.
    func testLeadingEventGivesDescendingHeadersWithAthletesAlphabeticalInside() {
        let ordered = LibraryGrouping.order(fixtureGroups(), by: .event)
        let sections = EventGroup.sections(of: ordered, by: .event)

        XCTAssertEqual(sections.map(\.name), ["Sölden 2025", "Neuss 2026"])
        XCTAssertEqual(sections[0].athletes.map(\.name), ["Ada"])
        XCTAssertEqual(sections[1].athletes.map(\.name), ["Ada", "Bea"])
    }

    // MARK: - 2. Leading athlete

    /// Fails if the pivot keeps the event sort applied to athletes: leading
    /// by athlete must sort *sections* alphabetically and *rows* descending
    /// by event — the mirror image of the event-led case, not a reuse of its
    /// priorities wholesale. Ada carries both events, so a wrong row order
    /// inside her own section is directly visible here.
    ///
    /// Note for whoever reads this next to the brief: the brief's worked
    /// example lists Ada's rows as "Neuss 2026, Sölden 2025", which is the
    /// *ascending* order — contradicting its own "events descending"
    /// annotation on the same line, and the brief's separate, unambiguous
    /// rule ("Leading athlete: sections alphabetical, rows descending by
    /// event"). This test follows the stated rule, matching test 1's
    /// direction: descending puts "Sölden 2025" first in both leading modes.
    func testLeadingAthleteGivesAlphabeticalHeadersWithEventsDescendingInside() {
        let ordered = LibraryGrouping.order(fixtureGroups(), by: .athlete)
        let sections = EventGroup.sections(of: ordered, by: .athlete)

        XCTAssertEqual(sections.map(\.name), ["Ada", "Bea"])
        XCTAssertEqual(sections[0].athletes.map(\.event), ["Sölden 2025", "Neuss 2026"])
        XCTAssertEqual(sections[1].athletes.map(\.event), ["Neuss 2026"])
    }

    // MARK: - 3. Selection survives a pivot

    /// Fails if pivoting resets the active selection the way opening a fresh
    /// library does. `LibraryGrouping.order` only permutes the existing
    /// `AthleteGroup` values — it never calls `LibraryGrouping.group` again —
    /// so `AthleteGroup.id`, and with it `selectedAthleteID`, must be
    /// byte-identical before and after the pivot.
    func testSwitchingThePivotPreservesTheSelectedRowsID() async throws {
        try await withTemporaryIndexStore {
            try await withTemporaryUserDefaults {
                let (model, provider, cache) = try remoteModel(files: [
                    remoteFile("a", "run.mp4", ["Sölden 2025", "Ada"]),
                    remoteFile("b", "run.mp4", ["Neuss 2026", "Ada"]),
                    remoteFile("c", "run.mp4", ["Neuss 2026", "Bea"]),
                ])
                try await model.openRemoteLibrary(
                    provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
                )

                let beaID = try XCTUnwrap(model.athletes.first { $0.name == "Bea" }?.id)
                model.selectAthlete(beaID)
                try await model.settleFetches()
                XCTAssertEqual(model.selectedAthleteID, beaID, "precondition: Bea must actually be selected")

                model.sidebarGrouping = .athlete

                XCTAssertEqual(
                    model.selectedAthleteID, beaID,
                    "the selected row's id must survive a pivot, or the coach loses their place"
                )
                XCTAssertEqual(
                    model.events.map(\.name), ["Ada", "Bea"],
                    "the sections must actually re-key on the new leading dimension"
                )
            }
        }
    }

    // MARK: - 4. Convention swaps both fields

    /// Fails if the convention swaps only one of the two fields — e.g. still
    /// reads the deepest folder as the athlete (today's rule) while reading
    /// the one above as the event, which would name the event right and the
    /// athlete wrong, or the reverse.
    func testAthleteThenEventConventionYieldsAthleteAndEventTheRightWayRound() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive",
            files: [remoteFile("a", "run.mp4", ["Ada", "Neuss 2026"])],
            convention: .athleteThenEvent
        )
        XCTAssertEqual(index.athletes.map(\.name), ["Ada"])
        XCTAssertEqual(index.athletes.map(\.event), ["Neuss 2026"])
    }

    // MARK: - 5. Local convention is unchanged

    /// The same athletes, event and clip order
    /// `VideoLibraryTests.testGroupsNestedVideosByAthleteFolder` asserts for
    /// the equivalent local tree, reproduced here through
    /// `RemoteLibraryIndex` with an explicit `.eventThenAthlete`. Fails if
    /// adding `FolderConvention` changed that branch's athlete/event
    /// assignment, its section order, or the within-athlete clip order.
    func testEventThenAthleteConventionReproducesTodaysLocalGrouping() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive",
            files: [
                remoteFile("a", "C0002.MP4", ["2026-07-16_Neuss", "Alice"]),
                remoteFile("b", "C0001.mov", ["2026-07-16_Neuss", "Alice"]),
                remoteFile("c", "C0003.m4v", ["2026-07-16_Neuss", "Bob"]),
            ],
            convention: .eventThenAthlete
        )
        XCTAssertEqual(index.athletes.map(\.name), ["Alice", "Bob"])
        XCTAssertEqual(index.athletes.map(\.event), ["2026-07-16_Neuss", "2026-07-16_Neuss"])
        XCTAssertEqual(index.athletes[0].videos.map(\.lastPathComponent), ["C0001.mov", "C0002.MP4"])
    }

    // MARK: - 6. Convention round-trips

    /// Fails if the convention is not persisted: `Stored.convention` would
    /// stay nil, `load` would fall back to `.eventThenAthlete`, and a
    /// relaunch would silently rename this fixture's athlete "Neuss 2026"
    /// and its event "Ada".
    func testRoundTrippingAnIndexPreservesItsConvention() async throws {
        try await withTemporaryIndexStore {
            let index = RemoteLibraryIndex(
                providerIdentifier: "gdrive",
                files: [remoteFile("a", "run.mp4", ["Ada", "Neuss 2026"])],
                convention: .athleteThenEvent
            )
            try index.save(forRoot: "d1")

            let loaded = try XCTUnwrap(RemoteLibraryIndex.load(forRoot: "d1"))
            XCTAssertEqual(loaded.convention, .athleteThenEvent)
            XCTAssertEqual(loaded.athletes.map(\.name), ["Ada"])
            XCTAssertEqual(loaded.athletes.map(\.event), ["Neuss 2026"])
        }
    }
}
