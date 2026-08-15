import Foundation
import XCTest
@testable import SkiVideoCore

/// Pins the on-disk layout a sorting session produces **today**, before the
/// output stage is extracted behind a `ClipPublisher` seam (Task 3 of
/// sort-on-ipad-from-a-card). If that extraction changes a path component, the
/// filename, or the collision error, one of these tests must fail.
///
/// The pipeline is `FakeMediaPipeline` (from `FakeSeams.swift`, already used
/// elsewhere in this target), so nothing here depends on AVFoundation. The
/// resize itself runs on a background `OperationQueue` — see
/// `SortingModel.enqueueResize` — so these tests only assert on the move of
/// the original, which `tagCurrentVideo()` performs synchronously before it
/// returns. Coverage for the path handed to the resize queue already exists
/// in `SortingModelResizeQueueTests.testPipelineReceivesOrganizedAndResizedPathsPerClip`,
/// which can afford to wait for the background job to finish; this file does
/// not duplicate that wait.
@MainActor
final class SortingModelPublisherTests: XCTestCase {
    private var root: URL!
    private var namesFile: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sorting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        namesFile = root.appendingPathComponent("athletes.txt")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        namesFile = nil
    }

    /// The layout: `organized/<event>/<athlete>/<original filename>`, and the
    /// original clip is moved out of the flat source folder, not copied.
    ///
    /// Fails if `SortingModel.tagCurrentVideo()` renames the `"organized"`
    /// segment, changes how `SortingLibrary.eventFolder` or
    /// `SortingLibrary.athleteFolderName` build their path components, drops
    /// the original filename, or copies instead of moving the source clip.
    func testASortedClipLandsInTheEventAthleteLayout() throws {
        let source = try makeSource(named: "C0001.MP4")
        try write(names: ["Ada Example"])
        let model = makeModel()
        model.sourcePath = root.path
        model.eventTitle = "Brunni"
        model.beginSorting()
        XCTAssertNil(model.errorMessage, "setup must succeed before the layout assertions mean anything")

        model.athleteQuery = "Ada Example"
        model.tagCurrentVideo()

        XCTAssertNil(model.errorMessage, "tagging must succeed before the layout assertions mean anything")
        let event = try SortingLibrary.eventFolder(date: model.eventDate, title: "Brunni")
        let athlete = try SortingLibrary.athleteFolderName("Ada Example")
        let organized = root
            .appendingPathComponent("organized/\(event)/\(athlete)/C0001.MP4")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: organized.path),
            "expected the original at \(organized.path); the layout is what this test pins"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: source.path),
            "the original is moved, not copied — that is today's behaviour"
        )
        XCTAssertEqual(
            model.queuedResizes, 1,
            "the move enqueues exactly one resize job — this happens synchronously, before the background queue runs it"
        )
    }

    /// The other half of the layout the happy path can't reach: when the
    /// destination is already occupied, tagging must leave the source clip
    /// exactly where it was rather than silently overwriting, and must
    /// surface `SortingError.outputExists`'s message to the operator.
    ///
    /// Fails if a future extraction swallows the collision, overwrites the
    /// existing file at the destination, or changes the error's wording.
    func testATaggingCollisionLeavesTheOriginalInPlaceAndReportsTheError() throws {
        let source = try makeSource(named: "C0001.MP4")
        try write(names: ["Ada Example"])
        let model = makeModel()
        model.sourcePath = root.path
        model.eventTitle = "Brunni"
        model.beginSorting()

        let event = try SortingLibrary.eventFolder(date: model.eventDate, title: "Brunni")
        let athlete = try SortingLibrary.athleteFolderName("Ada Example")
        let organized = root
            .appendingPathComponent("organized/\(event)/\(athlete)/C0001.MP4")
        try FileManager.default.createDirectory(
            at: organized.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let collidingContent = Data("already here".utf8)
        try collidingContent.write(to: organized)

        model.athleteQuery = "Ada Example"
        model.tagCurrentVideo()

        XCTAssertEqual(
            model.errorMessage,
            "A file already exists at \(organized.path). It was not overwritten.",
            "the collision error's wording is part of what this pins"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: source.path),
            "a collision must leave the source clip where it was, not consume it"
        )
        XCTAssertEqual(
            try Data(contentsOf: organized), collidingContent,
            "the pre-existing file at the destination must not be overwritten"
        )
        XCTAssertEqual(model.queuedResizes, 0, "a collision must not enqueue a resize job")
    }

    private func makeSource(named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 0, count: 16).write(to: url)
        return url
    }

    private func write(names: [String]) throws {
        try names.joined(separator: "\n").write(to: namesFile, atomically: true, encoding: .utf8)
    }

    /// `athleteNames` is `@Published public private(set)`, so a test cannot
    /// assign it directly. Writing the candidate name to the file backing
    /// `defaultNamesURL` and letting `init` call `reloadNames()` is the same
    /// technique `SortingFlowTests` uses, and it exercises the real
    /// `tagCurrentVideo()` path rather than `addNewAthleteAndTag()`'s extra
    /// persistence step.
    private func makeModel() -> SortingModel {
        SortingModel(mediaPipeline: FakeMediaPipeline(), defaultNamesURL: namesFile)
    }
}
