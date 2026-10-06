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

    // MARK: - Wiring through a real sort

    /// A model whose source is `root` (one clip, as if Photos had delivered
    /// it), ready to tag.
    private func makeSortingModel(
        importer: FakePhotosImporter,
        pipeline: MediaPipeline
    ) throws -> SortingModel {
        let names = root.appendingPathComponent("athletes.txt")
        try "Alfa".write(to: names, atomically: true, encoding: .utf8)
        let model = SortingModel(
            mediaPipeline: pipeline,
            defaultNamesURL: names,
            photosImporter: importer
        )
        model.keepsSourceIntact = true
        model.outputRoot = root.appendingPathComponent("Out", isDirectory: true)
        model.sourcePath = root.path
        model.eventTitle = "Test"
        return model
    }

    private func finishSort(_ model: SortingModel) async throws {
        model.beginSorting()
        model.athleteQuery = "Alfa"
        model.tagCurrentVideo()
        let deadline = Date().addingTimeInterval(20)
        while model.completedResizes < 1, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(model.completedResizes, 1)
    }

    func testFinishingASortCleanlyDiscardsTheScratch() async throws {
        let importer = FakePhotosImporter()
        let model = try makeSortingModel(importer: importer, pipeline: FakeMediaPipeline())

        try await finishSort(model)

        XCTAssertEqual(importer.discardCallCount, 1)
    }

    func testAFailedResizeKeepsTheScratch() async throws {
        let importer = FakePhotosImporter()
        let pipeline = FakeMediaPipeline()
        pipeline.resizeError = CocoaError(.fileWriteUnknown)
        let model = try makeSortingModel(importer: importer, pipeline: pipeline)

        try await finishSort(model)

        XCTAssertEqual(model.failedResizes.count, 1)
        XCTAssertEqual(importer.discardCallCount, 0, "the failed clip's source must survive")
    }

    func testImportIsRefusedWhileResizesAreInFlight() async throws {
        let importer = FakePhotosImporter()
        importer.folderToReturn = root
        let model = try makeSortingModel(
            importer: importer,
            pipeline: SerializationProbePipeline(jobDurationMilliseconds: 400)
        )
        model.beginSorting()
        model.athleteQuery = "Alfa"
        model.tagCurrentVideo()
        XCTAssertEqual(model.queuedResizes, 1)
        XCTAssertEqual(model.completedResizes, 0)

        await model.chooseFromPhotos()

        XCTAssertEqual(importer.importCallCount, 0, "importing would wipe the folder the resize reads")
        XCTAssertNotNil(model.errorMessage)
    }

    func testAFailedImportDoesNotLeaveTheSourceDangling() async {
        let importer = FakePhotosImporter()
        importer.errorToThrow = CocoaError(.fileReadUnknown)
        let model = makeModel(importer)
        model.sourcePath = root.appendingPathComponent("gone").path

        await model.chooseFromPhotos()

        XCTAssertEqual(model.sourcePath, "")
    }
}
