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

    func testScrubKeysFollowTheTargetWhileAligning() throws {
        let input = FakeInputSource()
        let model = try makeAlignedModel(input: input)
        defer { model.close() }

        model.target = .right
        input.emit(.scrubBegan(.forward))

        XCTAssertEqual(model.rightPlayer.currentTime().seconds, 1, accuracy: 0.01,
                       "the targeted clip must move")
        XCTAssertEqual(model.leftPlayer.currentTime().seconds, 0, accuracy: 0.01,
                       "the untargeted clip must not")
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

    /// The pair must stay locked at the *new* offset: `scrub` derives its
    /// offset from the two sync points, so it has to follow the correction.
    func testNudgeRetargetsTheOffsetTheLockedPairKeeps() throws {
        let model = try makeSyncedModel()
        defer { model.close() }

        model.target = .right
        model.applyTransport(.forward5)

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
}
