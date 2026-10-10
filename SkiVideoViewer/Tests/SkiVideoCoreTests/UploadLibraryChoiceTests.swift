import XCTest
@testable import SkiVideoCore

/// The sorting screen's "Upload to" picker. The snapshot each test hands back
/// names the library that is open now, so an assertion on `upload` says which
/// library the choice ended up reflecting. A refusal stands in for a target:
/// it carries a name and needs no provider.
@MainActor
final class UploadLibraryChoiceTests: XCTestCase {

    private let club = Library(name: "Club Drive", kind: .drive(rootID: "club"), lastOpened: Date(timeIntervalSince1970: 300))
    private let other = Library(name: "Other Drive", kind: .drive(rootID: "other"), lastOpened: Date(timeIntervalSince1970: 200))
    private let folder = Library(name: "Snow", kind: .folder(bookmark: Data()), lastOpened: Date(timeIntervalSince1970: 100))

    /// What `ViewerModel` would hold: which library is open, and every open asked for.
    private final class World {
        var open: Library?
        var opened: [String] = []
        var failing: Set<String> = []
    }

    private func makeChoice(_ world: World, libraries: [Library]? = nil) -> UploadLibraryChoice {
        UploadLibraryChoice(
            libraries: libraries ?? [club, other, folder],
            openLibraryID: world.open?.id,
            open: { library in
                world.opened.append(library.name)
                if world.failing.contains(library.name) { return "Sign in to open \(library.name)." }
                world.open = library
                return nil
            },
            current: {
                (world.open.map { .failure(.cannotWrite(libraryName: $0.name)) } ?? .failure(.noLibraryOpen),
                 world.open.map { [AthleteGroup(id: $0.name, name: "Athlete of \($0.name)", videos: [])] } ?? [])
            }
        )
    }

    /// Which library `upload` was taken from — the name the stand-in refusal carries.
    private func reflected(_ choice: UploadLibraryChoice) -> String? {
        if case let .failure(.cannotWrite(name))? = choice.upload { return name }
        return nil
    }

    func testOnlyDrivesAreOffered() {
        let choice = makeChoice(World())
        XCTAssertEqual(choice.options.map(\.name), ["Club Drive", "Other Drive"])
    }

    func testAnOpenDriveIsTheStartingChoiceAndIsNotReopened() async {
        let world = World()
        world.open = other
        let choice = makeChoice(world)
        XCTAssertEqual(choice.selection, other.id)
        XCTAssertEqual(reflected(choice), "Other Drive")
        await choice.start()
        XCTAssertEqual(world.opened, [], "the library already open must not be opened again")
    }

    func testWithNothingOpenTheMostRecentDriveIsChosenAndOpened() async {
        let world = World()
        let choice = makeChoice(world)
        XCTAssertEqual(choice.selection, club.id)
        XCTAssertNil(choice.upload, "nothing can upload until the choice has opened")
        await choice.start()
        XCTAssertEqual(world.opened, ["Club Drive"])
        XCTAssertEqual(reflected(choice), "Club Drive")
        XCTAssertEqual(choice.athletes.map(\.name), ["Athlete of Club Drive"])
        XCTAssertFalse(choice.isOpening)
    }

    /// A folder open in the viewer is left alone: starting on a Drive would
    /// close what the coach is looking at.
    func testAnOpenFolderStartsOnDontUpload() async {
        let world = World()
        world.open = folder
        let choice = makeChoice(world)
        XCTAssertNil(choice.selection)
        await choice.start()
        XCTAssertEqual(world.opened, [])
        XCTAssertNil(choice.upload)
        XCTAssertEqual(choice.athletes.map(\.name), ["Athlete of Snow"], "the folder's roster still suggests names")
    }

    func testNoDrivesMeansDontUpload() async {
        let choice = makeChoice(World(), libraries: [folder])
        XCTAssertNil(choice.selection)
        XCTAssertEqual(choice.options, [])
    }

    func testChoosingAnotherDriveOpensIt() async {
        let world = World()
        world.open = club
        let choice = makeChoice(world)
        await choice.choose(other.id)
        XCTAssertEqual(world.opened, ["Other Drive"])
        XCTAssertEqual(choice.selection, other.id)
        XCTAssertEqual(reflected(choice), "Other Drive")
        XCTAssertEqual(choice.athletes.map(\.name), ["Athlete of Other Drive"])
    }

    func testChoosingDontUploadClearsTheTargetWithoutOpeningAnything() async {
        let world = World()
        world.open = club
        let choice = makeChoice(world)
        await choice.choose(nil)
        XCTAssertNil(choice.selection)
        XCTAssertNil(choice.upload)
        XCTAssertEqual(world.opened, [])
    }

    /// Back to the library that is still open: no second open.
    func testChoosingTheOpenDriveAgainDoesNotReopenIt() async {
        let world = World()
        world.open = club
        let choice = makeChoice(world)
        await choice.choose(nil)
        await choice.choose(club.id)
        XCTAssertEqual(world.opened, [])
        XCTAssertEqual(reflected(choice), "Club Drive")
    }

    func testAFailedOpenIsShownAndLeavesNothingToUploadTo() async {
        let world = World()
        world.open = club
        world.failing = ["Other Drive"]
        let choice = makeChoice(world)
        await choice.choose(other.id)
        XCTAssertEqual(choice.failure, "Sign in to open Other Drive.")
        XCTAssertNil(choice.upload, "a library that did not open cannot be uploaded to")
        XCTAssertEqual(choice.selection, other.id, "the failed choice stays shown beside its reason")
        XCTAssertFalse(choice.isOpening)

        await choice.choose(club.id)
        XCTAssertNil(choice.failure)
        XCTAssertEqual(world.opened, ["Other Drive"], "the club drive never closed, so it is not reopened")
        XCTAssertEqual(reflected(choice), "Club Drive")
    }

    /// The coach changes their mind while a slow open is still running: the
    /// later choice wins, whatever order the opens finish in.
    func testALateFinishingOpenDoesNotOverwriteANewerChoice() async {
        let world = World()
        world.open = club
        var release: CheckedContinuation<Void, Never>?
        let choice = UploadLibraryChoice(
            libraries: [club, other],
            openLibraryID: club.id,
            open: { library in
                await withCheckedContinuation { release = $0 }
                world.open = library
                return nil
            },
            current: {
                (world.open.map { .failure(.cannotWrite(libraryName: $0.name)) } ?? .failure(.noLibraryOpen), [])
            }
        )
        let slow = Task { await choice.choose(other.id) }
        while release == nil { await Task.yield() }
        await choice.choose(nil)
        release?.resume()
        await slow.value
        XCTAssertNil(choice.selection)
        XCTAssertNil(choice.upload)
        XCTAssertFalse(choice.isOpening)
    }
}
