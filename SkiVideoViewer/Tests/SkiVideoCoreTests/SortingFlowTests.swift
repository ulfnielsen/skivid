import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import SkiVideoCore

/// End-to-end cover for the file-system half of the sorting flow, plus the two
/// seams `SortingModel` gained when it moved into the core: the folder picker
/// that replaced its two `NSOpenPanel`s, and the input source that replaced its
/// `NSEvent` monitor.
///
/// Everything here runs against a throwaway temp directory. The media pipeline
/// is faked, so the clips never have to be real video — the real ffmpeg
/// pipeline is covered by `FFmpegMediaPipelineTests` in the app test target.
@MainActor
final class SortingFlowTests: XCTestCase {
    private var root: URL!
    private var namesFile: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["C0001.mp4", "C0002.mp4"] {
            try Data(name.utf8).write(to: root.appendingPathComponent(name))
        }
        namesFile = root.appendingPathComponent("athletes.txt")
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    private func writeNames(_ names: [String]) throws {
        try names.joined(separator: "\n").write(to: namesFile, atomically: true, encoding: .utf8)
    }

    private func makeModel(
        input: FakeInputSource? = nil,
        folderPicker: FakeFolderPicker? = nil,
        defaultNamesURL: URL? = nil
    ) -> SortingModel {
        SortingModel(
            mediaPipeline: FakeMediaPipeline(),
            input: input ?? FakeInputSource(),
            folderPicker: folderPicker ?? FakeFolderPicker(),
            defaultNamesURL: defaultNamesURL ?? namesFile
        )
    }

    private var organizedDirectory: URL {
        root.appendingPathComponent("organized", isDirectory: true)
    }

    private func organizedVideos() -> [URL] {
        FileManager.default
            .enumerator(at: organizedDirectory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .sorted { $0.path < $1.path } ?? []
    }

    /// The clip physically leaves the flat source folder and lands under
    /// `organized/<event>/<athlete>/`. The resize-queue tests assert the paths
    /// handed to the pipeline; this asserts the move actually happened on disk.
    func testTaggingMovesTheClipIntoTheOrganizedLibrary() throws {
        try writeNames(["Idun", "Nora"])
        let model = makeModel()
        model.sourcePath = root.path
        model.eventTitle = "Test"
        model.beginSorting()

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isSorting)
        XCTAssertEqual(model.rawVideos.count, 2)

        model.athleteQuery = "Idun"
        model.tagCurrentVideo()

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.rawVideos.count, 1, "the tagged clip leaves the queue")
        XCTAssertEqual(model.queuedResizes, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("C0001.mp4").path),
            "the clip must not be left behind in the flat source folder"
        )

        let moved = organizedVideos()
        XCTAssertEqual(moved.count, 1)
        let path = try XCTUnwrap(moved.first).path
        XCTAssertTrue(path.hasSuffix("/Idun/C0001.mp4"), "expected an Idun folder, got \(path)")
        XCTAssertTrue(path.contains("_Test/"), "the event folder carries the event title, got \(path)")
        model.stopPlayback()
    }

    /// "Ing" matches both Ingrid and Ingvild, so tagging must refuse to guess
    /// and nothing may move.
    func testAmbiguousAthleteMovesNothing() throws {
        try writeNames(["Ingrid", "Ingvild"])
        let model = makeModel()
        model.sourcePath = root.path
        model.eventTitle = "Test"
        model.beginSorting()
        XCTAssertTrue(model.isSorting)

        model.athleteQuery = "Ing"
        XCTAssertEqual(model.matchingAthletes.count, 2, "the query must genuinely be ambiguous")
        XCTAssertNil(model.resolvedAthlete)

        model.tagCurrentVideo()

        XCTAssertEqual(model.rawVideos.count, 2, "nothing may move on an ambiguous tag")
        XCTAssertEqual(model.queuedResizes, 0)
        XCTAssertEqual(model.status, "Keep typing until one athlete matches, or add a new athlete.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: organizedDirectory.path))
        model.stopPlayback()
    }

    /// The source-folder panel is now the `FolderPicker` seam. Its title is the
    /// one the `NSOpenPanel` carried.
    func testChooseSourceDirectoryUsesTheFolderPicker() async throws {
        try writeNames(["Idun"])
        let picker = FakeFolderPicker()
        picker.folderToReturn = root
        let model = makeModel(folderPicker: picker)

        await model.chooseSourceDirectory()

        XCTAssertEqual(picker.pickFolderCallCount, 1)
        XCTAssertEqual(picker.lastPickFolderTitle, "Choose folder containing raw videos")
        XCTAssertEqual(picker.lastPickFolderConfirmLabel, "Choose")
        XCTAssertEqual(model.sourcePath, root.path)
    }

    /// A cancelled panel must leave the field untouched.
    func testCancellingTheSourcePanelKeepsTheExistingPath() async throws {
        try writeNames(["Idun"])
        let picker = FakeFolderPicker()
        picker.folderToReturn = nil
        let model = makeModel(folderPicker: picker)
        model.sourcePath = "/previously/chosen"

        await model.chooseSourceDirectory()

        XCTAssertEqual(picker.pickFolderCallCount, 1)
        XCTAssertEqual(model.sourcePath, "/previously/chosen")
    }

    /// The names panel is the same seam, restricted to plain text, and picking
    /// a file reloads the autocomplete list.
    func testChooseNamesFileUsesThePickerAndReloadsNames() async throws {
        let other = root.appendingPathComponent("other-names.txt")
        try "Nora\nIdun\n".write(to: other, atomically: true, encoding: .utf8)
        try writeNames(["Ingrid"])
        let picker = FakeFolderPicker()
        picker.fileToReturn = other
        let model = makeModel(folderPicker: picker)
        XCTAssertEqual(model.athleteNames, ["Ingrid"])

        await model.chooseNamesFile()

        XCTAssertEqual(picker.pickFileCallCount, 1)
        XCTAssertEqual(picker.lastPickFileType, .plainText)
        XCTAssertEqual(picker.lastPickFileTitle, "Choose athlete-name list")
        XCTAssertEqual(model.namesPath, other.path)
        XCTAssertEqual(model.athleteNames, ["Nora", "Idun"])
    }

    /// The `~/Ski/athletes.txt` default is injected now. A path that does not
    /// exist must leave the field empty rather than pointing at a missing file.
    func testDefaultNamesURLIsUsedOnlyWhenItExists() throws {
        try writeNames(["Idun"])
        XCTAssertEqual(makeModel().namesPath, namesFile.path)

        let missing = root.appendingPathComponent("no-such-list.txt")
        XCTAssertEqual(makeModel(defaultNamesURL: missing).namesPath, "")
        XCTAssertEqual(
            SortingModel(mediaPipeline: FakeMediaPipeline()).namesPath,
            "",
            "no default supplied means no names file"
        )
    }

    /// The `NSEvent` monitor was installed by `beginSorting` and removed by
    /// `stopPlayback`. The input source must follow exactly that lifecycle, or
    /// the sorting window swallows the main window's arrow keys.
    func testKeyboardInputIsEnabledOnlyWhileSorting() throws {
        try writeNames(["Idun"])
        let input = FakeInputSource()
        let model = makeModel(input: input)
        XCTAssertFalse(input.isEnabled, "the setup screen never intercepted keys")

        model.sourcePath = root.path
        model.eventTitle = "Test"
        model.beginSorting()
        XCTAssertTrue(input.isEnabled)

        model.stopPlayback()
        XCTAssertFalse(input.isEnabled)
    }
}
