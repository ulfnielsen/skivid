import XCTest
@testable import SkiVideoCore

final class RemoteLibraryIndexTests: XCTestCase {
    private func file(
        _ id: String, _ name: String, _ path: [String], size: Int64 = 1
    ) -> RemoteFile {
        RemoteFile(id: id, name: name, path: path, size: size,
                   contentVersion: "v1", md5: nil)
    }

    // MARK: - Library URLs

    /// The folder path rides in the URL path, which is what `LibraryGrouping`
    /// sorts on. Without it, Drive clips sort by file name alone and sibling
    /// folders interleave — the defect `GoogleDriveSupport` documented.
    func testALibraryURLCarriesTheFolderPathAndTheFileID() {
        let url = RemoteLibraryIndex.libraryURL(
            for: file("1AbC", "run 3.mp4", ["Neuss 2026", "Ada Lovelace"]),
            providerIdentifier: "gdrive"
        )
        XCTAssertEqual(url.scheme, "gdrive")
        XCTAssertEqual(url.host, "1AbC")
        XCTAssertEqual(url.path, "/Neuss 2026/Ada Lovelace/run 3.mp4")
        XCTAssertEqual(url.lastPathComponent, "run 3.mp4")
    }

    /// Two clips sharing a name in different folders must be different URLs,
    /// or the index would lose one of them.
    func testTwoClipsWithOneNameInDifferentFoldersAreDifferentURLs() {
        let a = RemoteLibraryIndex.libraryURL(
            for: file("a", "run.mp4", ["E", "Ada"]), providerIdentifier: "gdrive")
        let b = RemoteLibraryIndex.libraryURL(
            for: file("b", "run.mp4", ["E", "Bea"]), providerIdentifier: "gdrive")
        XCTAssertNotEqual(a, b)
    }

    /// A file id is base64url and contains `-` and `_`. Verified against
    /// Foundation: both survive as a URL host.
    func testAFileIDWithBase64URLCharactersSurvives() {
        let url = RemoteLibraryIndex.libraryURL(
            for: file("1A_bC-dEf", "run.mp4", ["E", "Ada"]), providerIdentifier: "gdrive")
        XCTAssertEqual(url.host, "1A_bC-dEf")
    }

    /// An id that cannot form a URL host must still produce a *unique* URL.
    /// Sharing one fallback URL would drop every such clip but the last, and
    /// leave duplicate rows pointing at it.
    func testIDsThatCannotFormAHostStillGetDistinctURLs() {
        let a = RemoteLibraryIndex.libraryURL(
            for: file("bad id one", "run.mp4", ["E", "Ada"]), providerIdentifier: "gdrive")
        let b = RemoteLibraryIndex.libraryURL(
            for: file("bad id two", "run.mp4", ["E", "Ada"]), providerIdentifier: "gdrive")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Grouping

    func testAthleteAndEventComeFromTheLastTwoPathComponents() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive",
            files: [file("a", "run.mp4", ["Neuss 2026", "Ada"])],
            convention: .eventThenAthlete
        )
        XCTAssertEqual(index.athletes.map(\.name), ["Ada"])
        XCTAssertEqual(index.athletes.map(\.event), ["Neuss 2026"])
    }

    /// A clip one level down has an athlete but no event, exactly as a local
    /// library does for `root/Athlete/clip.mp4`.
    func testAClipOneLevelDownHasAnAthleteButNoEvent() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive",
            files: [file("a", "run.mp4", ["Ada"])],
            convention: .eventThenAthlete
        )
        XCTAssertEqual(index.athletes.map(\.name), ["Ada"])
        XCTAssertNil(index.athletes[0].event)
    }

    /// A clip loose in the root has neither. It is grouped under the root's
    /// own name, which is the closest analogue to what the local scanner does.
    func testALooseClipIsGroupedUnderTheRootName() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive",
            rootName: "Club Footage",
            files: [file("a", "run.mp4", [])]
        )
        XCTAssertEqual(index.athletes.map(\.name), ["Club Footage"])
        XCTAssertNil(index.athletes[0].event)
    }

    /// Clips deeper than event/athlete take the two folders nearest them, so
    /// an extra organisational layer above does not break grouping.
    func testDeeperClipsUseTheTwoFoldersNearestThem() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive",
            files: [file("a", "run.mp4", ["2026", "Neuss 2026", "Ada"])],
            convention: .eventThenAthlete
        )
        XCTAssertEqual(index.athletes.map(\.name), ["Ada"])
        XCTAssertEqual(index.athletes.map(\.event), ["Neuss 2026"])
    }

    /// Within an athlete, clips sort by folder path *before* name — the local
    /// scanner's order, which the old flat URL could not produce.
    ///
    /// The two clips group together (the rule reads the two folders nearest
    /// the clip, so both are event "E", athlete "Ada") but sit in different
    /// folders. `/Archive/E/Ada/z.mp4` sorts before `/E/Ada/a.mp4` on path
    /// while sorting *after* it on name, so this test fails under any
    /// filename-only ordering — which is exactly what the old synthesised URL
    /// produced, and the defect this task exists to fix.
    ///
    /// Verified against Foundation: path order gives ["z.mp4", "a.mp4"],
    /// filename order gives ["a.mp4", "z.mp4"].
    func testClipsSortByFolderPathBeforeName() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive",
            files: [
                file("a", "a.mp4", ["E", "Ada"]),
                file("z", "z.mp4", ["Archive", "E", "Ada"]),
            ]
        )
        XCTAssertEqual(index.athletes.count, 1, "both clips belong to one athlete")
        XCTAssertEqual(
            index.athletes[0].videos.map(\.lastPathComponent), ["z.mp4", "a.mp4"]
        )
    }

    // MARK: - Layout

    /// **The operator's drive.** Their index stored `eventThenAthlete` while
    /// every one of its 335 two-deep clips is filed
    /// `<athlete>/<dated session>/clip.mp4`, so the sidebar showed dates as
    /// athletes. These four names are real ones from it, including the two
    /// shapes a stricter date rule would miss: `20251213 Zürs` has no
    /// separators, and `2026-25-04_Hoch-Ybrig` has month 25 — a typo, and
    /// still obviously a date to whoever typed it.
    func testDatedFoldersUnderNamedOnesInferAthleteFirst() {
        let inferred = RemoteLibraryIndex.inferredConvention(from: [
            file("a", "a.mp4", ["Idun Nielsen", "2026-02-25_Hoch-Ybrig"]),
            file("b", "b.mp4", ["Nora Nielsen", "20251213 Zürs"]),
            file("c", "c.mp4", ["Harry Korrodi", "2026-01-14_Brunni"]),
            file("d", "d.mp4", ["Maxi Wiest", "2026-25-04_Hoch-Ybrig"]),
        ])
        XCTAssertEqual(inferred, .athleteThenEvent)
    }

    /// The same rule, the other way round — otherwise this would not be
    /// inference at all, just a second hardcoded answer.
    func testDatedFoldersAboveNamedOnesInferEventFirst() {
        let inferred = RemoteLibraryIndex.inferredConvention(from: [
            file("a", "a.mp4", ["2026-07-16_Neuss", "Ada"]),
            file("b", "b.mp4", ["2026-07-17_Neuss", "Bea"]),
        ])
        XCTAssertEqual(inferred, .eventThenAthlete)
    }

    /// Folders that look like nothing in particular decide nothing. Nil is the
    /// honest answer and a real outcome: the caller has a default for it, and
    /// a guess here would be indistinguishable from evidence later.
    func testFoldersWithNoDatesAtAllDecideNothing() {
        XCTAssertNil(RemoteLibraryIndex.inferredConvention(from: [
            file("a", "a.mp4", ["Club", "Ada"]),
            file("b", "b.mp4", ["Club", "Bea"]),
        ]))
    }

    /// A clip with fewer than two folders above it has no pair to compare, so
    /// it abstains — including the pathless clips this whole fix exists
    /// because of, which must not drag the answer either way.
    func testClipsWithoutTwoFoldersAboveThemDoNotVote() {
        XCTAssertNil(RemoteLibraryIndex.inferredConvention(from: [
            file("a", "a.mp4", []),
            file("b", "b.mp4", ["2026-01-14_Brunni"]),
        ]))
    }

    /// An even split decides nothing rather than tipping on file order.
    func testAnEvenSplitDecidesNothing() {
        XCTAssertNil(RemoteLibraryIndex.inferredConvention(from: [
            file("a", "a.mp4", ["Ada", "2026-07-16_Neuss"]),
            file("b", "b.mp4", ["2026-07-17_Neuss", "Bea"]),
        ]))
    }

    /// A bare year — `Neuss 2026`, the shape the local libraries use — is
    /// enough where nothing carries a full date.
    func testABareYearNamesAnEventWhenNothingCarriesADate() {
        XCTAssertEqual(
            RemoteLibraryIndex.inferredConvention(from: [
                file("a", "a.mp4", ["Neuss 2026", "Ada"]),
            ]),
            .eventThenAthlete
        )
    }

    /// …but only where nothing does. An athlete folder carrying a birth year
    /// reads as an event to the year rule; a library that dates its sessions
    /// properly must not have its answer diluted by one clip that does not.
    /// Two year-only pairs against one dated pair, and the dated one wins.
    func testADatedFolderOutranksAYearNoMatterHowManyYearsThereAre() {
        XCTAssertEqual(
            RemoteLibraryIndex.inferredConvention(from: [
                file("a", "a.mp4", ["Anna 2010", "Neuss 2026"]),
                file("b", "b.mp4", ["Bea 2011", "Neuss 2026"]),
                file("c", "c.mp4", ["Carl", "2026-07-16_Neuss"]),
            ]),
            .athleteThenEvent
        )
    }

    /// Changing the layout must re-group the clips already indexed and fetch
    /// nothing. Asserted on the athletes actually changing, because an index
    /// that merely stored the new convention without re-grouping would look
    /// identical to its caller until the next reload.
    func testChangingTheLayoutRegroupsTheFilesAlreadyIndexed() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive",
            files: [file("a", "run.mp4", ["Ada", "2026-07-16_Neuss"])],
            convention: .eventThenAthlete
        )
        XCTAssertEqual(index.athletes.map(\.name), ["2026-07-16_Neuss"])

        let relaid = index.settingConvention(.athleteThenEvent, chosenByOperator: true)

        XCTAssertEqual(relaid.athletes.map(\.name), ["Ada"])
        XCTAssertEqual(relaid.athletes.map(\.event), ["2026-07-16_Neuss"])
        XCTAssertTrue(relaid.conventionWasChosen)
        XCTAssertEqual(relaid.file(for: relaid.athletes[0].videos[0])?.id, "a",
                       "the same files, re-grouped — not refetched")
    }

    /// Whether the layout was chosen or inferred has to survive a reload, or
    /// the next open cannot tell which of the two rules to apply.
    func testAChosenLayoutIsStillMarkedChosenAfterAReload() async throws {
        try await withTemporaryIndexStore {
            try RemoteLibraryIndex(
                providerIdentifier: "gdrive",
                files: [file("a", "run.mp4", ["Ada", "2026-07-16_Neuss"])],
                convention: .eventThenAthlete,
                conventionWasChosen: true
            ).save(forRoot: "d1")

            let loaded = try XCTUnwrap(RemoteLibraryIndex.load(forRoot: "d1"))
            XCTAssertEqual(loaded.convention, .eventThenAthlete)
            XCTAssertTrue(loaded.conventionWasChosen)
        }
    }

    // MARK: - Filtering

    func testOnlyPlayableExtensionsAreIndexed() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive",
            files: [
                file("a", "run.mp4", ["E", "Ada"]),
                file("b", "notes.txt", ["E", "Ada"]),
                file("c", "old.mkv", ["E", "Ada"]),
            ]
        )
        XCTAssertEqual(index.athletes[0].videos.map(\.lastPathComponent), ["run.mp4"])
    }

    /// The same list the local scanner uses, not a copy of it. Drive kept its
    /// own set until 2026-08-08 and offered files `AVPlayer` cannot open.
    func testTheExtensionListIsTheLocalScannersOwn() {
        XCTAssertEqual(
            RemoteLibraryIndex.supportedExtensions, VideoLibrary.supportedExtensions
        )
    }

    // MARK: - Lookup

    func testAFileCanBeFoundBackFromItsLibraryURL() {
        let indexed = file("1AbC", "run.mp4", ["E", "Ada"])
        let index = RemoteLibraryIndex(providerIdentifier: "gdrive", files: [indexed])
        let url = index.athletes[0].videos[0]
        XCTAssertEqual(index.file(for: url)?.id, "1AbC")
    }

    func testAnUnknownURLFindsNothing() {
        let index = RemoteLibraryIndex(providerIdentifier: "gdrive", files: [])
        XCTAssertNil(index.file(for: URL(fileURLWithPath: "/tmp/run.mp4")))
    }

    // MARK: - Persistence

    func testAnIndexSurvivesASaveAndLoad() async throws {
        try await withTemporaryIndexStore {
            let index = RemoteLibraryIndex(
                providerIdentifier: "gdrive",
                files: [file("a", "run.mp4", ["E", "Ada"])],
                cursor: "cursor-1",
                convention: .eventThenAthlete
            )
            try index.save(forRoot: "d1")

            let loaded = try XCTUnwrap(RemoteLibraryIndex.load(forRoot: "d1"))
            XCTAssertEqual(loaded.athletes.map(\.name), ["Ada"])
            XCTAssertEqual(loaded.cursor, "cursor-1")
            XCTAssertEqual(loaded.file(for: loaded.athletes[0].videos[0])?.id, "a")
        }
    }

    func testTwoDrivesKeepSeparateIndexes() async throws {
        try await withTemporaryIndexStore {
            try RemoteLibraryIndex(
                providerIdentifier: "gdrive", files: [file("a", "a.mp4", ["E", "Ada"])],
                cursor: nil, convention: .eventThenAthlete
            ).save(forRoot: "d1")
            try RemoteLibraryIndex(
                providerIdentifier: "gdrive", files: [file("b", "b.mp4", ["E", "Bea"])],
                cursor: nil, convention: .eventThenAthlete
            ).save(forRoot: "d2")

            XCTAssertEqual(RemoteLibraryIndex.load(forRoot: "d1")?.athletes.map(\.name), ["Ada"])
            XCTAssertEqual(RemoteLibraryIndex.load(forRoot: "d2")?.athletes.map(\.name), ["Bea"])
        }
    }

    func testNoStoredIndexLoadsAsNil() async {
        await withTemporaryIndexStore {
            XCTAssertNil(RemoteLibraryIndex.load(forRoot: "never-saved"))
        }
    }

    /// An index written by an older build is refused, not adapted — the same
    /// rule `AlignmentTrackStore` applies to a stale track. Refusing costs one
    /// sweep; adapting silently costs a library that is subtly wrong.
    ///
    /// Asserted as a *pair*, because a version-0 fixture alone proves nothing:
    /// any payload the decoder rejects for an unrelated reason — a missing
    /// field, a typo — makes `load` return nil too, so the test would pass
    /// with the version check deleted. The current-version fixture is
    /// byte-identical apart from `version`, so the only thing that can explain
    /// one loading and the other not is the gate itself.
    func testAnIndexFromAnOlderVersionIsRefusedWhileACurrentOneLoads() async throws {
        try await withTemporaryIndexStore {
            try FileManager.default.createDirectory(
                at: RemoteLibraryIndex.storeRoot, withIntermediateDirectories: true
            )

            func write(version: Int, forRoot rootID: String) throws {
                try Data("""
                {"version":\(version),"providerIdentifier":"gdrive","rootName":"Club",\
                "files":[],"cursor":null}
                """.utf8).write(to: RemoteLibraryIndex.storeURL(forRoot: rootID))
            }

            try write(version: 0, forRoot: "old")
            try write(version: RemoteLibraryIndex.currentVersion, forRoot: "current")

            XCTAssertNil(RemoteLibraryIndex.load(forRoot: "old"))
            XCTAssertNotNil(
                RemoteLibraryIndex.load(forRoot: "current"),
                "the fixture must be decodable, or the version test proves nothing"
            )
        }
    }

    /// The reset for the orphaned paths. A version 1 index is not merely old,
    /// it is wrong: the change feed resolved a changed clip's folders against
    /// the change page alone, so every clip whose bytes changed under an
    /// untouched folder was stored with an empty path — 63 of the operator's
    /// 407, grouped under the drive's own name as an athlete called "Videos".
    /// The names are not recoverable from anything stored, so the only repair
    /// is a re-sweep, and refusing the file is what makes it happen by itself.
    ///
    /// The fixture is a real version 1 payload, orphan included, so this fails
    /// if `currentVersion` is ever put back.
    func testAVersionOneIndexIsRefusedSoOrphanedPathsAreSweptAway() async throws {
        try await withTemporaryIndexStore {
            try FileManager.default.createDirectory(
                at: RemoteLibraryIndex.storeRoot, withIntermediateDirectories: true
            )
            try Data("""
            {"version":1,"providerIdentifier":"gdrive","rootName":"Videos","cursor":"t1",\
            "convention":"eventThenAthlete","files":[{"id":"a","name":"Nora1_resized.MP4",\
            "path":[],"size":1,"contentVersion":"r2"}]}
            """.utf8).write(to: RemoteLibraryIndex.storeURL(forRoot: "d1"))

            XCTAssertNil(RemoteLibraryIndex.load(forRoot: "d1"))
        }
    }

    /// The manual escape hatch, for a cached index that is wrong in a way the
    /// version gate has already let through. Asserted by loading the file back
    /// rather than by `discard` returning, because it returns nothing.
    func testDiscardingLeavesNothingToLoad() async throws {
        try await withTemporaryIndexStore {
            try RemoteLibraryIndex(
                providerIdentifier: "gdrive", files: [file("a", "run.mp4", ["E", "Ada"])]
            ).save(forRoot: "d1")
            XCTAssertNotNil(RemoteLibraryIndex.load(forRoot: "d1"))

            RemoteLibraryIndex.discard(forRoot: "d1")

            XCTAssertNil(RemoteLibraryIndex.load(forRoot: "d1"))
        }
    }

    /// Discarding an index that was never written is the state the caller
    /// wanted, not a failure — and nothing about it may throw.
    func testDiscardingAnIndexThatIsNotThereIsHarmless() async {
        await withTemporaryIndexStore {
            RemoteLibraryIndex.discard(forRoot: "never-saved")
        }
    }

    func testAnUnreadableIndexLoadsAsNilRatherThanThrowing() async throws {
        try await withTemporaryIndexStore {
            try FileManager.default.createDirectory(
                at: RemoteLibraryIndex.storeRoot, withIntermediateDirectories: true
            )
            try Data("not json".utf8).write(to: RemoteLibraryIndex.storeURL(forRoot: "d1"))
            XCTAssertNil(RemoteLibraryIndex.load(forRoot: "d1"))
        }
    }

    // MARK: - Applying changes

    func testANewFileAppearsInTheLibrary() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive", files: [file("a", "a.mp4", ["E", "Ada"])], cursor: "c1"
        )
        let refreshed = index.applying(
            RemoteLibraryChanges(
                changed: [file("b", "b.mp4", ["E", "Ada"])], removed: [], cursor: "c2"
            )
        )
        XCTAssertEqual(refreshed.athletes[0].videos.count, 2)
        XCTAssertEqual(refreshed.cursor, "c2")
    }

    /// The change feed is coalesced per file and replayed by id, so applying
    /// the same change twice must not duplicate a clip.
    func testApplyingTheSameChangeTwiceIsIdempotent() {
        let index = RemoteLibraryIndex(providerIdentifier: "gdrive", files: [], cursor: nil)
        let change = RemoteLibraryChanges(
            changed: [file("a", "a.mp4", ["E", "Ada"])], removed: [], cursor: "c1"
        )
        XCTAssertEqual(index.applying(change).applying(change).athletes[0].videos.count, 1)
    }

    /// A rename arrives as a change to the same id. The clip must move, not
    /// double.
    func testARenamedFileReplacesItsOldEntry() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive", files: [file("a", "old.mp4", ["E", "Ada"])], cursor: nil
        )
        let refreshed = index.applying(
            RemoteLibraryChanges(
                changed: [file("a", "new.mp4", ["E", "Ada"])], removed: [], cursor: "c1"
            )
        )
        XCTAssertEqual(
            refreshed.athletes[0].videos.map(\.lastPathComponent), ["new.mp4"]
        )
    }

    func testARemovedFileLeavesTheLibrary() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive",
            files: [file("a", "a.mp4", ["E", "Ada"]), file("b", "b.mp4", ["E", "Ada"])],
            cursor: nil
        )
        let refreshed = index.applying(
            RemoteLibraryChanges(changed: [], removed: ["a"], cursor: "c1")
        )
        XCTAssertEqual(refreshed.athletes[0].videos.map(\.lastPathComponent), ["b.mp4"])
    }

    /// An athlete whose last clip goes away should not linger as an empty row.
    func testAnAthleteWithNoClipsLeftDisappears() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive", files: [file("a", "a.mp4", ["E", "Ada"])], cursor: nil
        )
        let refreshed = index.applying(
            RemoteLibraryChanges(changed: [], removed: ["a"], cursor: "c1")
        )
        XCTAssertTrue(refreshed.athletes.isEmpty)
    }
}
