import XCTest
@testable import SkiVideoViewer

/// The bookkeeping behind keeping an iPhone awake while a batch uploads. The
/// UIKit flag itself cannot be reached from a macOS test, so a plain variable
/// stands in for `UIApplication.isIdleTimerDisabled`.
@MainActor
final class ScreenAwakeHoldTests: XCTestCase {
    private var flag = false
    private func makeHold() -> ScreenAwakeHold {
        ScreenAwakeHold(read: { self.flag }, write: { self.flag = $0 })
    }

    func testHoldingDisablesTheIdleTimerAndReleasingRestoresIt() {
        let hold = makeHold()
        hold.acquire()
        XCTAssertTrue(flag)
        hold.release()
        XCTAssertFalse(flag)
    }

    /// Something else — a video playing full screen — may already have the
    /// timer off. A finished upload must leave it the way it found it.
    func testReleasingRestoresWhatWasThereBefore() {
        flag = true
        let hold = makeHold()
        hold.acquire()
        hold.release()
        XCTAssertTrue(flag)
    }

    /// The session tray and the history tray can both be on screen; the
    /// first to finish must not let the phone lock under the other.
    func testTheTimerStaysOffUntilTheLastHolderReleases() {
        let hold = makeHold()
        hold.acquire()
        hold.acquire()
        hold.release()
        XCTAssertTrue(flag, "one batch is still running")
        hold.release()
        XCTAssertFalse(flag)
    }

    func testAnUnmatchedReleaseChangesNothing() {
        flag = true
        let hold = makeHold()
        hold.release()
        XCTAssertTrue(flag)
    }
}
