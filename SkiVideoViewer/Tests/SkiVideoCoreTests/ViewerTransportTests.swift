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

    func testCurrentTimeFollowsThePlayhead() throws {
        let model = try makeLoadedModel(seconds: 6)
        waitUntil("the duration must be published") { model.duration > 0 }
        model.scrub(to: 3)
        settle(model)
        waitUntil("currentTime must follow the playhead") { model.currentTime > 2.5 }
        XCTAssertEqual(model.currentTime, 3, accuracy: 0.3)
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
        XCTAssertLessThanOrEqual(model.player.currentTime().seconds, 6.05,
                                 "seeking past the end must clamp to the duration")
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

    /// A transport press while an arrow hold is in flight must cancel the hold.
    /// Without this the hold's state survives the press: `heldDirection` stays
    /// set, so `beginArrow` refuses the next hold entirely — the same class of
    /// stranded-state defect that the `heldDirection == nil` guard exists for.
    func testATransportPressCancelsAnArrowHold() throws {
        let model = try makeLoadedModel(seconds: 20)
        waitUntil("the duration must be published") { model.duration > 0 }
        model.beginArrow(.forward)
        model.applyTransport(.forward5)
        settle(model)

        // Assert on an effect the *second* hold produces, not on
        // `lastSeekOffset`: `applyTransport(.forward5)` already sets that, so an
        // assertion on it would pass whether or not the hold was cancelled.
        // A hold that starts drives the rate to 0.35 after `holdThreshold`.
        model.beginArrow(.forward)
        waitUntil("a hold after a transport press must be accepted and start") {
            abs(model.player.rate - 0.35) < 0.01
        }
    }

    func testScrubClampsAboveTheDuration() throws {
        let model = try makeLoadedModel(seconds: 6)
        waitUntil("the duration must be published") { model.duration > 0 }
        model.scrub(to: 999)
        settle(model)
        XCTAssertLessThanOrEqual(model.player.currentTime().seconds, 6.05,
                                 "scrubbing beyond the clip must clamp to its duration")
    }

    /// `scrub` has its own lower clamp, separate from `seek`'s. A test that only
    /// covered `applyTransport(.back1)` would leave this one unpinned, because
    /// the two take different paths to the player.
    func testScrubClampsBelowZero() throws {
        let model = try makeLoadedModel(seconds: 6)
        waitUntil("the duration must be published") { model.duration > 0 }
        model.scrub(to: -20)
        settle(model)
        XCTAssertEqual(model.player.currentTime().seconds, 0, accuracy: 0.05,
                       "scrubbing before the start must clamp at 0, not go negative")
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
