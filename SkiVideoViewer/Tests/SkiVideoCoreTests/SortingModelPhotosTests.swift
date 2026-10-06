import Foundation
import XCTest
@testable import SkiVideoCore

@MainActor
final class SortingModelPhotosTests: XCTestCase {
    private var root: URL!
    private var previousStoreRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("IMG_0001.mov"))
        previousStoreRoot = AthleteRoster.storeRoot
        AthleteRoster.storeRoot = root.appendingPathComponent("AthleteRoster", isDirectory: true)
    }

    override func tearDown() async throws {
        AthleteRoster.storeRoot = previousStoreRoot
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private func makeModel(_ importer: FakePhotosImporter?) -> SortingModel {
        SortingModel(
            mediaPipeline: FakeMediaPipeline(),
            input: FakeInputSource(),
            folderPicker: FakeFolderPicker(),
            defaultNamesURL: nil,
            photosImporter: importer
        )
    }

    func testNoImporterMeansNoPhotosButton() {
        XCTAssertFalse(makeModel(nil).canChooseFromPhotos)
        XCTAssertTrue(makeModel(FakePhotosImporter()).canChooseFromPhotos)
    }

    func testChoosingFromPhotosMakesTheImportedFolderTheSource() async {
        let importer = FakePhotosImporter()
        importer.folderToReturn = root
        let model = makeModel(importer)

        await model.chooseFromPhotos()

        XCTAssertEqual(model.sourcePath, root.path)
    }

    func testCancellingLeavesTheSourceAlone() async {
        let importer = FakePhotosImporter()
        let model = makeModel(importer)
        model.sourcePath = "/somewhere"

        await model.chooseFromPhotos()

        XCTAssertEqual(model.sourcePath, "/somewhere")
        XCTAssertNil(model.errorMessage)
    }

    func testAFailedImportIsReported() async {
        let importer = FakePhotosImporter()
        importer.errorToThrow = CocoaError(.fileReadNoSuchFile)
        let model = makeModel(importer)

        await model.chooseFromPhotos()

        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.sourcePath, "")
    }

    func testScratchIsDiscardedWhenNothingIsResizing() {
        let importer = FakePhotosImporter()
        makeModel(importer).discardPhotosScratchIfIdle()
        XCTAssertEqual(importer.discardCallCount, 1)
    }
}
