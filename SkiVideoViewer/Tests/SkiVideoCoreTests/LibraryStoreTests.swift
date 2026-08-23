import XCTest
@testable import SkiVideoCore

/// The list a coach lands on.
///
/// Opening footage was an action repeated every launch — pick a folder, or sign
/// in and browse a shared drive — because nothing about the choice survived the
/// app. These tests are about the choice surviving, and about the two ways that
/// goes wrong: forgetting something that worked, and remembering something
/// twice.
final class LibraryStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: LibraryStore!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "LibraryStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = LibraryStore(defaults: defaults)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func drive(_ name: String, root: String) -> Library {
        Library(name: name, kind: .drive(rootID: root))
    }

    // MARK: - Surviving the launch

    func testALibraryAddedIsThereNextTime() {
        store.add(drive("RG Albis Videos", root: "drive-1"))

        let reopened = LibraryStore(defaults: defaults).all()
        XCTAssertEqual(reopened.map(\.name), ["RG Albis Videos"])
        XCTAssertEqual(reopened.first?.kind, .drive(rootID: "drive-1"))
    }

    /// The place is the identity. Connecting the same drive again — after
    /// signing out, or because the coach forgot it was there — must not leave
    /// two rows for one folder.
    func testConnectingTheSamePlaceTwiceKeepsOneRow() {
        let first = store.add(drive("Videos", root: "drive-1"))
        store.markOpened(first.id)

        let again = store.add(Library(name: "Club videos", kind: .drive(rootID: "drive-1"),
                                      convention: .athleteThenEvent))

        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(again.id, first.id, "the row kept its identity and its history")
        XCTAssertEqual(store.all().first?.name, "Club videos", "and took the newer name")
        XCTAssertEqual(store.all().first?.convention, .athleteThenEvent)
        XCTAssertNotNil(store.all().first?.lastOpened)
    }

    /// A folder and a drive that happen to share a name are not the same
    /// library, and neither are two different folders.
    func testDifferentPlacesAreDifferentLibraries() {
        store.add(drive("Videos", root: "drive-1"))
        store.add(drive("Videos", root: "drive-2"))
        store.add(Library(name: "Videos", kind: .folder(bookmark: Data([1, 2, 3]))))

        XCTAssertEqual(store.all().count, 3)
    }

    // MARK: - Order

    /// Most recently opened first: the list is a work surface, not an archive.
    func testTheMostRecentlyOpenedComesFirst() {
        let a = store.add(drive("A", root: "1"))
        let b = store.add(drive("B", root: "2"))

        store.markOpened(a.id, at: Date(timeIntervalSince1970: 1_000))
        store.markOpened(b.id, at: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(store.all().map(\.name), ["B", "A"])

        store.markOpened(a.id, at: Date(timeIntervalSince1970: 3_000))
        XCTAssertEqual(store.all().map(\.name), ["A", "B"])
    }

    /// Never-opened sorts last, not first. It is usually the one just added and
    /// already on screen, and putting it above libraries the coach uses daily
    /// would reorder the list around the least useful row in it.
    func testANeverOpenedLibrarySortsLast() {
        let used = store.add(drive("Used", root: "1"))
        store.add(drive("Never", root: "2"))
        store.markOpened(used.id)

        XCTAssertEqual(store.all().map(\.name), ["Used", "Never"])
    }

    // MARK: - Only on success

    /// `markOpened` is called after an open succeeds, so an id that is not
    /// there must do nothing rather than resurrect a removed row.
    func testMarkingAnUnknownLibraryDoesNothing() {
        store.add(drive("A", root: "1"))
        store.markOpened(UUID())

        XCTAssertEqual(store.all().count, 1)
        XCTAssertNil(store.all().first?.lastOpened)
    }

    // MARK: - Editing

    func testRenaming() {
        let library = store.add(drive("Videos", root: "1"))
        store.rename(library.id, to: "  Club videos  ")
        XCTAssertEqual(store.all().first?.name, "Club videos")

        store.rename(library.id, to: "   ")
        XCTAssertEqual(store.all().first?.name, "Club videos", "an empty name is not a name")
    }

    /// The layout belongs to the library, not to the app: athlete-then-event
    /// can be right for the club drive and wrong for a season folder.
    func testTheConventionIsRememberedPerLibrary() {
        let club = store.add(drive("Club", root: "1"))
        let season = store.add(Library(name: "Season", kind: .folder(bookmark: Data([9]))))

        store.setConvention(.athleteThenEvent, for: club.id)
        store.setConvention(.eventThenAthlete, for: season.id)

        XCTAssertEqual(store.convention(for: club.id), .athleteThenEvent)
        XCTAssertEqual(store.convention(for: season.id), .eventThenAthlete)
    }

    func testRemoving() {
        let a = store.add(drive("A", root: "1"))
        store.add(drive("B", root: "2"))

        store.remove(a.id)
        XCTAssertEqual(store.all().map(\.name), ["B"])
    }

    /// Nothing stored is not an error, it is a coach who has never opened
    /// anything — the empty state the landing screen is built around.
    func testAnEmptyStoreIsEmptyRatherThanBroken() {
        XCTAssertTrue(store.all().isEmpty)
    }

    /// Defaults can hold anything, including something written by a future
    /// version. Unreadable data must read as "no libraries" rather than crash
    /// the launch it is read on.
    func testUnreadableDataReadsAsEmpty() {
        defaults.set(Data("not json".utf8), forKey: LibraryStore.defaultsKey)
        XCTAssertTrue(store.all().isEmpty)
    }
    // MARK: - The same folder is one library

    /// Adding the same folder twice must not make two libraries.
    ///
    /// This is what a coach saw: two identical "Snow" rows, then three. A
    /// bookmark is not an identity — both platforms mint different bytes for
    /// the same directory each time one is created — so `Kind.folder` compared
    /// by value made every re-add a new place.
    func testTheSameFolderAddedTwiceIsOneLibrary() {
        let store = LibraryStore(defaults: defaults)
        let path = "/Users/coach/Videos/Snow"

        store.add(Library(name: "Snow", kind: .folder(bookmark: Data([1, 2, 3])), folderPath: path))
        store.add(Library(name: "Snow", kind: .folder(bookmark: Data([9, 9, 9])), folderPath: path))

        XCTAssertEqual(store.all().count, 1, "same folder, different bookmark bytes — one library")
    }

    /// Two different folders stay two libraries, whatever their bookmarks say.
    func testTwoFoldersAreTwoLibraries() {
        let store = LibraryStore(defaults: defaults)
        store.add(Library(name: "Snow", kind: .folder(bookmark: Data([1])), folderPath: "/a/Snow"))
        store.add(Library(name: "Camp", kind: .folder(bookmark: Data([1])), folderPath: "/b/Camp"))

        XCTAssertEqual(store.all().count, 2)
    }

    /// A store written before folders carried a path still reads back, and its
    /// duplicates are collapsed on the way out rather than left for the coach
    /// to tidy up.
    func testDuplicatesAlreadyWrittenAreCollapsedOnRead() throws {
        let earlier = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        let stored = [
            Library(name: "Snow", kind: .folder(bookmark: Data([1])), lastOpened: earlier,
                    folderPath: "/a/Snow"),
            Library(name: "Snow", kind: .folder(bookmark: Data([2])), lastOpened: later,
                    folderPath: "/a/Snow"),
        ]
        defaults.set(try JSONEncoder().encode(stored), forKey: LibraryStore.defaultsKey)

        let all = LibraryStore(defaults: defaults).all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.lastOpened, later, "the most recently opened row is the one kept")
    }

}
