import AppKit
import SkiVideoCore
import XCTest
@testable import SkiVideoViewer

/// Drives a real `AppKitInputSource` into a real `ViewerModel`, so the
/// key-code mapping and the playback state machine are exercised together.
/// `AppKitInputSourceTests` covers the mapping in isolation; nothing else
/// covers the pair, which is how the mid-hold `heldDirection` regression got
/// past the first round of tests.
///
/// This lives in the app test target rather than `SkiVideoCoreTests` because
/// `ViewerModel` is still an app-target type until Task 6, and
/// `@testable import SkiVideoViewer` reaches it today — no dependency on
/// Task 4's `folderPicker` or Task 6's move.
@MainActor
final class AppKitInputToModelTests: XCTestCase {
    private var temporaryDirectory: URL?

    /// Deterministic stand-in for `Date.init` so the 0.38s double-tap window
    /// does not depend on how fast the test host runs.
    private final class Clock {
        private(set) var current = Date(timeIntervalSince1970: 1_000)
        func advance(by interval: TimeInterval) {
            current = current.addingTimeInterval(interval)
        }
        var now: () -> Date { { [self] in current } }
    }

    override func tearDown() async throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    /// `VideoLibrary.scan` only inspects file extensions, so empty files are
    /// enough to give the model a `currentVideo`. No playable media is needed:
    /// `seek` records the requested offset before it touches the player.
    private func makeLibrary() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let athlete = root.appendingPathComponent("Idun", isDirectory: true)
        try FileManager.default.createDirectory(at: athlete, withIntermediateDirectories: true)
        for name in ["a.mp4", "b.mp4"] {
            FileManager.default.createFile(
                atPath: athlete.appendingPathComponent(name).path,
                contents: Data()
            )
        }
        temporaryDirectory = root
        return root
    }

    /// A long hold threshold keeps every arrow press in this file a *tap*: the
    /// hold work item is scheduled on the main queue and these tests never
    /// yield, but being explicit keeps them immune to that detail.
    private func makeStack() throws -> (ViewerModel, AppKitInputSource, Clock) {
        let source = AppKitInputSource()
        let clock = Clock()
        let model = ViewerModel(input: source, now: clock.now, holdThreshold: 60)
        model.openDirectory(try makeLibrary())
        return (model, source, clock)
    }

    private func key(
        _ code: UInt16,
        type: NSEvent.EventType = .keyDown
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: code
        )!
    }

    private func tapRightArrow(_ source: AppKitInputSource) {
        _ = source.handle(key(124))
        _ = source.handle(key(124, type: .keyUp))
    }

    func testSingleTapSeeksOneSecond() throws {
        let (model, source, _) = try makeStack()

        tapRightArrow(source)

        XCTAssertEqual(model.lastSeekOffset ?? .nan, 1.0, accuracy: 0.0001)
        XCTAssertEqual(model.status, "Forward 1 seconds")
    }

    /// The one sanctioned behaviour change in this task: the double-tap seek
    /// was 4.0 seconds while the status text it set already said "5 seconds".
    func testDoubleTapWithinWindowSeeksFiveSecondsMatchingItsStatusText() throws {
        let (model, source, clock) = try makeStack()

        tapRightArrow(source)
        clock.advance(by: 0.2)   // inside the 0.38s window
        tapRightArrow(source)

        XCTAssertEqual(
            model.lastSeekOffset ?? .nan, 5.0, accuracy: 0.0001,
            "the seek must match the status text, which has always claimed 5 seconds"
        )
        XCTAssertEqual(model.status, "Forward 5 seconds")
    }

    func testTapsOutsideTheWindowStaySingleTaps() throws {
        let (model, source, clock) = try makeStack()

        tapRightArrow(source)
        clock.advance(by: 0.5)   // outside the 0.38s window
        tapRightArrow(source)

        XCTAssertEqual(model.lastSeekOffset ?? .nan, 1.0, accuracy: 0.0001)
        XCTAssertEqual(model.status, "Forward 1 seconds")
    }

    /// End-to-end form of the mid-hold regression: with Left held, pressing and
    /// releasing Right must change nothing, and releasing Left must still seek
    /// backward one second. Before the fix the Right *release* ended the scrub
    /// early and the Left release did nothing at all.
    func testReleasingASecondArrowMidHoldDoesNotEndTheScrub() throws {
        let (model, source, _) = try makeStack()

        _ = source.handle(key(123))                  // press and hold Left
        _ = source.handle(key(124))                  // press Right mid-hold
        _ = source.handle(key(124, type: .keyUp))    // release Right

        XCTAssertNil(model.lastSeekOffset, "nothing about Right may seek")

        _ = source.handle(key(123, type: .keyUp))    // release Left

        XCTAssertEqual(model.lastSeekOffset ?? .nan, -1.0, accuracy: 0.0001)
        XCTAssertEqual(model.status, "Back 1 seconds")
    }

    func testClipKeysAdvanceAndWrapTheVideoIndex() throws {
        let (model, source, _) = try makeStack()

        XCTAssertEqual(model.videoIndex, 0)
        _ = source.handle(key(125))   // Down Arrow
        XCTAssertEqual(model.videoIndex, 1)
        _ = source.handle(key(125))
        XCTAssertEqual(model.videoIndex, 0, "should wrap")
        _ = source.handle(key(126))   // Up Arrow
        XCTAssertEqual(model.videoIndex, 1, "should wrap backwards")
    }

    func testDisablingKeyboardControlsStopsTheSource() throws {
        let (model, source, _) = try makeStack()

        model.setKeyboardControlsEnabled(false)
        tapRightArrow(source)

        XCTAssertNil(model.lastSeekOffset, "a disabled source must not reach the model")
    }
}
