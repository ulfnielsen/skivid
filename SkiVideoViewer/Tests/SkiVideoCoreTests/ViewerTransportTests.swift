import AVFoundation
import XCTest
@testable import SkiVideoCore

/// The viewer's transport, against real media.
///
/// Every assertion here is about a bound or a duration, so a zero-byte fixture
/// would make the whole file vacuous — see `RealVideoFixture`.
@MainActor
final class ViewerTransportTests: XCTestCase {
    private var temporaryDirectory: URL?

    override func tearDown() {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        super.tearDown()
    }

    func testDurationIsPublishedOnceTheClipLoads() throws {
        let model = try makeLoadedModel(seconds: 6)
        waitUntil("the duration must be published") { model.duration > 0 }
        XCTAssertEqual(model.duration, 6, accuracy: 0.2)
    }

    /// Must be driven by the periodic time observer, not by an action that
    /// happens to also write `currentTime` itself. `scrub(to:)` assigns
    /// `currentTime` synchronously as part of what it does — asserting on that
    /// would pass with `startObservingTime()` replaced by a no-op, because the
    /// action under test would still be the one producing the value. Driving
    /// the playhead with `playPause` and reading `currentTime` back exercises
    /// only the observer: nothing else in the model writes it during ordinary
    /// playback.
    func testCurrentTimeFollowsThePlayhead() throws {
        let model = try makeLoadedModel(seconds: 6)
        waitUntil("the duration must be published") { model.duration > 0 }
        model.applyTransport(.playPause)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        XCTAssertGreaterThan(model.currentTime, 0.5,
                             "currentTime must be updated by the periodic time observer during playback")
    }

    func testForward5MovesFiveSeconds() throws {
        let model = try makeLoadedModel(seconds: 20)
        waitUntil("the duration must be published") { model.duration > 0 }
        model.applyTransport(.forward5)
        settle(model)
        XCTAssertEqual(model.player.currentTime().seconds, 5, accuracy: 0.2)
    }

    func testBack1DoesNotGoNegative() throws {
        let model = try makeLoadedModel(seconds: 20)
        waitUntil("the duration must be published") { model.duration > 0 }
        model.applyTransport(.back1)
        settle(model)
        XCTAssertEqual(model.player.currentTime().seconds, 0, accuracy: 0.05,
                       "seeking back from 0 must clamp at 0, not go negative")
    }

    func testForward5StopsAtTheEndOfTheClip() throws {
        let model = try makeLoadedModel(seconds: 6)
        waitUntil("the duration must be published") { model.duration > 0 }
        for _ in 0..<3 { model.applyTransport(.forward5); settle(model) }
        // Both bounds: `≤ 6.05` alone is satisfied by a player that never
        // moved at all, which would not distinguish "clamped at the end" from
        // "the seek never happened."
        XCTAssertLessThanOrEqual(model.player.currentTime().seconds, 6.05,
                                 "seeking past the end must clamp to the duration")
        XCTAssertGreaterThanOrEqual(model.player.currentTime().seconds, 5.9,
                                    "three forward-5 presses on a 6s clip must actually reach the end")
    }

    func testSlowPlaysAtQuarterRate() throws {
        let model = try makeLoadedModel(seconds: 20)
        waitUntil("the duration must be published") { model.duration > 0 }
        model.applyTransport(.slow)
        XCTAssertEqual(model.player.rate, 0.25, accuracy: 0.01)
    }

    func testPlayPauseTogglesTheRate() throws {
        let model = try makeLoadedModel(seconds: 20)
        waitUntil("the duration must be published") { model.duration > 0 }
        model.applyTransport(.playPause)
        XCTAssertGreaterThan(model.player.rate, 0, "the first press must start playback")
        model.applyTransport(.playPause)
        XCTAssertEqual(model.player.rate, 0, "the second press must pause")
    }

    /// A transport press while a slow-motion hold is in flight must cancel the
    /// hold. Without this the hold's state survives the press:
    /// `SlowMotionHold.isActive` stays true, so its `begin` refuses the next
    /// hold entirely — the same class of stranded-state defect that the
    /// `guard !isActive` there exists for.
    func testATransportPressCancelsAnArrowHold() throws {
        let model = try makeLoadedModel(seconds: 20)
        waitUntil("the duration must be published") { model.duration > 0 }
        model.handle(.slowMotionBegan(.forward))
        waitUntil("precondition: the hold must be running before the transport press") {
            abs(model.player.rate - 0.35) < 0.01
        }
        model.applyTransport(.forward5)
        settle(model)

        // The hold must be cancelled outright, not left running. Without
        // `endSlowMotion` in `applyTransport` the player keeps creeping
        // forward at 0.35 after the press, and the hold's state also strands
        // `SlowMotionHold.isActive`, so `begin` refuses every later hold.
        XCTAssertEqual(model.player.rate, 0, accuracy: 0.01,
                       "a transport press must cancel the hold, not leave it running")

        // Assert on an effect the *second* hold produces, not on
        // `lastSeekOffset`: `applyTransport(.forward5)` already sets that, so an
        // assertion on it would pass whether or not the hold was cancelled.
        model.handle(.slowMotionBegan(.forward))
        waitUntil("a hold after a transport press must be accepted and start") {
            abs(model.player.rate - 0.35) < 0.01
        }
    }

    /// The player-side assertion alone does not pin `scrub`'s own clamp:
    /// `AVPlayer.seek(to:)` clamps an out-of-range target to the item's valid
    /// range on its own, so `player.currentTime()` reads correctly whether or
    /// not `scrub` clamps `target` itself. The published `currentTime`,
    /// assigned synchronously from the unclamped `target` before the seek is
    /// even issued, is the only thing that actually depends on `scrub`'s own
    /// guard — read it immediately, before `settle` lets the periodic time
    /// observer overwrite it with the (already-correct) player position.
    func testScrubClampsAboveTheDuration() throws {
        let model = try makeLoadedModel(seconds: 6)
        waitUntil("the duration must be published") { model.duration > 0 }
        model.scrub(to: 999)
        XCTAssertLessThanOrEqual(model.currentTime, 6.05,
                                 "the published time must be clamped to the duration immediately")
        settle(model)
        XCTAssertLessThanOrEqual(model.player.currentTime().seconds, 6.05,
                                 "scrubbing beyond the clip must clamp to its duration")
        XCTAssertGreaterThanOrEqual(model.player.currentTime().seconds, 5.9,
                                    "scrubbing to 999 on a 6s clip must actually reach the end, not stay put")
    }

    /// `scrub` has its own lower clamp, separate from `seek`'s. A test that only
    /// covered `applyTransport(.back1)` would leave this one unpinned, because
    /// the two take different paths to the player.
    ///
    /// As with the upper bound above, `player.currentTime()` alone cannot pin
    /// this: `AVPlayer.seek(to:)` clamps a negative target on its own. Here the
    /// gap is worse than transient — a seek landing where the player already
    /// sits (0) produces no time jump, so the periodic observer never fires at
    /// all, and the unclamped `currentTime` would read -20.0 and *stay* -20.0
    /// through the whole `settle` window. Read it immediately.
    func testScrubClampsBelowZero() throws {
        let model = try makeLoadedModel(seconds: 6)
        waitUntil("the duration must be published") { model.duration > 0 }
        model.scrub(to: -20)
        XCTAssertEqual(model.currentTime, 0, accuracy: 0.05,
                       "the published time must be clamped at 0 immediately, not left negative")
        settle(model)
        XCTAssertEqual(model.player.currentTime().seconds, 0, accuracy: 0.05,
                       "scrubbing before the start must clamp at 0, not go negative")
    }

    // MARK: - isPlaying

    /// The plain toggle, through the public entry point rather than by poking
    /// the player. Both directions, and both checked against the player's real
    /// rate as well as against the expected boolean: `isPlaying` agreeing with
    /// itself proves nothing.
    func testIsPlayingFollowsTogglePlayback() throws {
        let model = try makeLoadedModel(seconds: 9)
        waitUntil("the duration must be published") { model.duration > 0 }
        XCTAssertFalse(model.isPlaying, "precondition: a freshly loaded clip is paused")

        model.togglePlayback()
        waitUntil("isPlaying must become true once playback starts") { model.isPlaying }
        XCTAssertGreaterThan(model.player.rate, 0, "precondition: the player really is playing")

        model.togglePlayback()
        waitUntil("isPlaying must become false once playback stops") { !model.isPlaying }
        XCTAssertEqual(model.player.rate, 0, "precondition: the player really is stopped")
    }

    /// The other public entry point. Worth its own test: `applyTransport` calls
    /// `endSlowMotion` before `togglePlayback`, a second place the rate can
    /// change.
    func testIsPlayingFollowsThePlayPauseTransport() throws {
        let model = try makeLoadedModel(seconds: 9)
        waitUntil("the duration must be published") { model.duration > 0 }
        XCTAssertFalse(model.isPlaying, "precondition: a freshly loaded clip is paused")

        model.applyTransport(.playPause)
        waitUntil("isPlaying must become true after the play/pause transport") { model.isPlaying }
        XCTAssertGreaterThan(model.player.rate, 0)

        model.applyTransport(.playPause)
        waitUntil("isPlaying must become false after the second press") { !model.isPlaying }
        XCTAssertEqual(model.player.rate, 0)
    }

    /// The case a hand-written flag gets wrong. A slow-motion hold started from
    /// a *paused* clip drives the rate to 0.35 without `togglePlayback` being
    /// called at all — `SlowMotionHold.begin` reaches the player directly — and
    /// releasing it drives the rate back to 0 through `SlowMotionHold.end()`,
    /// again with no toggle involved. A flag set inside
    /// `togglePlayback` stays false through both, so `isPlaying` would report
    /// "paused" over half a second of visibly moving video, and the search
    /// field would keep the focus exactly when the operator started watching.
    ///
    /// Asserts the rate at each step as well as the flag, so "the hold never
    /// started" cannot masquerade as "the flag tracked a hold that did".
    func testIsPlayingFollowsAHoldStartedFromAPausedClip() throws {
        let model = try makeLoadedModel(seconds: 9)
        waitUntil("the duration must be published") { model.duration > 0 }
        XCTAssertFalse(model.isPlaying, "precondition: paused, and no toggle will be called in this test")

        model.handle(.slowMotionBegan(.forward))
        waitUntil("precondition: the hold must actually start and drive the rate") {
            abs(model.player.rate - 0.35) < 0.01
        }
        waitUntil("isPlaying must follow a rate the hold set, not only one togglePlayback set") {
            model.isPlaying
        }

        model.handle(.slowMotionEnded)
        waitUntil("precondition: releasing a hold taken from pause must stop the player") {
            model.player.rate == 0
        }
        waitUntil("isPlaying must follow the rate back down when the hold is released") {
            !model.isPlaying
        }
    }

    /// The complementary leg: a hold taken *during* playback restores the
    /// previous rate on release, so `isPlaying` must be true on both sides of
    /// it and never latch false on the way through. The rate genuinely changes
    /// three times here (1 → 0.35 → 0 → 1), the middle stop being
    /// `SlowMotionHold.end()`'s `player.pause()` before it restores the
    /// pre-hold rate.
    func testIsPlayingSurvivesAHoldTakenDuringPlayback() throws {
        let model = try makeLoadedModel(seconds: 9)
        waitUntil("the duration must be published") { model.duration > 0 }

        model.togglePlayback()
        waitUntil("precondition: playback must start") { model.player.rate == 1 }

        model.handle(.slowMotionBegan(.forward))
        waitUntil("precondition: the hold must take over the rate") {
            abs(model.player.rate - 0.35) < 0.01
        }

        model.handle(.slowMotionEnded)
        waitUntil("precondition: releasing must restore the pre-hold rate") { model.player.rate == 1 }
        waitUntil("isPlaying must still be true once the hold hands playback back") { model.isPlaying }

        // And it still comes down afterwards: a flag stuck true is as wrong as
        // one stuck false.
        model.togglePlayback()
        waitUntil("isPlaying must still be able to fall after a hold") { !model.isPlaying }
        XCTAssertEqual(model.player.rate, 0)
    }

    /// The slow-motion transport is a third rate-changing path with no toggle
    /// in it: `applyTransport(.slow)` calls `playImmediately(atRate: 0.25)`
    /// directly. Quarter speed is still playing.
    func testIsPlayingFollowsTheSlowMotionTransport() throws {
        let model = try makeLoadedModel(seconds: 9)
        waitUntil("the duration must be published") { model.duration > 0 }
        XCTAssertFalse(model.isPlaying, "precondition: paused")

        model.applyTransport(.slow)
        XCTAssertEqual(model.player.rate, 0.25, accuracy: 0.01, "precondition: quarter speed")
        waitUntil("isPlaying must be true at quarter speed") { model.isPlaying }
    }

    // MARK: - helpers

    private func makeLoadedModel(seconds: Double) throws -> ViewerModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        temporaryDirectory = root
        let athlete = root.appendingPathComponent("Athlete", isDirectory: true)
        _ = try makeRealVideoFile(in: athlete, name: "run1.mov", seconds: seconds)

        let model = ViewerModel(
            input: FakeInputSource(),
            folderPicker: FakeFolderPicker(),
            oauthPresenter: FakeOAuthPresenter()
        )
        model.openDirectory(root)
        return model
    }

    /// Stability, not an expected value: a wait for the value the test wants
    /// would pass by construction. Seeks on a real item are asynchronous.
    private func settle(_ model: ViewerModel, timeout: TimeInterval = 5) {
        var previous = Double.nan
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let now = model.player.currentTime().seconds
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
}
