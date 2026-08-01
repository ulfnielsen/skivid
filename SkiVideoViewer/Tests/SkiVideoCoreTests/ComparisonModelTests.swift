import UniformTypeIdentifiers
import XCTest
@testable import SkiVideoCore

@MainActor
final class ComparisonModelTests: XCTestCase {
    private var temporaryDirectory: URL?

    override func tearDown() async throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    private func makeModel() -> ComparisonModel {
        ComparisonModel()
    }

    /// `AVPlayerItem` accepts any URL and reports failure asynchronously, so an
    /// empty file is enough to give a player a `currentItem` — which is all
    /// `hasTwoVideos` and therefore `setSyncPoints()` require. No decodable
    /// media is needed.
    private func makeVideoFile(_ name: String) throws -> URL {
        let root = temporaryDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryDirectory = root
        let url = root.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    /// A model in the synced state, where the three intents the comparison
    /// window binds each produce a distinguishable status. Without sync every
    /// branch reports "Set the sync points first.", which cannot tell
    /// `playSynced` from `seekSynced` from a dropped intent.
    private func makeSyncedModel(input: FakeInputSource) throws -> ComparisonModel {
        let model = ComparisonModel(input: input)
        model.load(try makeVideoFile("left.mp4"), side: .left)
        model.load(try makeVideoFile("right.mp4"), side: .right)
        model.setSyncPoints()
        XCTAssertTrue(model.isSynced, "precondition: the model must be synced")
        return model
    }

    func testDefaultsToSideBySideBlendAtHalfOpacity() {
        let model = makeModel()
        defer { model.close() }

        XCTAssertEqual(model.layout, .sideBySide)
        XCTAssertEqual(model.blend, .blend)
        XCTAssertEqual(model.overlayOpacity, 0.5, accuracy: 0.0001)
    }

    func testTopLayerOpacityFollowsSliderInBlendMode() {
        let model = makeModel()
        defer { model.close() }

        model.blend = .blend
        model.overlayOpacity = 0.25
        XCTAssertEqual(model.topLayerOpacity, 0.25, accuracy: 0.0001)

        model.overlayOpacity = 0.9
        XCTAssertEqual(model.topLayerOpacity, 0.9, accuracy: 0.0001)
    }

    func testTopLayerOpacityIsFullInDifferenceMode() {
        let model = makeModel()
        defer { model.close() }

        model.overlayOpacity = 0.25
        model.blend = .difference
        XCTAssertEqual(model.topLayerOpacity, 1.0, accuracy: 0.0001)

        model.overlayOpacity = 0.0
        XCTAssertEqual(model.topLayerOpacity, 1.0, accuracy: 0.0001)
    }

    /// `OverlayPlayerStack` no longer branches on `blend` for opacity — it
    /// draws whatever `topLayerOpacity` says. So the forced 1.0 of difference
    /// mode must be computed, never latched: leaving difference has to hand the
    /// slider value back, or the overlay stays stuck at full opacity.
    func testLeavingDifferenceModeRestoresTheSliderOpacity() {
        let model = makeModel()
        defer { model.close() }

        model.overlayOpacity = 0.25
        model.blend = .difference
        XCTAssertEqual(model.topLayerOpacity, 1.0, accuracy: 0.0001)

        model.blend = .blend
        XCTAssertEqual(model.topLayerOpacity, 0.25, accuracy: 0.0001)
    }

    func testSwitchingLayoutLeavesBlendAndOpacityUntouched() {
        let model = makeModel()
        defer { model.close() }

        model.overlayOpacity = 0.3
        model.blend = .difference
        model.layout = .overlay

        XCTAssertEqual(model.overlayOpacity, 0.3, accuracy: 0.0001)
        XCTAssertEqual(model.blend, .difference)

        model.layout = .sideBySide
        XCTAssertEqual(model.overlayOpacity, 0.3, accuracy: 0.0001)
        XCTAssertEqual(model.blend, .difference)
    }

    func testLayoutAndBlendTitles() {
        XCTAssertEqual(ComparisonLayout.sideBySide.title, "Side-by-side")
        XCTAssertEqual(ComparisonLayout.overlay.title, "Overlay")
        XCTAssertEqual(OverlayBlend.blend.title, "Blend")
        XCTAssertEqual(OverlayBlend.difference.title, "Difference")
    }

    // MARK: - Intent handling
    //
    // The comparison window's key bindings used to live in an `NSEvent`
    // monitor inside this model. They now arrive as `PlaybackIntent`s from the
    // `PlaybackInputSource` seam; these tests pin the mapping the monitor had.

    /// Deliberately *not* run against a synced model: `playSynced` reaches
    /// `AVPlayer.setRate(_:time:atHostTime:)`, which raises an Objective-C
    /// exception unless the item is `.readyToPlay`, and no decodable media
    /// exists in a unit test. Unsynced, the two branches are still
    /// distinguishable — `playSynced` sets the status, `pauseBoth` leaves it
    /// alone — which is the regression that matters: Space must attempt to
    /// play, not to pause, when both players are stopped.
    func testTogglePlaybackIntentAttemptsSyncedPlaybackRatherThanPausing() {
        let input = FakeInputSource()
        let model = ComparisonModel(input: input)
        defer { model.close() }

        XCTAssertEqual(model.leftPlayer.rate, 0)
        XCTAssertEqual(model.rightPlayer.rate, 0)
        XCTAssertEqual(model.status, "Choose two videos and align them independently.")

        input.emit(.togglePlayback)

        XCTAssertEqual(
            model.status,
            "Set the sync points first.",
            "an unchanged status would mean the intent reached pauseBoth instead"
        )
    }

    func testScrubBeganIntentsSeekBothPlayersOneSecondInTheEmittedDirection() throws {
        let input = FakeInputSource()
        let model = try makeSyncedModel(input: input)
        defer { model.close() }

        input.emit(.scrubBegan(.backward))
        XCTAssertEqual(model.status, "Both moved -1 seconds")

        input.emit(.scrubBegan(.forward))
        XCTAssertEqual(model.status, "Both moved +1 seconds")
    }

    func testScrubEndedIsIgnoredBecauseTheWindowNeverHadHoldToScrub() throws {
        let input = FakeInputSource()
        let model = try makeSyncedModel(input: input)
        defer { model.close() }

        input.emit(.scrubBegan(.forward))
        let statusAfterBegan = model.status

        input.emit(.scrubEnded(.forward, performTap: true))
        XCTAssertEqual(
            model.status,
            statusAfterBegan,
            "a release must not seek a second time"
        )
    }

    func testClipAndAthleteIntentsAreIgnored() throws {
        let input = FakeInputSource()
        let model = try makeSyncedModel(input: input)
        defer { model.close() }

        let statusBefore = model.status
        input.emit(.clip(.next))
        input.emit(.athlete(.previous))
        input.emit(.focusAthleteSearch)
        input.emit(.openFolder)

        XCTAssertEqual(
            model.status,
            statusBefore,
            "the old monitor passed these keys through to the main window"
        )
    }

    func testScrubIntentsDoNotTrapWithNoVideosLoaded() {
        let input = FakeInputSource()
        let model = ComparisonModel(input: input)
        defer { model.close() }

        input.emit(.scrubBegan(.backward))
        input.emit(.scrubBegan(.forward))
        input.emit(.togglePlayback)

        XCTAssertEqual(model.leftTime, 0, accuracy: 0.0001)
        XCTAssertEqual(model.rightTime, 0, accuracy: 0.0001)
        XCTAssertFalse(model.isSynced)
    }

    func testClosingDetachesTheInputSource() throws {
        let input = FakeInputSource()
        let model = try makeSyncedModel(input: input)

        model.close()

        // Equivalent to the `NSEvent.removeMonitor` that `close()` used to do:
        // the window must stop both receiving and swallowing key events.
        XCTAssertFalse(input.isEnabled)
        let statusAfterClose = model.status
        input.emit(.scrubBegan(.forward))
        XCTAssertEqual(model.status, statusAfterClose)
    }

    // MARK: - File selection

    func testChooseVideoLoadsWhatThePickerReturnsIntoTheRequestedSide() async throws {
        let picker = FakeFolderPicker()
        picker.fileToReturn = try makeVideoFile("chosen.mp4")
        let model = ComparisonModel(folderPicker: picker)
        defer { model.close() }

        await model.chooseVideo(side: .right)

        XCTAssertEqual(picker.pickFileCallCount, 1)
        XCTAssertEqual(model.rightName, "chosen.mp4")
        XCTAssertEqual(model.leftName, "Choose left video", "the other side must be untouched")
        XCTAssertEqual(
            picker.lastPickFileType,
            .movie,
            "regression guard: the panel offered movies only"
        )
    }

    func testChooseVideoPassesThePerSidePanelTitleThrough() async throws {
        let picker = FakeFolderPicker()
        picker.fileToReturn = try makeVideoFile("chosen.mp4")
        let model = ComparisonModel(folderPicker: picker)
        defer { model.close() }

        // Regression guard: these titles the user sees must survive routing
        // through the FolderPicker seam.
        await model.chooseVideo(side: .left)
        XCTAssertEqual(picker.lastPickFileTitle, "Choose left comparison video")

        await model.chooseVideo(side: .right)
        XCTAssertEqual(picker.lastPickFileTitle, "Choose right comparison video")
    }

    func testChooseVideoDoesNothingWhenCancelled() async {
        let picker = FakeFolderPicker()
        picker.fileToReturn = nil
        let model = ComparisonModel(folderPicker: picker)
        defer { model.close() }

        await model.chooseVideo(side: .left)

        XCTAssertEqual(picker.pickFileCallCount, 1)
        XCTAssertEqual(model.leftName, "Choose left video")
    }
}
