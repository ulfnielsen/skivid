import AVFoundation
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
    /// Two clips loaded, no sync points yet — the "aligning" state.
    ///
    /// The loaded items matter for any assertion on `currentTime()`: a player
    /// with no `currentItem` reports an *indefinite* time, which reads back as
    /// NaN. With an item, even an undecodable one, seeks land and
    /// `currentTime()` reports them — the published `leftTime`/`rightTime` are
    /// the ones that stay 0, because their periodic observers never fire.
    private func makeAlignedModel(input: FakeInputSource? = nil) throws -> ComparisonModel {
        let model = ComparisonModel(input: input)
        model.load(try makeVideoFile("left.mp4"), side: .left)
        model.load(try makeVideoFile("right.mp4"), side: .right)
        XCTAssertFalse(model.isSynced, "precondition: the model must still be aligning")
        return model
    }

    private func makeSyncedModel(input: FakeInputSource? = nil) throws -> ComparisonModel {
        let model = try makeAlignedModel(input: input)
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

    /// `OverlayPlayerStack` re-applies the "difference mode forces full
    /// opacity" rule itself, as defence in depth — but the model is still
    /// where the rule lives. So the forced 1.0 must be computed here, never
    /// latched: leaving difference has to hand the slider value back, or the
    /// overlay stays stuck at full opacity.
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
    /// exists in a unit test.
    ///
    /// The regression this pins is unchanged — Space must attempt to *play*,
    /// not to pause, when both players are stopped — but the contract it
    /// asserts is the new one: the key goes through `applyTransport`, so while
    /// aligning it plays the targeted clip instead of answering "Set the sync
    /// points first." A rate of 0 on both players would mean it reached
    /// `pauseBoth`, which is the failure that matters.
    func testTogglePlaybackIntentAttemptsPlaybackRatherThanPausing() {
        let input = FakeInputSource()
        let model = ComparisonModel(input: input)
        defer { model.close() }

        XCTAssertEqual(model.leftPlayer.rate, 0)
        XCTAssertEqual(model.rightPlayer.rate, 0)
        XCTAssertEqual(model.target, .left)

        input.emit(.togglePlayback)

        XCTAssertEqual(model.leftPlayer.rate, 1, "Space must attempt to play the targeted clip")
        XCTAssertEqual(model.rightPlayer.rate, 0, "the untargeted clip must stay put")
    }

    /// The keys used to call `playSynced`/`seekSynced` directly while the
    /// buttons went through `target`, so with Left targeted while aligning the
    /// ▶ button played the left clip and Space said "Set the sync points
    /// first." Both now route through `applyTransport`.
    func testKeyboardFollowsTheTargetJustAsTheButtonsDo() {
        let input = FakeInputSource()
        let model = ComparisonModel(input: input)
        defer { model.close() }

        model.target = .right
        input.emit(.togglePlayback)

        XCTAssertEqual(model.rightPlayer.rate, 1, "Space must follow the target")
        XCTAssertEqual(model.leftPlayer.rate, 0)
    }

    func testSeekKeysFollowTheTargetWhileAligning() throws {
        let input = FakeInputSource()
        let model = try makeAlignedModel(input: input)
        defer { model.close() }

        model.target = .right
        input.emit(.seek(.forward))

        XCTAssertEqual(model.rightPlayer.currentTime().seconds, 1, accuracy: 0.01,
                       "the targeted clip must move")
        XCTAssertEqual(model.leftPlayer.currentTime().seconds, 0, accuracy: 0.01,
                       "the untargeted clip must not")
    }

    func testSeekIntentsMoveBothPlayersOneSecondInTheEmittedDirection() throws {
        let input = FakeInputSource()
        let model = try makeSyncedModel(input: input)
        defer { model.close() }

        input.emit(.seek(.backward))
        XCTAssertEqual(model.status, "Both moved -1 seconds")

        input.emit(.seek(.forward))
        XCTAssertEqual(model.status, "Both moved +1 seconds")
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

    func testSeekIntentsDoNotTrapWithNoVideosLoaded() {
        let input = FakeInputSource()
        let model = ComparisonModel(input: input)
        defer { model.close() }

        input.emit(.seek(.backward))
        input.emit(.seek(.forward))
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
        input.emit(.seek(.forward))
        XCTAssertEqual(model.status, statusAfterClose)
    }

    // MARK: - Slow motion

    func testSlowMotionRunsTheTargetedSideWhileAligning() throws {
        let input = FakeInputSource()
        let model = try makeAlignedModel(input: input)
        defer { model.close() }
        model.target = .left

        input.emit(.slowMotionBegan(.forward))

        XCTAssertEqual(model.leftPlayer.rate, 0.35, accuracy: 0.001)
        XCTAssertEqual(model.rightPlayer.rate, 0, "the untargeted side must stay put")
    }

    func testSlowMotionRunsBothSidesWhenBothAreTargeted() throws {
        let input = FakeInputSource()
        let model = try makeSyncedModel(input: input)
        defer { model.close() }
        model.target = .both

        input.emit(.slowMotionBegan(.forward))

        XCTAssertEqual(model.leftPlayer.rate, 0.35, accuracy: 0.001)
        XCTAssertEqual(model.rightPlayer.rate, 0.35, accuracy: 0.001)
    }

    /// A per-side hold on a locked pair drives the pair, matching
    /// `playIndividual` — running one clip alone would desync exactly what the
    /// operator just aligned.
    func testSlowMotionOnOneSideOfASyncedPairDrivesBoth() throws {
        let input = FakeInputSource()
        let model = try makeSyncedModel(input: input)
        defer { model.close() }
        model.target = .left

        input.emit(.slowMotionBegan(.forward))

        XCTAssertEqual(model.leftPlayer.rate, 0.35, accuracy: 0.001)
        XCTAssertEqual(model.rightPlayer.rate, 0.35, accuracy: 0.001)
    }

    func testEndingSlowMotionStopsThePlayers() throws {
        let input = FakeInputSource()
        let model = try makeAlignedModel(input: input)
        defer { model.close() }
        model.target = .right

        input.emit(.slowMotionBegan(.forward))
        input.emit(.slowMotionEnded)

        XCTAssertEqual(model.rightPlayer.rate, 0)
    }

    /// The cross-direction press — ⌘→ held, then ⌘← without releasing it.
    /// `SlowMotionHold.begin` refuses the second one silently, so the status
    /// must be guarded here or it announces "Slow backward" over a clip still
    /// running forward. Same defect the viewer's `.slowMotionBegan` case names.
    func testARefusedSecondHoldChangesNeitherRateNorStatus() throws {
        let input = FakeInputSource()
        let model = try makeAlignedModel(input: input)
        defer { model.close() }
        model.target = .left

        input.emit(.slowMotionBegan(.forward))
        XCTAssertEqual(model.status, "Slow forward")

        input.emit(.slowMotionBegan(.backward))

        XCTAssertEqual(model.leftPlayer.rate, 0.35, accuracy: 0.001,
                       "the running direction must not change")
        XCTAssertEqual(model.status, "Slow forward",
                       "a refused begin must not word the status after a hold it did not start")
    }

    /// The clip is **playing** before the hold on purpose, and the whole test
    /// turns on it. `close()` pauses the players itself, so from a standing
    /// start this assertion passes with `endSlowMotion()` deleted outright — it
    /// would pin nothing. With a pre-hold rate of 1× the two orderings separate:
    /// ending first restores 1× and the pause that follows wins, leaving 0;
    /// pausing first lets the restore run last and leaves the clip playing at 1×
    /// in a window that has just been closed. Mutation-verified in both
    /// directions.
    func testClosingEndsAnActiveHold() throws {
        let input = FakeInputSource()
        let model = try makeAlignedModel(input: input)
        model.target = .left
        model.leftPlayer.playImmediately(atRate: 1)
        XCTAssertEqual(model.leftPlayer.rate, 1, "premise: the clip must be playing before the hold")

        input.emit(.slowMotionBegan(.forward))
        XCTAssertEqual(model.leftPlayer.rate, 0.35, accuracy: 0.001, "premise: the hold must be running")
        model.close()

        XCTAssertEqual(model.leftPlayer.rate, 0, "a closed window must not be left playing")
        XCTAssertFalse(model.isHoldingSlowMotion, "the hold must be ended, not abandoned")
    }

    /// The other teardown path, with the same pre-hold rate for the same
    /// reason. `pauseBoth` is what every seek, sync and alignment change goes
    /// through, and a hold left running under it would restart the pair the
    /// moment the restore fired.
    func testPausingBothEndsAnActiveHold() throws {
        let input = FakeInputSource()
        let model = try makeSyncedModel(input: input)
        defer { model.close() }
        model.target = .both
        model.leftPlayer.playImmediately(atRate: 1)
        model.rightPlayer.playImmediately(atRate: 1)

        input.emit(.slowMotionBegan(.forward))
        XCTAssertEqual(model.leftPlayer.rate, 0.35, accuracy: 0.001, "premise: the hold must be running")
        model.pauseBoth()

        XCTAssertEqual(model.leftPlayer.rate, 0)
        XCTAssertEqual(model.rightPlayer.rate, 0)
        XCTAssertFalse(model.isHoldingSlowMotion, "the hold must be ended, not abandoned")
    }

    /// A transport action taken *during* a hold must end it, or
    /// `SlowMotionHold.isActive` stays true and refuses every later hold — the
    /// operator's ⌘→ silently stops working for the rest of the session.
    /// `pauseBoth` cannot cover this: while aligning, `toggleIndividual` never
    /// reaches it.
    func testATransportActionEndsTheHoldSoALaterOneCanStart() throws {
        let input = FakeInputSource()
        let model = try makeAlignedModel(input: input)
        defer { model.close() }
        model.target = .left

        input.emit(.slowMotionBegan(.forward))
        model.applyTransport(.playPause)
        // Space exits the hold rather than steering it, and the clip it hands
        // back was stopped before the hold — so the toggle starts it, exactly
        // as `ViewerModel.togglePlayback` does out of a hold.
        XCTAssertEqual(model.leftPlayer.rate, 1, "Space plays the clip the hold handed back")

        input.emit(.slowMotionBegan(.forward))

        XCTAssertEqual(model.leftPlayer.rate, 0.35, accuracy: 0.001,
                       "a hold left active refuses every later one")
    }

    /// The reverse fallback's shape, which is the worst of the two: it pauses
    /// the clips and steps them on a timer, so both rates read 0 and the
    /// transport reads that as "stopped" and plays. Without the teardown the
    /// hold is still live, and the key-up that arrives a moment later restores
    /// its captured pre-hold rate of 0 — stopping the pair dead right after the
    /// operator asked it to play.
    func testPlayingOutOfAHoldSurvivesTheKeyRelease() throws {
        let input = FakeInputSource()
        let model = try makeAlignedModel(input: input)
        defer { model.close() }
        model.target = .left
        XCTAssertNotEqual(model.leftPlayer.currentItem?.canPlayReverse, true,
                          "premise: this fixture takes the timer fallback")

        input.emit(.slowMotionBegan(.backward))
        XCTAssertEqual(model.leftPlayer.rate, 0, "premise: the fallback leaves the clip paused")

        model.applyTransport(.playPause)
        XCTAssertEqual(model.leftPlayer.rate, 1, "the operator asked for playback")

        input.emit(.slowMotionEnded)

        XCTAssertEqual(model.leftPlayer.rate, 1,
                       "the release must not stop what the operator just started")
    }

    /// Releasing the key must not leave the screen describing a hold that is
    /// over. The hold is transient in both directions — `end()` puts the
    /// players back at the rate they were running at — so the sentence that
    /// described them before it is true again.
    func testEndingAHoldRestoresTheStatusItReplaced() throws {
        let input = FakeInputSource()
        let model = try makeAlignedModel(input: input)
        defer { model.close() }
        model.target = .left
        let before = model.status

        input.emit(.slowMotionBegan(.forward))
        XCTAssertEqual(model.status, "Slow forward")

        input.emit(.slowMotionEnded)

        XCTAssertEqual(model.status, before,
                       "the stopped clips must not sit under \"Slow forward\"")
    }

    /// Swapping a clip mid-hold. The clip is **playing** at 1× before the hold
    /// for the same reason `testClosingEndsAnActiveHold` plays: `load` pauses
    /// the player itself, so from a standing start every ordering leaves 0 and
    /// the assertion would pin nothing. With a pre-hold rate of 1× the two
    /// separate — a hold carried across the load restores that 1× onto the clip
    /// that has just arrived, so the operator picks a new clip and it starts
    /// playing by itself under "Align both videos, then set the sync points."
    ///
    /// Aligning, not synced, on purpose: `clearSync` only pauses when the pair
    /// was locked, so the synced path escapes this by accident and proves
    /// nothing about `load`.
    func testLoadingANewClipEndsAnActiveHold() throws {
        let input = FakeInputSource()
        let model = try makeAlignedModel(input: input)
        defer { model.close() }
        model.target = .left
        model.leftPlayer.playImmediately(atRate: 1)
        XCTAssertEqual(model.leftPlayer.rate, 1, "premise: the clip must be playing before the hold")

        input.emit(.slowMotionBegan(.forward))
        XCTAssertEqual(model.leftPlayer.rate, 0.35, accuracy: 0.001, "premise: the hold must be running")
        model.load(try makeVideoFile("another-left.mp4"), side: .left)
        XCTAssertFalse(model.isHoldingSlowMotion, "the hold must not survive the clip it was started on")

        input.emit(.slowMotionEnded)

        XCTAssertEqual(model.leftPlayer.rate, 0,
                       "the release must not start the clip that just replaced the held one")
    }

    /// An empty window. `SlowMotionHold.begin` is the only copy of the refusal
    /// rule now, and this is the half the comparison window used to be missing:
    /// ⌘→ with nothing loaded wrote "Slow forward", marked a hold active over
    /// item-less players and, on the reverse fallback, spun an 80ms timer
    /// seeking nothing.
    ///
    /// The status is the discriminating assertion. `leftPlayer.rate` is 0 either
    /// way — a player with no item cannot play whatever it is asked — so a test
    /// written against rates alone passes with the refusal deleted.
    func testAHoldRefusedForLackOfPlayersWritesNoStatus() {
        let input = FakeInputSource()
        let model = ComparisonModel(input: input)
        defer { model.close() }
        let before = model.status

        input.emit(.slowMotionBegan(.forward))

        XCTAssertEqual(model.status, before, "an empty window must not announce a hold")
        XCTAssertFalse(model.isHoldingSlowMotion,
                       "a hold over players with no items is not a hold")
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

    // MARK: - Transport target
    //
    // One control bar drives either side or both, selected by `target`. The
    // model already routes every per-side call through `isSynced`
    // (`toggleIndividual`, `playIndividual`, `seek`, `scrub` each check it
    // first), so `target` is the only thing that was missing.

    func testTargetDefaultsToLeftWhileAligning() {
        let model = makeModel()
        defer { model.close() }

        XCTAssertFalse(model.isSynced)
        XCTAssertEqual(model.target, .left)
    }

    func testBothIsNotOfferedUntilSyncPointsAreSet() {
        let model = makeModel()
        defer { model.close() }

        XCTAssertEqual(model.availableTargets, [.left, .right],
                       "Both cannot work before sync: playSynced refuses")
    }

    func testTargetSwitchesToBothOnSync() throws {
        let model = try makeSyncedModel()
        defer { model.close() }

        XCTAssertTrue(model.isSynced)
        XCTAssertEqual(model.target, .both)
        XCTAssertEqual(model.availableTargets, [.both, .left, .right])
    }

    func testClearingSyncReturnsTargetToASide() throws {
        let model = try makeSyncedModel()
        defer { model.close() }

        model.removeSync()

        XCTAssertFalse(model.isSynced)
        XCTAssertNotEqual(model.target, .both,
                          "Both must not remain selected once it cannot work")
        XCTAssertEqual(model.availableTargets, [.left, .right])
    }

    /// `removeSync()` is not the only way sync drops: `clearSync` does it too,
    /// from `load` and from any per-side nudge. That path must demote `target`
    /// as well, or the picker keeps a selection `availableTargets` no longer
    /// offers.
    func testLoadingAClipAlsoDemotesTargetFromBoth() throws {
        let model = try makeSyncedModel()
        defer { model.close() }

        XCTAssertEqual(model.target, .both)

        model.load(try makeVideoFile("replacement.mp4"), side: .left)

        XCTAssertFalse(model.isSynced)
        XCTAssertNotEqual(model.target, .both)
        XCTAssertTrue(model.availableTargets.contains(model.target),
                      "target must always be one of availableTargets")
    }

    /// `.slow` is the action asserted on because it is the only one whose
    /// observable effect names a side: unsynced, `playIndividual` writes
    /// "Playing left/right at …×". The seek actions route through
    /// `seek(_:by:)`, whose unsynced branch writes the side-agnostic
    /// "Alignment changed…" — asserting `status.contains("right")` after a
    /// targeted seek would fail, not pass. The player rates pin the routing a
    /// second way, so a mis-wired `.right` case cannot slip through on the
    /// status string alone.
    func testTransportRoutesToTheTargetedSide() {
        let model = makeModel()
        defer { model.close() }

        model.target = .right
        model.applyTransport(.slow)

        XCTAssertTrue(
            model.status.lowercased().contains("right"),
            "expected a right-side status, got \(model.status)"
        )
        XCTAssertEqual(model.rightPlayer.rate, 0.25, "the targeted side must move")
        XCTAssertEqual(model.leftPlayer.rate, 0, "the untargeted side must not")
    }

    func testTransportTargetingLeftLeavesTheRightSideAlone() {
        let model = makeModel()
        defer { model.close() }

        model.target = .left
        model.applyTransport(.slow)

        XCTAssertTrue(
            model.status.lowercased().contains("left"),
            "expected a left-side status, got \(model.status)"
        )
        XCTAssertEqual(model.leftPlayer.rate, 0.25)
        XCTAssertEqual(model.rightPlayer.rate, 0)
    }

    /// Seek routing cannot be told apart per side without decodable media, but
    /// side-versus-both can: the unsynced per-side branch writes "Alignment
    /// changed…" while `seekSynced` writes "Set the sync points first."
    func testSeekActionsRouteThroughThePerSideSeekWhenASideIsTargeted() {
        let model = makeModel()
        defer { model.close() }

        model.target = .right
        model.applyTransport(.back5)

        XCTAssertEqual(
            model.status,
            "Alignment changed. Set sync points again when ready.",
            "a 'Set the sync points first.' status would mean it reached seekSynced"
        )
    }

    func testTransportRoutesToBothWhenSynced() throws {
        let model = try makeSyncedModel()
        defer { model.close() }

        XCTAssertEqual(model.target, .both)

        model.applyTransport(.back5)
        XCTAssertEqual(model.status, "Both moved -5 seconds")

        model.applyTransport(.forward1)
        XCTAssertEqual(model.status, "Both moved +1 seconds")
    }

    func testTargetTitles() {
        XCTAssertEqual(ComparisonTarget.both.title, "Both")
        XCTAssertEqual(ComparisonTarget.left.title, "Left")
        XCTAssertEqual(ComparisonTarget.right.title, "Right")
    }

    func testTransportActionIsCaseIterableInButtonOrder() {
        XCTAssertEqual(TransportAction.allCases,
                       [.back5, .back1, .playPause, .forward1, .forward5, .slow])
    }

    // MARK: - The target invariant
    //
    // `target` is writable so a Picker can bind to it, which means anything can
    // assign `both`. A selection absent from `availableTargets` renders as no
    // selection at all, so the setter has to refuse it.

    func testSelectingBothWhileAligningIsRefused() {
        let model = makeModel()
        defer { model.close() }

        model.target = .both

        XCTAssertNotEqual(model.target, .both,
                          "Both cannot work before sync, so it must not stick")
        XCTAssertTrue(model.availableTargets.contains(model.target))
    }

    func testTargetAlwaysStaysWithinAvailableTargets() throws {
        let model = try makeSyncedModel()
        defer { model.close() }

        for candidate in ComparisonTarget.allCases {
            model.target = candidate
            XCTAssertTrue(model.availableTargets.contains(model.target),
                          "\(candidate) left target outside availableTargets")
        }

        model.removeSync()

        for candidate in ComparisonTarget.allCases {
            model.target = candidate
            XCTAssertTrue(model.availableTargets.contains(model.target),
                          "\(candidate) left target outside availableTargets while aligning")
        }
    }

    // MARK: - Per-action routing
    //
    // Mutation-checked: routing playPause to the other side, or any seek action
    // to seekSynced, fails at least one assertion below.

    func testPlayPauseTargetingLeftPlaysOnlyTheLeftClip() {
        let model = makeModel()
        defer { model.close() }

        model.target = .left
        model.applyTransport(.playPause)

        XCTAssertEqual(model.leftPlayer.rate, 1)
        XCTAssertEqual(model.rightPlayer.rate, 0, "the other clip must not start")
    }

    func testPlayPauseTargetingRightPlaysOnlyTheRightClip() {
        let model = makeModel()
        defer { model.close() }

        model.target = .right
        model.applyTransport(.playPause)

        XCTAssertEqual(model.rightPlayer.rate, 1)
        XCTAssertEqual(model.leftPlayer.rate, 0, "the other clip must not start")
    }

    /// Every seek action, not just `.back5`: routing any one of them to
    /// `seekSynced` would write "Set the sync points first." instead.
    func testEverySeekActionRoutesPerSideWhileAligning() throws {
        let expected: [(TransportAction, Double)] = [
            (.back5, -5), (.back1, -1), (.forward1, 1), (.forward5, 5),
        ]

        for (action, offset) in expected {
            let model = try makeAlignedModel()
            defer { model.close() }

            model.target = .right
            model.applyTransport(action)

            XCTAssertEqual(
                model.status,
                "Alignment changed. Set sync points again when ready.",
                "\(action) reached seekSynced instead of the per-side seek"
            )
            XCTAssertEqual(model.rightPlayer.currentTime().seconds, max(0, offset), accuracy: 0.01,
                           "\(action) moved the targeted clip to the wrong place")
            XCTAssertEqual(model.leftPlayer.currentTime().seconds, 0, accuracy: 0.01,
                           "\(action) disturbed the untargeted clip")
        }
    }

    // MARK: - Demotion follows the last-touched side

    func testDemotionFollowsTheLastTouchedSide() throws {
        let model = try makeSyncedModel()
        defer { model.close() }

        // makeSyncedModel loads left then right, so right was touched last.
        model.removeSync()

        XCTAssertEqual(model.target, .right,
                       "snapping to Left after the user last worked the right pane reads as a bug")
    }

    func testNudgingASideMakesItTheDemotionLanding() throws {
        let model = try makeSyncedModel()
        defer { model.close() }

        model.target = .left
        model.applyTransport(.forward1)
        model.removeSync()

        XCTAssertEqual(model.target, .left)
    }

    /// The reported scenario, verbatim: select Right, align it by *dragging*
    /// rather than tapping, sync, clear sync — and land back on Left. The
    /// scrubber is the only route to an absolute seek (`TransportAction` has
    /// no such case), so this user never went through `applyTransport`, which
    /// was one of only two places `lastTouchedSide` was written.
    ///
    /// Now double-covered: the picker write records the side too, so this test
    /// passes if *either* fix is present. `testEveryPerSideEntryPointRecords…`
    /// below is what actually pins `scrub`.
    func testScrubbingTheSelectedSideMakesItTheDemotionLanding() throws {
        let model = try makeAlignedModel()
        defer { model.close() }

        model.target = .right
        model.scrub(.right, to: 5)
        model.setSyncPoints()
        XCTAssertEqual(model.target, .both, "precondition: syncing promotes to Both")

        model.removeSync()

        XCTAssertEqual(model.target, .right,
                       "aligning the right clip by dragging must still land on Right")
    }

    /// Selecting a side in the picker is the clearest statement of preference
    /// there is, and on its own it used to record nothing at all.
    ///
    /// Loaded right-then-left so the stale landing side is Left and choosing
    /// Right is a real change — assigning the value it already holds would
    /// prove nothing.
    func testSelectingASideMakesItTheDemotionLandingWithoutAnyOtherAction() throws {
        let model = ComparisonModel()
        defer { model.close() }
        model.load(try makeVideoFile("right.mp4"), side: .right)
        model.load(try makeVideoFile("left.mp4"), side: .left)

        model.target = .right
        model.setSyncPoints()
        model.removeSync()

        XCTAssertEqual(model.target, .right,
                       "the side the user picked must survive a sync/unsync round trip")
    }

    /// The counterpart the naive fix gets wrong. While targeting `both` the
    /// scrubber shows the common timeline and drags it through
    /// `scrub(.left, to:)`, because there is no paired overload. Recording
    /// that as a touch on Left would reintroduce the same bug for a user who
    /// had chosen Right.
    func testDraggingTheCommonTimelineWhileTargetingBothDoesNotStealTheLandingSide() throws {
        let model = try makeAlignedModel()
        defer { model.close() }

        model.target = .right
        model.setSyncPoints()
        XCTAssertEqual(model.target, .both, "precondition: syncing promotes to Both")

        // What ComparisonScrubber does when the target is `both`.
        model.scrub(.left, to: 7)

        model.removeSync()

        XCTAssertEqual(model.target, .right,
                       "the common timeline names no side; the user's choice of Right must stand")
    }

    /// The remaining per-side entry points, so the rule cannot be re-broken one
    /// method at a time.
    func testEveryPerSideEntryPointRecordsTheLandingSide() throws {
        let calls: [(name: String, apply: (ComparisonModel) -> Void)] = [
            ("scrub", { $0.scrub(.left, to: 3) }),
            ("seek(by:)", { $0.seek(.left, by: 3) }),
            ("seek(to:)", { $0.seek(.left, to: 3) }),
            ("nudge", { $0.nudge(.left, by: 3) }),
            ("toggleIndividual", { $0.toggleIndividual(.left) }),
            ("playIndividual", { $0.playIndividual(.left, rate: 0.25) }),
        ]

        for call in calls {
            // makeAlignedModel loads left then right, so the stale landing
            // side is Right. Nothing here touches `target`, so each call is
            // the only thing that can move the landing to Left — which is what
            // makes this sensitive to removing `noteTouched` from any one
            // method.
            let model = try makeAlignedModel()
            defer { model.close() }

            call.apply(model)
            model.setSyncPoints()
            model.removeSync()

            XCTAssertEqual(model.target, .left,
                           "\(call.name) left lastTouchedSide stale")
        }
    }

    /// `nudge` needs its own case. In the table above it is called while
    /// aligning, where it delegates to `seek(_:by:)` — which records the side
    /// itself, so the table cannot tell whether `nudge` does. The path where
    /// `nudge` is the only recorder is the synced one, reached with a side
    /// other than the current target.
    func testNudgingASideOtherThanTheTargetRecordsIt() throws {
        let model = try makeSyncedModel()
        defer { model.close() }

        model.target = .left
        model.nudge(.right, by: 3)
        // Back to the paired transport, so that clearing sync actually has a
        // `both` to demote from — `removeSync` only relands the target when it
        // is `both`. Selecting `both` records no side, so the landing is still
        // whatever `nudge` left behind.
        model.target = .both
        model.removeSync()

        XCTAssertEqual(model.target, .right,
                       "nudging the right clip must make Right the landing side")
    }

    // MARK: - Nudging one side while the pair is locked
    //
    // The correction affordance: with a side targeted while synced, a seek
    // moves that clip *relative to* the other and carries its sync point along,
    // so the pair stays locked at the corrected offset.

    /// Playback stays paired while synced even with a side targeted — running
    /// one clip alone would desync exactly what the user just aligned.
    ///
    /// Only the *pause* direction is reachable in a unit test. Playing routes
    /// through `playSynced` → `AVPlayer.setRate(_:time:atHostTime:)`, which
    /// raises unless the item is `.readyToPlay`, so it would abort the suite
    /// rather than fail. Starting the players directly with
    /// `playImmediately(atRate:)` sidesteps that and still exercises the branch
    /// that matters: `toggleIndividual` must reach `pauseBoth`, not pause one
    /// side.
    func testPlayPauseStaysPairedWhileSyncedEvenWithASideTargeted() throws {
        let model = try makeSyncedModel()
        defer { model.close() }

        model.leftPlayer.playImmediately(atRate: 1)
        model.rightPlayer.playImmediately(atRate: 1)
        XCTAssertEqual(model.leftPlayer.rate, 1, "precondition: both clips running")
        XCTAssertEqual(model.rightPlayer.rate, 1, "precondition: both clips running")

        model.target = .left
        model.applyTransport(.playPause)

        XCTAssertEqual(model.leftPlayer.rate, 0)
        XCTAssertEqual(model.rightPlayer.rate, 0,
                       "pausing one clip alone would desync the locked pair")
        XCTAssertEqual(model.status, "Paused together")
    }

    func testNudgeMovesOnlyTheTargetedClip() throws {
        let model = try makeSyncedModel()
        defer { model.close() }

        model.target = .left
        model.applyTransport(.forward5)

        XCTAssertEqual(model.leftPlayer.currentTime().seconds, 5, accuracy: 0.01)
        XCTAssertEqual(model.rightPlayer.currentTime().seconds, 0, accuracy: 0.01,
                       "a nudge corrects one clip against the other; the other must not move")
        XCTAssertTrue(model.status.lowercased().contains("left"),
                      "the status must name the nudged side, got \(model.status)")
        XCTAssertTrue(model.isSynced, "a nudge corrects the alignment, it does not drop it")
    }

    func testNudgeCarriesTheSyncPointSoTheCorrectionSurvivesAReturn() throws {
        let model = try makeSyncedModel()
        defer { model.close() }

        model.target = .left
        model.applyTransport(.forward5)

        XCTAssertEqual(model.leftSyncPoint.seconds, 5, accuracy: 0.01,
                       "the sync point must follow the clip it names")
        XCTAssertEqual(model.rightSyncPoint.seconds, 0, accuracy: 0.01)

        // Move the locked pair away, then come back.
        model.target = .both
        model.applyTransport(.forward1)
        XCTAssertEqual(model.leftPlayer.currentTime().seconds, 6, accuracy: 0.01)
        XCTAssertEqual(model.rightPlayer.currentTime().seconds, 1, accuracy: 0.01)

        model.returnToSyncPoints()

        XCTAssertEqual(model.leftPlayer.currentTime().seconds, 5, accuracy: 0.01,
                       "returned to the original alignment instead of the corrected one")
        XCTAssertEqual(model.rightPlayer.currentTime().seconds, 0, accuracy: 0.01)
    }

    /// The pair must stay locked at the *new* offset: a paired scrub derives
    /// its offset from the two sync points, so it has to follow the correction.
    ///
    /// `target` goes back to `both` before the drag because that is now the
    /// only state in which a drag is a paired one — with a side targeted the
    /// bar corrects that clip instead, which is
    /// `testScrubbingWithASideTargetedLeavesTheOtherClipWhereItIs` below. The
    /// combination this used to test (targeting Right while dragging the left
    /// clip's timeline) is one `ComparisonScrubber` cannot produce: it passes
    /// `target.scrubbedSide`.
    func testNudgeRetargetsTheOffsetTheLockedPairKeeps() throws {
        let model = try makeSyncedModel()
        defer { model.close() }

        model.target = .right
        model.applyTransport(.forward5)

        model.target = .both
        model.scrub(.left, to: 10)

        XCTAssertEqual(model.leftPlayer.currentTime().seconds, 10, accuracy: 0.01)
        XCTAssertEqual(model.rightPlayer.currentTime().seconds, 15, accuracy: 0.01,
                       "scrubbing together must honour the corrected 5s offset")
    }

    func testNudgeWhileAligningIsAnOrdinaryPerSideSeek() throws {
        let model = try makeAlignedModel()
        defer { model.close() }

        model.nudge(.right, by: 3)

        XCTAssertEqual(model.rightPlayer.currentTime().seconds, 3, accuracy: 0.01)
        XCTAssertEqual(model.leftPlayer.currentTime().seconds, 0, accuracy: 0.01)
        XCTAssertEqual(model.leftSyncPoint, .zero, "there is no alignment to correct yet")
        XCTAssertEqual(model.rightSyncPoint, .zero)
    }

    /// A nudge that runs into the start of the clip must not drift the sync
    /// point past where the clip can actually go, or the pair silently loses
    /// the offset the user set.
    func testNudgeClampedAtTheStartDoesNotDriftTheSyncPoint() throws {
        let model = try makeSyncedModel()
        defer { model.close() }

        model.target = .left
        model.applyTransport(.back5)

        XCTAssertEqual(model.leftPlayer.currentTime().seconds, 0, accuracy: 0.01,
                       "cannot seek before the start")
        XCTAssertEqual(model.leftSyncPoint.seconds, 0, accuracy: 0.01,
                       "the sync point must move by the distance travelled, not the distance asked for")
    }

    // MARK: - Correcting the start by dragging the bar
    //
    // Reported from use: "I can't adjust the start now, which will often be
    // needed." Once synced, a drag moved *both* clips whatever the target said,
    // so the only way to move one clip against the other was the 1s and 5s
    // arrows — and a run start needs frame-level adjustment. The bar is the
    // only control with that resolution.

    /// The reported fix. With a side targeted, dragging must correct *that*
    /// clip against the other and leave the other alone — the same meaning the
    /// transport arrows already gave the target picker.
    func testScrubbingWithASideTargetedLeavesTheOtherClipWhereItIs() throws {
        let model = try makeSyncedModel()
        defer { model.close() }
        // Somewhere other than zero, so "the right clip did not move" is a
        // claim about the right clip rather than about a fresh model.
        model.target = .both
        model.scrub(.left, to: 6)
        XCTAssertEqual(model.rightPlayer.currentTime().seconds, 6, accuracy: 0.01,
                       "precondition: the paired drag must have moved both clips")

        model.target = .left
        model.scrub(.left, to: 8.32)

        XCTAssertEqual(model.leftPlayer.currentTime().seconds, 8.32, accuracy: 0.01,
                       "the targeted clip must land on the time under the thumb")
        XCTAssertEqual(model.rightPlayer.currentTime().seconds, 6, accuracy: 0.01,
                       "correcting one clip against the other must not move the other")
        XCTAssertTrue(model.isSynced, "a correction adjusts the alignment, it does not drop it")
    }

    /// And the correction has to be durable: the sync point carries with the
    /// clip, exactly as a nudge's does, or `returnToSyncPoints()` would come
    /// back to the alignment being corrected.
    func testScrubbingWithASideTargetedCarriesThatSidesSyncPoint() throws {
        let model = try makeSyncedModel()
        defer { model.close() }

        model.target = .left
        model.scrub(.left, to: 2.5)

        XCTAssertEqual(model.leftSyncPoint.seconds, 2.5, accuracy: 0.01,
                       "the sync point must follow the clip it names")
        XCTAssertEqual(model.rightSyncPoint.seconds, 0, accuracy: 0.01,
                       "the untouched side's sync point must not move")

        model.target = .both
        model.applyTransport(.forward1)
        model.returnToSyncPoints()

        XCTAssertEqual(model.leftPlayer.currentTime().seconds, 2.5, accuracy: 0.01,
                       "returned to the alignment being corrected instead of the corrected one")
        XCTAssertEqual(model.rightPlayer.currentTime().seconds, 0, accuracy: 0.01)
    }

    /// The behaviour the change must not silently take away: with `both`
    /// targeted a drag still moves the locked pair, offset preserved.
    ///
    /// The pair is given a non-zero offset first. With both sync points at zero
    /// "moved together" and "moved one" are indistinguishable at the right
    /// clip's playhead, and this test is precisely about telling them apart.
    func testScrubbingWithBothTargetedStillMovesThePairAtTheSyncOffset() throws {
        let model = try makeSyncedModel()
        defer { model.close() }
        model.target = .right
        model.applyTransport(.forward5)
        XCTAssertEqual(model.rightSyncPoint.seconds - model.leftSyncPoint.seconds, 5, accuracy: 0.01,
                       "precondition: the pair must keep a 5s offset")

        model.target = .both
        model.scrub(.left, to: 9)

        XCTAssertEqual(model.leftPlayer.currentTime().seconds, 9, accuracy: 0.01)
        XCTAssertEqual(model.rightPlayer.currentTime().seconds, 14, accuracy: 0.01,
                       "a paired drag must carry the other clip at the sync offset")
        XCTAssertEqual(model.leftSyncPoint.seconds, 0, accuracy: 0.01,
                       "moving the pair is not a correction; the sync points must not move")
        XCTAssertEqual(model.rightSyncPoint.seconds, 5, accuracy: 0.01)
    }

    /// While aligning there is no pair to correct against, so a drag with a
    /// side targeted is the plain per-side seek it always was — and in
    /// particular it must not drop the alignment or touch a sync point.
    func testScrubbingWhileAligningStillMovesOnlyTheDraggedClip() throws {
        let model = try makeAlignedModel()
        defer { model.close() }

        model.target = .left
        model.scrub(.left, to: 4)

        XCTAssertEqual(model.leftPlayer.currentTime().seconds, 4, accuracy: 0.01)
        XCTAssertEqual(model.rightPlayer.currentTime().seconds, 0, accuracy: 0.01,
                       "the clips are independent while aligning")
        XCTAssertFalse(model.isSynced)
        XCTAssertEqual(model.leftSyncPoint, .zero, "there is no alignment to correct yet")
        XCTAssertEqual(model.rightSyncPoint, .zero)
    }

    /// A correction dragged past the start of the clip clamps, and the sync
    /// point moves by the distance **actually travelled** — the subtlety
    /// `nudge` records and this route has to inherit rather than reimplement.
    ///
    /// Asking for −10 from 3s travels −3, not −13. The difference is visible on
    /// the *right* sync point: a sync point moved by the requested amount lands
    /// at −10, and `normalizeSyncPoints()` then slides the pair +10 to bring it
    /// back into range, dragging the untouched right sync point to 10 and
    /// putting the pair 10s out of the alignment the operator set.
    func testACorrectionClampedAtTheStartMovesTheSyncPointByWhatItTravelled() throws {
        let model = try makeSyncedModel()
        defer { model.close() }
        model.target = .left
        model.scrub(.left, to: 3)
        XCTAssertEqual(model.leftSyncPoint.seconds, 3, accuracy: 0.01, "precondition: the correction landed at 3s")

        model.scrub(.left, to: -10)

        XCTAssertEqual(model.leftPlayer.currentTime().seconds, 0, accuracy: 0.01,
                       "cannot seek before the start")
        XCTAssertEqual(model.leftSyncPoint.seconds, 0, accuracy: 0.01,
                       "the sync point must move by the 3s travelled, not the 13s asked for")
        XCTAssertEqual(model.rightSyncPoint.seconds, 0, accuracy: 0.01,
                       """
                       the untouched sync point moved, so the pair was slid back into range \
                       from a sync point driven below zero — the offset the operator set is gone
                       """)
    }

    /// The chip must not go on crediting "detected starts" once the operator
    /// has moved one, and the sentence has to stay inside the width the chip is
    /// pinned to.
    func testAppliedCorrectedStartsAreAttributedAsCorrected() throws {
        let model = try makeAlignedModel()
        defer { model.close() }

        model.applySync(left: 16.84, right: 4.42, corrected: true)
        let corrected = model.status

        XCTAssertTrue(corrected.contains("corrected"),
                      "a corrected start must not be credited to the detector, got \(corrected)")
        XCTAssertLessThanOrEqual(corrected.count, 83,
                                 "the status chip is pinned at 83 characters; this one is \(corrected.count)")

        model.applySync(left: 16.84, right: 4.42)

        XCTAssertTrue(model.status.contains("detected"),
                      "an uncorrected sync must still say where it came from, got \(model.status)")
    }

    // MARK: - Applying a sync point that came from somewhere else
    //
    // `applySync` takes two plain times. The model deliberately does not learn
    // where they came from — only that they did not come from the operator, so
    // the status chip can attribute them.
    //
    // `makeAlignedModel()` stands in for the brief's `loadedPair()`: this file
    // has no such helper, and two zero-byte clips are what every other test
    // here uses to get a loaded pair.

    func testApplySyncSetsBothSidesAndRecordsItsOrigin() throws {
        let model = try makeAlignedModel()
        defer { model.close() }

        model.applySync(left: 18.64, right: 4.42)

        XCTAssertTrue(model.isSynced)
        XCTAssertEqual(model.leftSyncPoint.seconds, 18.64, accuracy: 0.05)
        XCTAssertEqual(model.rightSyncPoint.seconds, 4.42, accuracy: 0.05)
        guard case let .detected(left, right) = model.syncOrigin else {
            return XCTFail("expected detected, got \(model.syncOrigin)")
        }
        XCTAssertEqual(left, 18.64, accuracy: 1e-9)
        XCTAssertEqual(right, 4.42, accuracy: 1e-9)
    }

    func testAManualSyncAfterADetectedOneTakesTheOrigin() throws {
        let model = try makeAlignedModel()
        defer { model.close() }
        model.applySync(left: 18.64, right: 4.42)
        XCTAssertNotEqual(model.syncOrigin, .manual, "precondition: the sync must be attributed to detection")

        model.setSyncPoints()

        XCTAssertEqual(model.syncOrigin, .manual)
    }

    func testClearingSyncResetsTheOrigin() throws {
        let model = try makeAlignedModel()
        defer { model.close() }
        model.applySync(left: 18.64, right: 4.42)
        XCTAssertNotEqual(model.syncOrigin, .manual, "precondition: the sync must be attributed to detection")

        model.removeSync()

        XCTAssertFalse(model.isSynced)
        XCTAssertEqual(model.syncOrigin, .manual)
    }

    /// Every other route that drops sync goes through `clearSync`, so loading a
    /// clip must reset the attribution too — otherwise the chip keeps crediting
    /// a detection that no longer applies to the clip on screen.
    func testLoadingAClipAlsoResetsTheOrigin() throws {
        let model = try makeAlignedModel()
        defer { model.close() }
        model.applySync(left: 18.64, right: 4.42)

        model.load(try makeVideoFile("replacement.mp4"), side: .left)

        XCTAssertFalse(model.isSynced)
        XCTAssertEqual(model.syncOrigin, .manual)
    }

    /// `alreadyRunning` yields a time at or before the first frame, and a
    /// detected start can in principle exceed a clip's duration. Neither should
    /// leave the pair half-synced.
    ///
    /// The upper bound is untestable here — a zero-byte fixture reports its
    /// duration as NaN, so every clip is effectively infinite. See
    /// `ComparisonBoundsTests.testApplySyncClampsBothEndsIntoRealClips` for
    /// that half, on real media.
    func testApplySyncClampsATimeBeyondTheClipRatherThanRefusing() throws {
        let model = try makeAlignedModel()
        defer { model.close() }

        model.applySync(left: -3.0, right: 9_999.0)

        XCTAssertTrue(model.isSynced)
        XCTAssertGreaterThanOrEqual(model.leftSyncPoint.seconds, 0)
    }

    /// A detected sync needs both clips, exactly as a manual one does: syncing
    /// off a single loaded clip would lock the pair to a sync point on a player
    /// with no item, whose time is NaN.
    func testApplySyncWithOnlyOneClipLoadedDoesNotSync() throws {
        let model = ComparisonModel()
        defer { model.close() }
        model.load(try makeVideoFile("left.mp4"), side: .left)

        model.applySync(left: 3, right: 4)

        XCTAssertFalse(model.isSynced)
        XCTAssertEqual(model.syncOrigin, .manual,
                       "a refused sync must not be attributed to a detection")
    }

    func testSyncOriginStartsManual() {
        let model = makeModel()
        defer { model.close() }

        XCTAssertEqual(model.syncOrigin, .manual)
    }

    /// The status is the only thing on screen that can attribute a sync — a
    /// detected sync is applied before the operator has seen it, and
    /// `syncOrigin` itself is not rendered anywhere.
    func testADetectedSyncSaysSoInTheStatus() throws {
        let model = try makeAlignedModel()
        defer { model.close() }

        model.applySync(left: 18.64, right: 4.42)

        XCTAssertTrue(
            model.status.lowercased().contains("detected"),
            "a detected sync must be attributable from the status; got: \(model.status)"
        )
    }

    /// The converse: a manual sync must not carry the word forward from a
    /// detected one that preceded it — `setSyncPoints` overwrites the status
    /// same as it overwrites `syncOrigin`.
    func testAManualSyncDoesNotClaimToBeDetected() throws {
        let model = try makeAlignedModel()
        defer { model.close() }
        model.applySync(left: 18.64, right: 4.42)

        model.setSyncPoints()

        XCTAssertFalse(model.status.lowercased().contains("detected"))
    }

    // MARK: - Zoom

    /// A pane of a real size, which is all these need: the clamp arithmetic is
    /// `VideoZoomTests`' subject, and these are about *which side* moves.
    private static let zoomPane = CGSize(width: 800, height: 450)

    func testEachSideZoomsIndependently() throws {
        let model = try makeAlignedModel()
        defer { model.close() }

        model.setZoomScale(2.5, in: Self.zoomPane, side: .right)

        XCTAssertEqual(model.zoom(for: .right).scale, 2.5, accuracy: 0.0001)
        XCTAssertEqual(
            model.zoom(for: .left).scale, 1, accuracy: 0.0001,
            "two runs shot from different distances is the whole reason zoom is per side"
        )
    }

    func testPanningOneSideLeavesTheOtherCentred() throws {
        let model = try makeAlignedModel()
        defer { model.close() }
        model.setZoomScale(2, in: Self.zoomPane, side: .left)

        model.panZoom(by: CGSize(width: -100, height: 0), in: Self.zoomPane, side: .left)

        XCTAssertGreaterThan(model.zoom(for: .left).center.x, 0.5)
        XCTAssertEqual(model.zoom(for: .right).center.x, 0.5, accuracy: 0.0001)
    }

    func testResettingOneSideLeavesTheOther() throws {
        let model = try makeAlignedModel()
        defer { model.close() }
        model.setZoomScale(3, in: Self.zoomPane, side: .left)
        model.setZoomScale(2, in: Self.zoomPane, side: .right)

        model.resetZoom(side: .left)

        XCTAssertEqual(model.zoom(for: .left), VideoZoom())
        XCTAssertEqual(model.zoom(for: .right).scale, 2, accuracy: 0.0001)
    }

    /// **Why `setZoomScale` takes a pane size at all**, which is the one place
    /// this API departs from a sketch that had it take only a scale and a side.
    ///
    /// `VideoZoom.setScale` re-clamps the centre against the pane, because
    /// zooming *out* narrows the legal interval: a centre that is legal at 4×
    /// is not at 1.5×, and left uncorrected the picture hangs off one edge with
    /// black down the side. Without a pane to re-clamp against, the call would
    /// have to pass a degenerate size, which `VideoZoom` documents as the
    /// "skip the re-clamp" case — so the correction would silently never run.
    ///
    /// Measured, 800×450 pane, no clip dimensions (the fixtures report none, so
    /// `fitted` falls back to the pane): the legal half-extent is `1/(2·scale)`,
    /// giving `[0.125, 0.875]` at 4× and `[0.333, 0.667]` at 1.5×. A pan to the
    /// 4× bound therefore has to come back to 0.667 when the operator zooms out
    /// — and stays at 0.875 if the pane is not passed through.
    func testZoomingOutRecentresAPanThatIsNoLongerLegal() throws {
        let model = try makeAlignedModel()
        defer { model.close() }
        model.setZoomScale(4, in: Self.zoomPane, side: .left)
        model.panZoom(by: CGSize(width: -2000, height: 0), in: Self.zoomPane, side: .left)
        XCTAssertEqual(model.zoom(for: .left).center.x, 0.875, accuracy: 0.0001,
                       "precondition: panned to 4x's bound")

        model.setZoomScale(1.5, in: Self.zoomPane, side: .left)

        XCTAssertEqual(
            model.zoom(for: .left).center.x, 2.0 / 3.0, accuracy: 0.0001,
            "zooming out must pull the pan back inside the interval that is legal at the new scale"
        )
    }

    /// Zoom is a view setting, not an alignment one: it must not disturb the
    /// sync points or drop the pair out of sync.
    func testZoomingDoesNotTouchTheSync() throws {
        let model = try makeSyncedModel()
        defer { model.close() }
        let points = model.syncPoints
        XCTAssertNotNil(points, "precondition: there are sync points to leave alone")

        model.setZoomScale(3, in: Self.zoomPane, side: .left)
        model.panZoom(by: CGSize(width: -60, height: 20), in: Self.zoomPane, side: .left)

        XCTAssertEqual(model.zoom(for: .left).scale, 3, accuracy: 0.0001,
                       "precondition: the zoom must have taken, or this passes with the mutators gutted")
        XCTAssertGreaterThan(model.zoom(for: .left).center.x, 0.5, "precondition: and so must the pan")
        XCTAssertTrue(model.isSynced)
        XCTAssertEqual(model.syncPoints?.left, points?.left)
        XCTAssertEqual(model.syncPoints?.right, points?.right)
    }

    /// **Zoom names no side for the transport**, which is why none of these
    /// methods calls `noteTouched`. That records which side a `both` demotion
    /// lands on, and its rule is that it may only follow a call expressing a
    /// preference about *playback*; zooming the right pane to read a boot
    /// buckle says nothing about which clip the transport should fall back to.
    ///
    /// Built to fail if one is added: `makeAlignedModel` loads left then right,
    /// so the landing side is Right and the target is Left — a `noteTouched`
    /// inside the zoom methods would therefore be unguarded and would steal the
    /// landing for Left, exactly as the scrubber once did.
    func testZoomingASideDoesNotStealTheDemotionLanding() throws {
        let model = try makeAlignedModel()
        defer { model.close() }
        XCTAssertEqual(model.target, .left, "precondition: the target is not `both`, so a noteTouched would land")

        model.setZoomScale(3, in: Self.zoomPane, side: .left)
        model.panZoom(by: CGSize(width: -40, height: 0), in: Self.zoomPane, side: .left)
        XCTAssertEqual(model.zoom(for: .left).scale, 3, accuracy: 0.0001,
                       "precondition: the zoom must have taken, or this passes with the mutators gutted")
        XCTAssertGreaterThan(model.zoom(for: .left).center.x, 0.5, "precondition: and so must the pan")
        model.resetZoom(side: .left)
        model.setSyncPoints()
        model.removeSync()

        XCTAssertEqual(
            model.target, .right,
            "framing a pane is not a statement about which clip the transport should fall back to"
        )
    }
}

/// The bounds and paired-playback tests, on **real decodable media**.
///
/// The slow-motion tests at the end are here for the same fixture reason as the
/// bounds ones, plus one of their own: a paired start reaches
/// `AVPlayer.setRate(_:time:atHostTime:)`, which raises unless the item is
/// `.readyToPlay`, so a zero-byte fixture cannot reach that path at all.
///
/// These live apart from `ComparisonModelTests` because they need a different
/// kind of fixture, and that difference is the whole point: the zero-byte files
/// the tests above use report `duration` as NaN, so every upper bound inside
/// the model is `.infinity` and every seek beyond the end of a clip "succeeds".
/// A sync point could be driven to −3s or past the end of its clip and no test
/// in the suite could see it. Real media gives real durations and real
/// clamping, which is what makes the misalignment below reproducible.
///
/// Media is generated here rather than checked in: `AVAssetWriter` produces a
/// few hundred 160×90 H.264 frames in well under a second, into the test's own
/// temporary directory, which is removed in `tearDown`. Nothing reads the
/// user's library.
@MainActor
final class ComparisonBoundsTests: XCTestCase {
    private var temporaryDirectory: URL?

    override func tearDown() async throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    /// **The regression.** A nudge that would push a sync point below zero used
    /// to leave it there. `returnToSyncPoints()` then seeked each side
    /// independently, `AVPlayer` clamped the negative one to 0 on its own, and
    /// the pair landed 3s apart — while `isSynced` stayed true and the status
    /// read "Returned to the sync points". Measured before the fix:
    /// sync 2.0/2.0, pair at 8.0, one `back5` on the left → left sync point
    /// −3.0, return landed 0.0/2.0, offset 2.0 where the user had set 5.0.
    ///
    /// Nudges accumulate, so this is not a boundary curiosity: four `back5`
    /// corrections push a sync point 20s out wherever it started.
    func testReturningToSyncPointsKeepsTheOffsetWhenANudgeDrivesASyncPointBelowZero() throws {
        let model = try makeRealMediaModel(leftSeconds: 12, rightSeconds: 20)
        defer { model.close() }

        try align(model, left: 2, right: 2)
        model.setSyncPoints()
        XCTAssertTrue(model.isSynced, "precondition: the pair must be locked")

        model.target = .both
        model.scrub(.left, to: 8)
        settle(model)

        model.target = .left
        model.applyTransport(.back5)
        settle(model)

        // What the user just set, read off the clips themselves.
        let correctedOffset = model.rightPlayer.currentTime().seconds - model.leftPlayer.currentTime().seconds
        XCTAssertEqual(correctedOffset, 5, accuracy: 0.05,
                       "precondition: the nudge itself must move the left clip 5s earlier than the right")

        XCTAssertGreaterThanOrEqual(model.leftSyncPoint.seconds, 0,
                                    "a sync point below zero names no frame; it was \(model.leftSyncPoint.seconds)")
        XCTAssertEqual(model.rightSyncPoint.seconds - model.leftSyncPoint.seconds, correctedOffset, accuracy: 0.05,
                       "sliding the pair back into range must preserve the offset between the sync points")

        model.returnToSyncPoints()
        settle(model)

        let landedOffset = model.rightPlayer.currentTime().seconds - model.leftPlayer.currentTime().seconds
        XCTAssertEqual(landedOffset, correctedOffset, accuracy: 0.25,
                       """
                       returning to the sync points landed the pair \
                       \(abs(landedOffset - correctedOffset))s out of alignment \
                       (L \(model.leftPlayer.currentTime().seconds), \
                       R \(model.rightPlayer.currentTime().seconds))
                       """)
    }

    /// The symmetric case, and the one the first fix attempt did not cover: a
    /// forward nudge drives the sync point *past the end* of its clip, where
    /// `AVPlayer` clamps it down to the duration just as silently. Measured
    /// before the fix: sync 8.0/8.0, pair at 1.0, one `forward5` on the left →
    /// left sync point 13.0 on a 12s clip, return landed 3s out.
    func testReturningToSyncPointsKeepsTheOffsetWhenANudgeDrivesASyncPointPastTheEnd() throws {
        let model = try makeRealMediaModel(leftSeconds: 12, rightSeconds: 20)
        defer { model.close() }

        try align(model, left: 8, right: 8)
        model.setSyncPoints()
        XCTAssertTrue(model.isSynced, "precondition: the pair must be locked")

        model.target = .both
        model.scrub(.left, to: 1)
        settle(model)

        model.target = .left
        model.applyTransport(.forward5)
        settle(model)

        let correctedOffset = model.rightPlayer.currentTime().seconds - model.leftPlayer.currentTime().seconds
        XCTAssertEqual(correctedOffset, -5, accuracy: 0.05,
                       "precondition: the nudge itself must move the left clip 5s later than the right")

        XCTAssertLessThanOrEqual(model.leftSyncPoint.seconds, model.leftDuration + 0.01,
                                 """
                                 a sync point past the end of its clip names no frame; it was \
                                 \(model.leftSyncPoint.seconds) on a \(model.leftDuration)s clip
                                 """)
        XCTAssertEqual(model.rightSyncPoint.seconds - model.leftSyncPoint.seconds, correctedOffset, accuracy: 0.05,
                       "sliding the pair back into range must preserve the offset between the sync points")

        model.returnToSyncPoints()
        settle(model)

        let landedOffset = model.rightPlayer.currentTime().seconds - model.leftPlayer.currentTime().seconds
        XCTAssertEqual(landedOffset, correctedOffset, accuracy: 0.25,
                       """
                       returning to the sync points landed the pair \
                       \(abs(landedOffset - correctedOffset))s out of alignment \
                       (L \(model.leftPlayer.currentTime().seconds), \
                       R \(model.rightPlayer.currentTime().seconds))
                       """)
    }

    /// Nudges accumulate — that is what makes this reachable from ordinary use
    /// rather than from a contrived starting position. Four `back5` corrections
    /// ask for 20s of travel from a sync point at 2s.
    func testRepeatedNudgesInOneDirectionStillReturnToTheCorrectedAlignment() throws {
        let model = try makeRealMediaModel(leftSeconds: 25, rightSeconds: 25)
        defer { model.close() }

        try align(model, left: 2, right: 2)
        model.setSyncPoints()

        // Far enough in that all four nudges travel the full 5s: a nudge
        // clamped at the start travels less, which would make this test about
        // clamping rather than about accumulation.
        model.target = .both
        model.scrub(.left, to: 20)
        settle(model)

        model.target = .left
        for _ in 0..<4 {
            model.applyTransport(.back5)
            settle(model)
        }

        let correctedOffset = model.rightPlayer.currentTime().seconds - model.leftPlayer.currentTime().seconds
        XCTAssertEqual(correctedOffset, 20, accuracy: 0.05,
                       "precondition: four back-5 nudges must move the left clip 20s earlier")

        model.returnToSyncPoints()
        settle(model)

        let landedOffset = model.rightPlayer.currentTime().seconds - model.leftPlayer.currentTime().seconds
        XCTAssertEqual(landedOffset, correctedOffset, accuracy: 0.25,
                       """
                       four accumulated nudges landed the pair \
                       \(abs(landedOffset - correctedOffset))s out of alignment \
                       (L \(model.leftPlayer.currentTime().seconds), \
                       R \(model.rightPlayer.currentTime().seconds))
                       """)
    }

    /// **A drag is not one correction, it is hundreds**, and on real media they
    /// arrive faster than the seeks they ask for complete.
    ///
    /// This is the case only real media can show, and it found a real defect.
    /// Computing each correction's travel from `AVPlayer.currentTime()` reads a
    /// playhead still standing where the *previous* event left it, so every
    /// event shifts the sync point again by a distance the clip has already
    /// been asked to travel. Measured before `lockedPosition(of:)`: this drag
    /// left the clip correctly at 6.4s and the anchor at 1.6s, five seconds
    /// adrift — a stored run start that is silently wrong, which is worse than
    /// storing none.
    ///
    /// No `settle` between the events, deliberately. Settling between them is
    /// what a test does, not what a finger does.
    func testADragsWorthOfCorrectionsLandsTheAnchorWhereTheClipLands() throws {
        let model = try makeRealMediaModel(leftSeconds: 20, rightSeconds: 20)
        defer { model.close() }

        try align(model, left: 8, right: 5)
        model.setSyncPoints()
        model.target = .left

        for time in [7.6, 7.2, 6.8, 6.4] {
            model.scrub(.left, to: time)
        }
        settle(model)

        XCTAssertEqual(model.leftPlayer.currentTime().seconds, 6.4, accuracy: 0.15,
                       "the clip must end where the drag ended")
        XCTAssertEqual(model.leftSyncPoint.seconds, 6.4, accuracy: 0.15,
                       """
                       the anchor is \(model.leftSyncPoint.seconds) where the clip is \
                       \(model.leftPlayer.currentTime().seconds); the corrected start that gets \
                       stored would name a frame the operator never chose
                       """)
        XCTAssertEqual(model.rightSyncPoint.seconds, 5, accuracy: 0.05,
                       "the untouched side's anchor must not move at all")
    }

    /// The ordinary case, on real media, so the fix cannot be "always slide the
    /// pair somewhere". A nudge that stays comfortably inside both clips must
    /// leave both sync points exactly where the nudge put them.
    func testANudgeWellInsideBothClipsLeavesTheSyncPointsAlone() throws {
        let model = try makeRealMediaModel(leftSeconds: 20, rightSeconds: 20)
        defer { model.close() }

        try align(model, left: 8, right: 8)
        model.setSyncPoints()

        model.target = .left
        model.applyTransport(.back5)
        settle(model)

        XCTAssertEqual(model.leftSyncPoint.seconds, 3, accuracy: 0.05,
                       "the nudged side's sync point follows its clip")
        XCTAssertEqual(model.rightSyncPoint.seconds, 8, accuracy: 0.05,
                       "the untouched side's sync point must not move when nothing is out of range")
    }

    /// `applySync` on real media, in range: the sync points must land on the
    /// times asked for. Worth its own case because `setSyncPoints()` reads
    /// `AVPlayer.currentTime()`, and a seek on a real item completes
    /// asynchronously — if `currentTime()` lagged the seek, a detected sync
    /// would silently anchor on wherever the playheads happened to be.
    func testApplySyncOnRealMediaAnchorsOnTheTimesAskedFor() throws {
        let model = try makeRealMediaModel(leftSeconds: 12, rightSeconds: 20)
        defer { model.close() }

        model.applySync(left: 3, right: 7)

        XCTAssertTrue(model.isSynced)
        XCTAssertEqual(model.leftSyncPoint.seconds, 3, accuracy: 0.05)
        XCTAssertEqual(model.rightSyncPoint.seconds, 7, accuracy: 0.05)
        XCTAssertEqual(model.syncOrigin, .detected(left: 3, right: 7))
    }

    /// **The anchor, pinned to the request.** Real media loaded and then
    /// deliberately *not* waited on: `hasTwoVideos` is true the moment `load`
    /// sets the items, and the seeks `applySync` issues cannot have completed
    /// by the next line — `AVPlayer.seek` is fire-and-forget.
    ///
    /// **Nothing here pumps the run loop, and nothing may be added that does.**
    /// A test that settles first pins the race rather than the fix: it asserts
    /// what the anchor becomes once the seeks land, which is the one state a
    /// playhead-reading version also reaches.
    ///
    /// What this cannot claim is that it fails on demand against the version
    /// that read `currentTime()` back. Measured, it does not: `AVPlayer`
    /// usually reports a *pending* seek's target time straight away, which is
    /// why reading the playheads back looked correct for two whole features and
    /// only lost the race about 2 runs in 12 (`CorrectedStartEndToEndTests`,
    /// which anchored at 0.0 on those runs). Move the read ahead of the pause
    /// and the same version anchors at 0.0 every time — measured, all three
    /// `applySync` cases here. Both are the same defect: the anchor was a
    /// question about `AVPlayer`'s internal state rather than about the number
    /// the caller passed in.
    func testApplySyncAnchorsOnTheTimesAskedForBeforeAnySeekCanLand() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryDirectory = root
        let model = ComparisonModel()
        defer { model.close() }
        model.load(try makeRealVideoFile(in: root, name: "left.mov", seconds: 25), side: .left)
        model.load(try makeRealVideoFile(in: root, name: "right.mov", seconds: 25), side: .right)
        XCTAssertEqual(model.leftPlayer.currentTime().seconds, 0, accuracy: 1e-9,
                       "precondition: a freshly loaded clip sits at 0, which is what a lost race latches")

        model.applySync(left: 18.29, right: 12.04)

        XCTAssertTrue(model.isSynced)
        XCTAssertEqual(model.leftSyncPoint.seconds, 18.29, accuracy: 1.0 / 600,
                       """
                       the anchor is \(model.leftSyncPoint.seconds) where 18.29 was asked for; \
                       the status chip would still say 18.29 and the sidecar would get this
                       """)
        XCTAssertEqual(model.rightSyncPoint.seconds, 12.04, accuracy: 1.0 / 600)
    }

    /// And what is latched is the *clamped* request, exactly. A detected start
    /// of 9999s on a 20s clip must anchor at 20.0 — the bound `clampedSeekTarget`
    /// applied and the time the seek was actually given — however far the clip
    /// itself gets. Also unpumped, for the reason above.
    func testApplySyncLatchesTheClampedRequestNotWhereThePlayerLands() throws {
        let model = try makeRealMediaModel(leftSeconds: 12, rightSeconds: 20)
        defer { model.close() }

        model.applySync(left: -3, right: 9_999)

        XCTAssertEqual(model.leftSyncPoint.seconds, 0, accuracy: 1.0 / 600,
                       "a start before the first frame clamps to 0, and 0 is what the anchor must hold")
        XCTAssertEqual(model.rightSyncPoint.seconds, model.rightDuration, accuracy: 1.0 / 600,
                       """
                       the anchor is \(model.rightSyncPoint.seconds) where the clamp is \
                       \(model.rightDuration); anything else means the playhead was read back
                       """)
    }

    /// The half the zero-byte fixtures cannot see. A detected start at or before
    /// the first frame, and one past the end of its clip, in the same call: both
    /// must land on a real frame and the pair must end up fully synced, because
    /// half a sync is worse than none.
    func testApplySyncClampsBothEndsIntoRealClips() throws {
        let model = try makeRealMediaModel(leftSeconds: 12, rightSeconds: 20)
        defer { model.close() }

        model.applySync(left: -3, right: 9_999)

        XCTAssertTrue(model.isSynced, "a clamped detection must still sync the pair")
        XCTAssertGreaterThanOrEqual(model.leftSyncPoint.seconds, 0,
                                    "a sync point below zero names no frame; it was \(model.leftSyncPoint.seconds)")
        XCTAssertLessThanOrEqual(model.leftSyncPoint.seconds, model.leftDuration + 0.01)
        XCTAssertGreaterThanOrEqual(model.rightSyncPoint.seconds, 0)
        XCTAssertLessThanOrEqual(
            model.rightSyncPoint.seconds,
            model.rightDuration + 0.01,
            """
            a sync point past the end of its clip names no frame; it was \
            \(model.rightSyncPoint.seconds) on a \(model.rightDuration)s clip
            """
        )
        // Both playheads must agree with the sync points they were taken from,
        // or the pair is locked to an offset neither clip is actually at.
        settle(model)
        XCTAssertEqual(model.leftPlayer.currentTime().seconds, model.leftSyncPoint.seconds, accuracy: 0.05)
        XCTAssertEqual(model.rightPlayer.currentTime().seconds, model.rightSyncPoint.seconds, accuracy: 0.05)
    }

    // MARK: - Slow motion on real media

    /// A locked pair, played, held and released, with the distance between the
    /// two playheads measured before and after. `SlowMotionHold` starts and
    /// restores a set of players on a common clock precisely so this distance
    /// does not move; `playSynced` is the precedent it borrows from.
    ///
    /// **The tolerance comes from measurement.** Across five runs on this
    /// machine the delta moved by at most 0.4ms over a full cycle (the run
    /// recorded here: 0.00011s introduced by the start, 0.00001s by the
    /// restore). 10ms is ~25x the worst observation and under a third of a
    /// frame at 30fps — tight enough to fail on drift an operator could see,
    /// loose enough not to flake on sampling.
    ///
    /// **What it does not do.** It pins the invariant, not the mechanism: the
    /// same measurement against two independent `playImmediately` calls — what
    /// the hold did before — also came in under 0.1ms on these fixtures
    /// (160x90 H.264, decoders that start instantly), so deleting the paired
    /// start does not fail this test. The skew it prevents belongs to real
    /// cameras and real decoders, which no generated fixture reproduces. Read
    /// it as a floor, not as a regression guard.
    func testAHeldPairComesBackFromSlowMotionStillAligned() throws {
        let input = FakeInputSource()
        let model = try makeRealMediaModel(leftSeconds: 12, rightSeconds: 12, input: input)
        defer { model.close() }
        try align(model, left: 2, right: 3)
        model.setSyncPoints()
        waitUntilReadyToPlay(model)

        model.applyTransport(.playPause)
        pump(0.8)
        let before = model.leftPlayer.currentTime().seconds - model.rightPlayer.currentTime().seconds
        XCTAssertNotEqual(model.leftPlayer.rate, 0, "premise: the pair must actually be playing")

        input.emit(.slowMotionBegan(.forward))
        XCTAssertEqual(model.leftPlayer.rate, 0.35, accuracy: 0.001)
        XCTAssertEqual(model.rightPlayer.rate, 0.35, accuracy: 0.001)
        pump(0.8)

        input.emit(.slowMotionEnded)
        XCTAssertEqual(model.leftPlayer.rate, 1, accuracy: 0.001, "the pre-hold rate must come back")
        pump(0.8)
        let after = model.leftPlayer.currentTime().seconds - model.rightPlayer.currentTime().seconds
        model.pauseBoth()

        XCTAssertEqual(
            after, before, accuracy: 0.01,
            "the hold moved the pair \(after - before)s out of alignment"
        )
    }

    /// `playSynced` arms a recovery 0.35s out, guarded on `playbackGeneration`
    /// and on "either side is stopped". A hold begun inside that window is a
    /// playback start like any other, and must take the generation with it —
    /// otherwise the recovery fires *through* the hold, plays both clips at 1×
    /// and rewrites the status to "Playing together".
    ///
    /// The players are stopped by hand, and that stands in for something the
    /// fixtures cannot produce: on media where `canPlayReverse` is false the
    /// hold's timer fallback pauses both clips, which is exactly the state the
    /// recovery is looking for. Every clip this suite can generate is
    /// reversible, so the hold here runs natively in reverse and the pause
    /// reproduces the state directly.
    func testAHoldCancelsAPendingPlaybackRecovery() throws {
        let input = FakeInputSource()
        let model = try makeRealMediaModel(leftSeconds: 12, rightSeconds: 12, input: input)
        defer { model.close() }
        try align(model, left: 2, right: 2)
        model.setSyncPoints()
        waitUntilReadyToPlay(model)

        model.applyTransport(.playPause)
        input.emit(.slowMotionBegan(.backward))
        model.leftPlayer.pause()
        model.rightPlayer.pause()
        pump(0.7)

        XCTAssertEqual(model.status, "Slow backward",
                       "a recovery from before the hold must not rewrite the status over it")
        XCTAssertNotEqual(model.leftPlayer.rate, 1, "nor play the pair forward under a reverse hold")
        XCTAssertNotEqual(model.rightPlayer.rate, 1)
    }

    // MARK: - Playing from the end of a clip

    /// An unsynced side rewinds to its own zero, and only that side moves.
    func testPlayingAnUnsyncedClipAtItsEndRewindsThatSideAlone() throws {
        let model = try makeRealMediaModel(leftSeconds: 2, rightSeconds: 6)
        model.seek(.left, to: 99)
        settle(model)
        XCTAssertEqual(model.leftPlayer.currentTime().seconds, 2, accuracy: 0.05,
                       "precondition: the left clip must be parked at its end")

        model.toggleIndividual(.left)
        XCTAssertGreaterThan(model.leftPlayer.rate, 0,
                             "play at the end must start playback rather than do nothing")
        waitUntil("the left playhead must have been rewound") {
            model.leftPlayer.currentTime().seconds < 0.5
        }
        XCTAssertEqual(model.rightPlayer.currentTime().seconds, 0, accuracy: 0.05,
                       "the other side must not have been moved")
        XCTAssertEqual(model.rightPlayer.rate, 0, "nor started")
    }

    /// The tortoise button on one unsynced side, same dead end.
    func testSlowMotionOnAnUnsyncedClipAtItsEndRewindsIt() throws {
        let model = try makeRealMediaModel(leftSeconds: 2, rightSeconds: 6)
        model.seek(.right, to: 99)
        settle(model)
        XCTAssertEqual(model.rightPlayer.currentTime().seconds, 6, accuracy: 0.05,
                       "precondition: the right clip must be parked at its end")

        model.playIndividual(.right, rate: 0.25)
        XCTAssertEqual(model.rightPlayer.rate, 0.25, accuracy: 0.01,
                       "quarter speed at the end must start playback rather than do nothing")
        waitUntil("the right playhead must have been rewound") {
            model.rightPlayer.currentTime().seconds < 0.5
        }
    }

    /// **The synced case, and the reason it is not "seek both to zero".**
    ///
    /// The offset between the two sync points *is* the alignment the operator
    /// established — it is the whole product of this screen. Rewinding both
    /// clips to their own zeros would discard it silently, leaving `isSynced`
    /// true over a pair that no longer lines up. `returnToSyncPoints()` is the
    /// existing single place that comes back to the alignment, normalisation
    /// included, so this uses it.
    ///
    /// The 2s offset assertion is what separates the two behaviours: seeking
    /// both to zero flattens it to 0.
    func testPlayingASyncedPairAtTheEndReturnsToTheSyncPointsRatherThanZero() throws {
        let model = try makeRealMediaModel(leftSeconds: 4, rightSeconds: 6)
        waitUntilReadyToPlay(model)
        model.applySync(left: 1, right: 3)
        settle(model)
        XCTAssertTrue(model.isSynced, "precondition: the pair must be locked")

        // Run the locked pair off the end without waiting for real playback.
        // `seekSynced` moves both and clamps each at its own duration, which is
        // exactly where playing to the end leaves them.
        model.seekSynced(by: 10)
        settle(model)
        XCTAssertEqual(model.leftPlayer.currentTime().seconds, 4, accuracy: 0.05,
                       "precondition: the left clip must be at its end")
        XCTAssertEqual(model.rightPlayer.currentTime().seconds, 6, accuracy: 0.05,
                       "precondition: the right clip must be at its end")

        model.applyTransport(.playPause)
        waitUntil("the synced pair must start playing rather than sit dead at the end") {
            model.leftPlayer.rate > 0 && model.rightPlayer.rate > 0
        }
        model.pauseBoth()
        settle(model)

        let left = model.leftPlayer.currentTime().seconds
        let right = model.rightPlayer.currentTime().seconds
        XCTAssertEqual(right - left, 2, accuracy: 0.25,
                       "the 2s alignment offset must survive the rewind — seeking both clips to "
                           + "their own zeros would flatten it to 0")
        XCTAssertLessThan(left, 2.5, "the pair must have come back from the end")
        XCTAssertGreaterThan(left, 0.5,
                             "returning to the sync points is not returning to zero")
    }

    /// The guard on the other side: a locked pair paused midway must carry on
    /// from where it is, not snap back to the sync points every time the
    /// operator presses play.
    func testPlayingASyncedPairMidClipDoesNotReturnToTheSyncPoints() throws {
        let model = try makeRealMediaModel(leftSeconds: 6, rightSeconds: 8)
        waitUntilReadyToPlay(model)
        model.applySync(left: 1, right: 3)
        settle(model)
        model.seekSynced(by: 2)
        settle(model)
        XCTAssertEqual(model.leftPlayer.currentTime().seconds, 3, accuracy: 0.05,
                       "precondition: parked 2s past the left sync point")

        model.applyTransport(.playPause)
        waitUntil("the pair must start playing") {
            model.leftPlayer.rate > 0 && model.rightPlayer.rate > 0
        }
        model.pauseBoth()
        settle(model)
        XCTAssertGreaterThan(model.leftPlayer.currentTime().seconds, 2.5,
                             "playing from mid-clip must continue from there, not jump back to "
                                 + "the 1s sync point")
    }

    // MARK: - Fixtures

    /// Two loaded clips whose durations the model has actually observed. The
    /// wait matters: `AVPlayerItem.duration` is NaN until the item loads, and a
    /// bounds test run before that would measure the same absent bounds the
    /// zero-byte fixtures give.
    private func makeRealMediaModel(
        leftSeconds: Double,
        rightSeconds: Double,
        input: FakeInputSource? = nil
    ) throws -> ComparisonModel {
        let root = temporaryDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        temporaryDirectory = root
        let model = ComparisonModel(input: input)
        model.load(try makeRealVideoFile(in: root, name: "left.mov", seconds: leftSeconds), side: .left)
        model.load(try makeRealVideoFile(in: root, name: "right.mov", seconds: rightSeconds), side: .right)
        waitUntil("the clips' durations must be known before any bound can be tested") {
            model.leftDuration > 0 && model.rightDuration > 0
        }
        XCTAssertEqual(model.leftDuration, leftSeconds, accuracy: 0.05)
        XCTAssertEqual(model.rightDuration, rightSeconds, accuracy: 0.05)
        return model
    }

    /// Both clips parked on a chosen second, the way a user aligns them before
    /// tapping the anchor.
    private func align(_ model: ComparisonModel, left: Double, right: Double) throws {
        model.seek(.left, to: left)
        model.seek(.right, to: right)
        settle(model)
        XCTAssertEqual(model.leftPlayer.currentTime().seconds, left, accuracy: 0.05,
                       "precondition: the left clip must have reached \(left)s")
        XCTAssertEqual(model.rightPlayer.currentTime().seconds, right, accuracy: 0.05,
                       "precondition: the right clip must have reached \(right)s")
    }

    /// Seeks on a real item are asynchronous, so every measurement waits for
    /// both playheads to stop moving rather than reading them straight after
    /// the call. Stability, not an expected value: a test that waited for the
    /// value it wants would pass by construction.
    private func settle(_ model: ComparisonModel, timeout: TimeInterval = 5) {
        var previous = (Double.nan, Double.nan)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let now = (model.leftPlayer.currentTime().seconds, model.rightPlayer.currentTime().seconds)
            if now == previous { return }
            previous = now
        }
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 20, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), message)
    }

    /// Lets real playback actually run. `settle` waits for the playheads to
    /// *stop*, which is the opposite of what a drift measurement needs.
    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Both items ready, which every paired start requires: `playSynced` and
    /// `SlowMotionHold`'s paired start both reach
    /// `AVPlayer.setRate(_:time:atHostTime:)`, which raises unless the item is
    /// `.readyToPlay`.
    private func waitUntilReadyToPlay(_ model: ComparisonModel) {
        waitUntil("both items must reach .readyToPlay before a paired start") {
            model.leftPlayer.currentItem?.status == .readyToPlay
                && model.rightPlayer.currentItem?.status == .readyToPlay
        }
    }

}
