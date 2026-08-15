import XCTest
@testable import SkiVideoCore

/// `AthleteRoster` merges an open library's athlete names with any added
/// locally, and persists the local additions.
///
/// `AthleteRoster.storeRoot` is repointed at a fresh temporary directory in
/// `setUp` and restored in `tearDown` — this project has polluted the
/// developer's real `~/Library/Application Support/SkiVideoViewer` three
/// times already, and `testStoreRootIsHonoured` exists specifically to prove
/// a roster store is not a fourth.
final class AthleteRosterTests: XCTestCase {
    private var root: URL!
    private var previousStoreRoot: URL!
    private var realApplicationSupport: URL!

    override func setUpWithError() throws {
        previousStoreRoot = AthleteRoster.storeRoot
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("athlete-roster-\(UUID().uuidString)", isDirectory: true)
        AthleteRoster.storeRoot = root
        realApplicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SkiVideoViewer", isDirectory: true)
    }

    override func tearDownWithError() throws {
        AthleteRoster.storeRoot = previousStoreRoot
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func group(_ name: String, event: String) -> AthleteGroup {
        AthleteGroup(id: "\(name)-\(event)", name: name, event: event, videos: [])
    }

    /// Fails if `names(inLibrary:)` keys its de-duplication on something
    /// per-event — `AthleteGroup.id`, or the (name, event) pair itself —
    /// instead of the athlete's name alone, so one athlete with clips at
    /// three events would appear three times.
    func testLibraryNamesAreDeduplicatedAcrossEvents() {
        let athletes = [
            group("Ada Example", event: "Brunni"),
            group("Ada Example", event: "Neuss"),
            group("Ada Example", event: "Davos"),
        ]

        XCTAssertEqual(AthleteRoster.names(inLibrary: athletes), ["Ada Example"])
    }

    /// Fails if `addLocally` only updates some in-memory state — a static
    /// array that would still make a later `merged` call in the *same*
    /// process report the name — rather than actually writing it to disk
    /// under `storeRoot`, where a later launch of the app would look.
    func testALocallyAddedNameAppearsInMergedAndSurvivesAReload() throws {
        try AthleteRoster.addLocally("New Joiner")

        let filesOnDisk = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )
        XCTAssertFalse(filesOnDisk.isEmpty, "addLocally must persist under storeRoot, not just in memory")

        XCTAssertEqual(AthleteRoster.merged(library: []), ["New Joiner"])
    }

    /// Fails if `merged` de-duplicates library and local names by exact
    /// string equality instead of `SortingLibrary.normalized(_:)`'s case-
    /// and whitespace-insensitive comparison, so "Ada Example" from the
    /// library and " ada example " added locally would both appear.
    func testANameAlreadyInTheLibraryIsNotDuplicatedByAddingItLocally() throws {
        let library = [group("Ada Example", event: "Brunni")]

        try AthleteRoster.addLocally(" ada example ")

        XCTAssertEqual(
            AthleteRoster.merged(library: library), ["Ada Example"],
            "the library's spelling must win, and no second entry may appear"
        )
    }

    /// Fails if `addLocally` appends unconditionally instead of checking
    /// whether the (normalized) name is already stored, so calling it twice
    /// would leave two entries for the same athlete.
    func testAddLocallyIsIdempotent() throws {
        try AthleteRoster.addLocally("New Joiner")
        try AthleteRoster.addLocally("New Joiner")

        XCTAssertEqual(AthleteRoster.merged(library: []), ["New Joiner"])
    }

    /// Fails if `AthleteRoster` reads or writes through a hardcoded
    /// Application Support path instead of the overridable `storeRoot` —
    /// which would make this test write a stray file into the developer's
    /// real `~/Library/Application Support/SkiVideoViewer`, the same mistake
    /// this project has made three times already.
    func testStoreRootIsHonoured() throws {
        let before = (try? FileManager.default.contentsOfDirectory(
            at: realApplicationSupport, includingPropertiesForKeys: nil
        )) ?? []

        try AthleteRoster.addLocally("Temp Athlete")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.path),
            "addLocally must write under the overridden storeRoot"
        )

        let after = (try? FileManager.default.contentsOfDirectory(
            at: realApplicationSupport, includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertEqual(
            Set(after.map(\.lastPathComponent)), Set(before.map(\.lastPathComponent)),
            "nothing new may appear in the real Application Support directory"
        )
    }
}
