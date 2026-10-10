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
/// `SortingModel.enqueueResize` — so most of these tests only assert on the
/// move of the original, which `tagCurrentVideo()` performs synchronously
/// before it returns, and do not wait for the background job to finish.
/// `testAReadOnlySessionWritesNothingToTheSource` is the exception: what it
/// pins can only be observed after the background job runs, so it polls
/// `completedResizes` the way `SortingModelResizeQueueTests` does. Coverage
/// for the path handed to the resize queue in the non-read-only case already
/// exists in
/// `SortingModelResizeQueueTests.testPipelineReceivesOrganizedAndResizedPathsPerClip`.
@MainActor
final class SortingModelPublisherTests: XCTestCase {
    private var root: URL!
    private var namesFile: URL!

    private var previousAthleteRosterStoreRoot: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sorting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        namesFile = root.appendingPathComponent("athletes.txt")
        // `testAReadOnlySessionWritesNothingToTheSource` calls
        // `addNewAthleteAndTag()` with `keepsSourceIntact = true`, which now
        // routes through `AthleteRoster.addLocally` — this must not write into
        // the developer's real Application Support. See `AthleteRosterTests`
        // for the same guard's rationale.
        previousAthleteRosterStoreRoot = AthleteRoster.storeRoot
        AthleteRoster.storeRoot = root.appendingPathComponent("AthleteRoster", isDirectory: true)
    }

    override func tearDownWithError() throws {
        AthleteRoster.storeRoot = previousAthleteRosterStoreRoot
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

    /// A read-only session must write its resize somewhere that is not the
    /// card, and must never write an athlete tag into the card's original.
    ///
    /// The directory-listing comparison alone can only prove the first half:
    /// a real pipeline's `writeMetadata` uses `replaceItemAt`, which swaps a
    /// file's contents without changing what `contentsOfDirectory` reports,
    /// so a metadata write into the card's original would pass that check
    /// undetected. Deleting `enqueueResize`'s `if !skipSourceMetadata` gate
    /// was verified by hand to leave every test in this file green before
    /// this assertion existed. `FakeMediaPipeline.metadataCalls`
    /// (`Tests/SkiVideoCoreTests/FakeSeams.swift:134`) is the part of the
    /// fake that actually sees the call regardless of what it did to disk,
    /// so asserting it is empty is what closes the gap — and
    /// `resizeCalls.first?.source` pins that the resize itself reads the
    /// clip on the card in place, per `ReadOnlySourcePublisher.prepare`,
    /// rather than a moved copy.
    func testAReadOnlySessionWritesNothingToTheSource() async throws {
        let card = root.appendingPathComponent("DCIM")
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        let clip = card.appendingPathComponent("C0001.MP4")
        try Data(repeating: 0, count: 16).write(to: clip)
        let before = try FileManager.default.contentsOfDirectory(atPath: card.path)
        let output = root.appendingPathComponent("app-storage")
        let pipeline = FakeMediaPipeline()

        let model = await MainActor.run { () -> SortingModel in
            let model = SortingModel(mediaPipeline: pipeline)
            model.sourcePath = card.path
            model.eventTitle = "Brunni"
            model.keepsSourceIntact = true
            model.outputRoot = output
            model.beginSorting()
            return model
        }
        await MainActor.run {
            model.athleteQuery = "Ada Example"
            model.addNewAthleteAndTag()
        }
        // The resize itself runs on the background operation queue — see
        // `SortingModel.enqueueResize` — so `metadataCalls`/`resizeCalls`
        // are not populated yet the instant `addNewAthleteAndTag` returns.
        // Drained the same way `SortingModelResizeQueueTests` does.
        try await waitForResizes(model, count: 1)

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: card.path), before,
            "a read-only session must leave the card exactly as it found it"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: output.path),
            "the resize target directory should have been created under the output root"
        )
        XCTAssertTrue(
            pipeline.metadataCalls.isEmpty,
            "a read-only session must never write athlete metadata into the source"
        )
        // `resolvingSymlinksInPath()` on both sides: `FileManager
        // .contentsOfDirectory` returns paths through `/private/var`, while
        // `clip` was built from `FileManager.default.temporaryDirectory`
        // directly, which on this OS version does not include `/private` —
        // an unrelated quirk this test must not mistake for a moved file.
        XCTAssertEqual(
            pipeline.resizeCalls.first?.source.resolvingSymlinksInPath(),
            clip.resolvingSymlinksInPath(),
            "the resize must read the clip on the card in place, not a moved copy"
        )
    }

    /// The upload tray reads the sorted output back from disk, so it needs to
    /// know where that is: the output root for a read-only session — known
    /// before any tagging, which is what lets a tray reopen after the app was
    /// killed — and the source's `organized_resize` for a Mac session, which
    /// is only known once a source has been chosen and sorting began.
    func testTheUploadRootIsWhereTheResizesLand() throws {
        try makeSource(named: "C0001.MP4")
        let readOnly = makeModel()
        readOnly.keepsSourceIntact = true
        readOnly.outputRoot = root.appendingPathComponent("app-storage")
        XCTAssertEqual(readOnly.uploadRoot, readOnly.outputRoot)

        let inPlace = makeModel()
        XCTAssertNil(inPlace.uploadRoot)
        inPlace.sourcePath = root.path
        inPlace.eventTitle = "Brunni"
        inPlace.beginSorting()
        XCTAssertEqual(inPlace.uploadRoot, root.appendingPathComponent("organized_resize", isDirectory: true))
    }

    /// The finished-tagging tray reads only this session's event folder.
    func testTheSessionFolderIsTheEventUnderTheUploadRoot() throws {
        try makeSource(named: "C0001.MP4")
        let model = makeModel()
        model.keepsSourceIntact = true
        model.outputRoot = root.appendingPathComponent("app-storage")
        XCTAssertNil(model.sessionOutputDirectory, "no event until sorting begins")
        model.sourcePath = root.path
        model.eventTitle = "Brunni"
        model.beginSorting()

        let event = try SortingLibrary.eventFolder(date: model.eventDate, title: "Brunni")
        XCTAssertEqual(model.sessionOutputDirectory,
                       model.outputRoot.appendingPathComponent(event, isDirectory: true))
    }

    func testResizesAreSettledOnlyOnceTaggingIsDoneAndTheQueueIsEmpty() async throws {
        try makeSource(named: "C0001.MP4")
        try write(names: ["Ada Example"])
        let model = makeModel()
        XCTAssertFalse(model.resizesAreSettled)
        model.sourcePath = root.path
        model.eventTitle = "Brunni"
        model.beginSorting()
        XCTAssertFalse(model.resizesAreSettled)

        model.athleteQuery = "Ada Example"
        model.tagCurrentVideo()
        try await waitForResizes(model, count: 1)

        XCTAssertTrue(model.resizesAreSettled)
    }

    /// Polls `completedResizes` rather than depending on ordering with the
    /// background `OperationQueue`, exactly as `SortingModelResizeQueueTests
    /// .waitForResizes` does — duplicated here rather than shared because
    /// that one lives in a different `XCTestCase`.
    private func waitForResizes(_ model: SortingModel, count: Int) async throws {
        let deadline = Date().addingTimeInterval(20)
        while model.completedResizes < count {
            if Date() > deadline {
                XCTFail("timed out with \(model.completedResizes) of \(count) resizes done")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @discardableResult
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
