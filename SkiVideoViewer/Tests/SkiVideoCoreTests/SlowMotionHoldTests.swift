import AVFoundation
import XCTest
@testable import SkiVideoCore

/// `SlowMotionHold` against real media. `canPlayReverse` is only meaningful on
/// an item that actually loaded, so the reversible-path test needs a real clip
/// — a zero-byte file reports `false` forever, which is the *fallback* path and
/// is tested separately with exactly such a file.
@MainActor
final class SlowMotionHoldTests: XCTestCase {
    private var temporaryDirectory: URL?

    override func tearDown() {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        super.tearDown()
    }

    private func makeDirectory() throws -> URL {
        if let temporaryDirectory { return temporaryDirectory }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryDirectory = root
        return root
    }

    /// A player holding a real, seekable clip.
    private func makeRealPlayer(seconds: Double = 20) throws -> AVPlayer {
        let url = try makeRealVideoFile(
            in: try makeDirectory(),
            name: "\(UUID().uuidString).mov",
            seconds: seconds
        )
        let player = AVPlayer(url: url)
        waitUntil("the item must become ready") {
            player.currentItem?.status == .readyToPlay
        }
        return player
    }

    /// A player whose item can never load, so `canPlayReverse` stays false.
    private func makeUnloadablePlayer() throws -> AVPlayer {
        let url = try makeDirectory().appendingPathComponent("\(UUID().uuidString).mov")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return AVPlayer(url: url)
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 20, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), message)
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testForwardPlaysAtTheSlowRate() throws {
        let player = try makeRealPlayer()
        let hold = SlowMotionHold()

        hold.begin(.forward, players: [player])

        XCTAssertTrue(hold.isActive)
        XCTAssertEqual(player.rate, 0.35, accuracy: 0.001)
    }

    func testForwardDrivesEveryPlayerItIsGiven() throws {
        let left = try makeRealPlayer()
        let right = try makeRealPlayer()
        let hold = SlowMotionHold()

        hold.begin(.forward, players: [left, right])

        XCTAssertEqual(left.rate, 0.35, accuracy: 0.001)
        XCTAssertEqual(right.rate, 0.35, accuracy: 0.001)
    }

    func testBackwardPlaysInReverseWhenTheItemAllowsIt() throws {
        let player = try makeRealPlayer()
        waitUntil("the fixture must be reversible, or this test proves nothing") {
            player.currentItem?.canPlayReverse == true
        }
        let hold = SlowMotionHold()

        hold.begin(.backward, players: [player])

        XCTAssertEqual(player.rate, -0.35, accuracy: 0.001)
    }

    /// The fallback the viewer has always had: pause, and step the playhead
    /// back on a timer. Asserting on the rate alone would pass with the timer
    /// never scheduled, so this asserts the playhead actually moved.
    func testBackwardStepsThePlayheadWhenTheItemCannotPlayInReverse() throws {
        let player = try makeUnloadablePlayer()
        XCTAssertNotEqual(player.currentItem?.canPlayReverse, true,
                          "premise: this item must not be reversible")
        let hold = SlowMotionHold()

        hold.begin(.backward, players: [player])

        XCTAssertEqual(player.rate, 0, "the fallback must leave the player paused")
        XCTAssertTrue(hold.isActive)
        pump(0.3)
        XCTAssertNotNil(hold.lastFallbackTarget,
                        "the timer must have fired and asked for a target")
    }

    func testEndRestoresThePriorRate() throws {
        let player = try makeRealPlayer()
        player.playImmediately(atRate: 1)
        let hold = SlowMotionHold()

        hold.begin(.forward, players: [player])
        XCTAssertEqual(player.rate, 0.35, accuracy: 0.001)
        hold.end()

        XCTAssertEqual(player.rate, 1, accuracy: 0.001)
        XCTAssertFalse(hold.isActive)
    }

    func testEndLeavesAPausedPlayerPaused() throws {
        let player = try makeRealPlayer()
        let hold = SlowMotionHold()

        hold.begin(.forward, players: [player])
        hold.end()

        XCTAssertEqual(player.rate, 0, "a player that was paused must not start playing")
    }

    /// `end()` is called from app-resign, window close and clip change as well
    /// as from the key-up, so it must tolerate being called when nothing is
    /// held and twice in a row.
    func testEndIsIdempotent() throws {
        let player = try makeRealPlayer()
        let hold = SlowMotionHold()

        hold.end()
        hold.begin(.forward, players: [player])
        hold.end()
        hold.end()

        XCTAssertEqual(player.rate, 0)
        XCTAssertFalse(hold.isActive)
    }

    /// The reverse fallback schedules a repeating `Timer` on the main run loop,
    /// and the run loop retains it — so a hold that is released mid-fallback,
    /// without `end()` ever being called, leaves that timer firing every 80ms
    /// for the rest of the session. `ComparisonModel` is what makes this
    /// reachable: unlike the viewer it has a real teardown, and its window can
    /// be closed with a key still held.
    ///
    /// The timer is held here on purpose — otherwise the only reference to it
    /// dies with the hold and there is nothing left to ask.
    func testDroppingTheHoldMidFallbackInvalidatesItsTimer() throws {
        let player = try makeUnloadablePlayer()
        var timer: Timer?
        autoreleasepool {
            let hold = SlowMotionHold()
            hold.begin(.backward, players: [player])
            timer = hold.reverseTimer
            XCTAssertEqual(timer?.isValid, true, "premise: the fallback timer must be scheduled")
        }

        XCTAssertEqual(timer?.isValid, false, "a dropped hold must not leave its timer firing")
    }

    /// Auto-repeat delivers more than one begin for one physical press. A
    /// second begin must not overwrite the captured rate, or `end()` would
    /// restore 0.35 instead of the rate the operator was watching at.
    func testASecondBeginIsIgnoredWhileAHoldIsActive() throws {
        let player = try makeRealPlayer()
        player.playImmediately(atRate: 1)
        let hold = SlowMotionHold()

        hold.begin(.forward, players: [player])
        hold.begin(.backward, players: [player])
        XCTAssertEqual(player.rate, 0.35, accuracy: 0.001,
                       "the second begin must not change direction")
        hold.end()

        XCTAssertEqual(player.rate, 1, accuracy: 0.001,
                       "the captured rate must survive the second begin")
    }
}
