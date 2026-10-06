import AVFoundation
import XCTest
@testable import SkiVideoCore

@MainActor
final class UploadDestinationTests: XCTestCase {
    private func drive(_ convention: FolderConvention? = nil) -> Library {
        Library(name: "Club", kind: .drive(rootID: "root-1"), convention: convention)
    }

    func testEventThenAthleteWalksEventFirst() throws {
        let destination = try UploadDestination.resolve(
            library: drive(.eventThenAthlete), indexConvention: nil)
        XCTAssertEqual(destination.rootID, "root-1")
        XCTAssertEqual(destination.folderNames(event: "2026-01-14_Brunni", athlete: "Ada"),
                       ["2026-01-14_Brunni", "Ada"])
    }

    func testAthleteThenEventWalksAthleteFirst() throws {
        let destination = try UploadDestination.resolve(
            library: drive(.athleteThenEvent), indexConvention: nil)
        XCTAssertEqual(destination.folderNames(event: "2026-01-14_Brunni", athlete: "Ada"),
                       ["Ada", "2026-01-14_Brunni"])
    }

    func testTheLibrarysOwnConventionBeatsTheIndexs() throws {
        let destination = try UploadDestination.resolve(
            library: drive(.eventThenAthlete), indexConvention: .athleteThenEvent)
        XCTAssertEqual(destination.convention, .eventThenAthlete)
    }

    func testNilConventionFallsBackToTheIndexs() throws {
        let destination = try UploadDestination.resolve(
            library: drive(nil), indexConvention: .athleteThenEvent)
        XCTAssertEqual(destination.convention, .athleteThenEvent)
    }

    func testNoConventionAnywhereRefusesRatherThanGuessing() {
        XCTAssertThrowsError(try UploadDestination.resolve(library: drive(nil), indexConvention: nil)) {
            XCTAssertEqual($0 as? UploadRefusal, .layoutUnknown(libraryName: "Club"))
        }
    }

    func testNoLibraryRefuses() {
        XCTAssertThrowsError(try UploadDestination.resolve(library: nil, indexConvention: .athleteThenEvent)) {
            XCTAssertEqual($0 as? UploadRefusal, .noLibraryOpen)
        }
    }

    func testALocalFolderRefuses() {
        let folder = Library(name: "Season", kind: .folder(bookmark: Data()), convention: .eventThenAthlete)
        XCTAssertThrowsError(try UploadDestination.resolve(library: folder, indexConvention: .eventThenAthlete)) {
            XCTAssertEqual($0 as? UploadRefusal, .libraryIsAFolder(libraryName: "Season"))
        }
    }

    func testRefusalsReadAsSentencesForACoach() {
        for refusal in [UploadRefusal.noLibraryOpen, .libraryIsAFolder(libraryName: "Season"),
                        .layoutUnknown(libraryName: "Club")] {
            XCTAssertFalse((refusal.errorDescription ?? "").isEmpty)
        }
        XCTAssertTrue(UploadRefusal.libraryIsAFolder(libraryName: "Season").errorDescription!.contains("Season"))
    }

    // MARK: reading the sorted directory back

    func testClipsReadBackFromTheLayoutReadOnlySourcePublisherWrites() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sorted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let publisher = ReadOnlySourcePublisher(resizedRoot: root)
        // Written by the real publisher, then the resize's output stood in for.
        var written: [(String, String, String)] = [
            ("2026-01-14_Brunni", "Ada", "IMG_1.MOV"),
            ("2026-01-14_Brunni", "Bo-Per", "IMG_2.MOV"),
            ("2026-02-02_Zürs", "Ada", "IMG_3.MOV"),
        ]
        for (event, athlete, name) in written {
            let targets = try publisher.prepare(
                source: URL(fileURLWithPath: "/scratch/\(name)"), athlete: athlete, event: event)
            try Data([1]).write(to: targets.resizeDestination)
        }
        try Data([1]).write(to: root.appendingPathComponent(".DS_Store"))

        let clips = try SortedOutput.clips(in: root)

        written.sort { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }
        XCTAssertEqual(clips.map { [$0.event, $0.athlete, $0.file.lastPathComponent] },
                       written.map { [$0.0, $0.1, $0.2] })
        XCTAssertTrue(clips.allSatisfy { FileManager.default.fileExists(atPath: $0.file.path) })
    }

    func testAMissingOrEmptyDirectoryHasNoClips() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID())")
        XCTAssertEqual(try SortedOutput.clips(in: missing), [])
    }

    // MARK: the open library, through ViewerModel

    private func openDrive(_ path: [String], convention: FolderConvention?) async throws -> ViewerModel {
        var model: ViewerModel!
        try await withTemporaryIndexStore {
            let (m, provider, cache, _) = try remoteModelWithDownloader(
                files: [remoteFile("1", "run.mov", path)])
            await m.signIn(with: provider)
            _ = await m.chooseRoot(RemoteFolder(id: "drive-1", name: "Club"),
                                   cache: cache, convention: convention)
            model = m
        }
        return model
    }

    func testNothingOpenRefusesBeforeAnyTagging() {
        let model = ViewerModel(input: FakeInputSource(), folderPicker: FakeFolderPicker(),
                                oauthPresenter: FakeOAuthPresenter())
        XCTAssertThrowsError(try model.uploadDestination()) {
            XCTAssertEqual($0 as? UploadRefusal, .noLibraryOpen)
        }
    }

    func testAnOpenDriveWithAChosenLayoutResolves() async throws {
        let model = try await openDrive(["Anna", "Slalom"], convention: .eventThenAthlete)
        XCTAssertEqual(try model.uploadDestination().convention, .eventThenAthlete)
        XCTAssertEqual(try model.uploadDestination().rootID, "drive-1")
    }

    func testAnOpenDriveWhoseFoldersSayWhichWayRoundResolvesFromTheIndex() async throws {
        let model = try await openDrive(["Anna", "2026-02-25_Hoch-Ybrig"], convention: nil)
        XCTAssertNil(model.openLibrary?.convention)
        XCTAssertEqual(try model.uploadDestination().convention, .athleteThenEvent)
    }

    /// The index shows athlete-then-event here only because opening falls back
    /// to it; that guess must not decide where footage is filed.
    func testAnOpenDriveWhoseLayoutWasOnlyDefaultedRefuses() async throws {
        let model = try await openDrive(["Anna", "Slalom"], convention: nil)
        XCTAssertThrowsError(try model.uploadDestination()) {
            XCTAssertEqual($0 as? UploadRefusal, .layoutUnknown(libraryName: "Club"))
        }
    }

    func testHiddenStagingPartialsAndNonVideosAreNotListed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sorted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("2026-01-14_Brunni/Ada")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["good.MOV", ".resize-ABC.MOV", "notes.txt", "clip.mov.part"] {
            try Data([1]).write(to: folder.appendingPathComponent(name))
        }
        XCTAssertEqual(try SortedOutput.clips(in: root).map { $0.file.lastPathComponent }, ["good.MOV"])
    }

    /// Real pipeline: an unreadable source fails after the destination folder
    /// exists; nothing may be left in it, final or staging.
    func testAFailedResizeLeavesNothingBehind() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sorted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bogus = root.appendingPathComponent("bogus.mov")
        try Data("not a video".utf8).write(to: bogus)
        let destination = root.appendingPathComponent("out/Event/Ada/bogus.mov")
        do {
            try await AVFoundationMediaPipeline().resize(source: bogus, destination: destination, athlete: "Ada")
            XCTFail("expected failure")
        } catch {}
        let left = try FileManager.default.contentsOfDirectory(
            atPath: destination.deletingLastPathComponent().path)
        XCTAssertEqual(left, [])
        XCTAssertEqual(try SortedOutput.clips(in: root.appendingPathComponent("out")), [])
    }

    func testASuccessfulResizeLeavesOnlyTheFinalFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sorted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeRealVideoFile(in: root, name: "a.mov", seconds: 1, fps: 30, width: 640, height: 360)
        let destination = root.appendingPathComponent("out/Event/Ada/a.mov")
        try await AVFoundationMediaPipeline().resize(source: source, destination: destination, athlete: "Ada")
        let hidden = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        XCTAssertEqual(hidden, ["a.mov"])
        XCTAssertEqual(try SortedOutput.clips(in: root.appendingPathComponent("out")).count, 1)
    }
}
