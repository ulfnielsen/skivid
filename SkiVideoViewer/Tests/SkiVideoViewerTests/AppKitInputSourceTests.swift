import AppKit
import SkiVideoCore
import XCTest
@testable import SkiVideoViewer

@MainActor
final class AppKitInputSourceTests: XCTestCase {
    private func key(
        _ code: UInt16,
        type: NSEvent.EventType = .keyDown,
        modifiers: NSEvent.ModifierFlags = [],
        isARepeat: Bool = false
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: isARepeat,
            keyCode: code
        )!
    }

    private func capture(
        _ events: [NSEvent],
        configure: (AppKitInputSource) -> Void = { _ in }
    ) -> [PlaybackIntent] {
        let source = AppKitInputSource()
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }
        configure(source)
        for event in events { _ = source.handle(event) }
        return captured
    }

    func testSpaceEmitsTogglePlayback() {
        let intents = capture([key(49)])
        XCTAssertEqual(intents.count, 1)
        guard case .togglePlayback = intents[0] else {
            return XCTFail("expected togglePlayback, got \(intents[0])")
        }
    }

    func testArrowsEmitClipSteps() {
        let intents = capture([key(126), key(125)])
        guard case let .clip(up) = intents[0], case let .clip(down) = intents[1] else {
            return XCTFail("expected two clip intents, got \(intents)")
        }
        XCTAssertEqual(up, .previous)
        XCTAssertEqual(down, .next)
    }

    func testPageKeysEmitAthleteSteps() {
        let intents = capture([key(116), key(121)])
        guard case let .athlete(up) = intents[0], case let .athlete(down) = intents[1] else {
            return XCTFail("expected two athlete intents, got \(intents)")
        }
        XCTAssertEqual(up, .previous)
        XCTAssertEqual(down, .next)
    }

    func testArrowDownThenUpEmitsScrubPairWithTap() {
        let intents = capture([key(124), key(124, type: .keyUp)])
        XCTAssertEqual(intents.count, 2)
        guard case let .scrubBegan(began) = intents[0],
              case let .scrubEnded(ended, performTap) = intents[1]
        else {
            return XCTFail("expected a scrub pair, got \(intents)")
        }
        XCTAssertEqual(began, .forward)
        XCTAssertEqual(ended, .forward)
        XCTAssertTrue(performTap, "a released key is a tap")
    }

    func testKeyUpWithoutMatchingKeyDownEmitsNothing() {
        XCTAssertTrue(capture([key(123, type: .keyUp)]).isEmpty)
    }

    func testModifiedKeysAreIgnored() {
        // Cmd-O and Cmd-F belong to the menu, not to playback.
        XCTAssertTrue(capture([key(49, modifiers: .command)]).isEmpty)
        XCTAssertTrue(capture([key(125, modifiers: .option)]).isEmpty)
        XCTAssertTrue(capture([key(124, modifiers: .control)]).isEmpty)
    }

    func testAutorepeatDoesNotRetrigger() {
        XCTAssertTrue(capture([key(49, isARepeat: true)]).isEmpty)
        XCTAssertTrue(capture([key(125, isARepeat: true)]).isEmpty)
    }

    func testDisabledSourceEmitsNothing() {
        let intents = capture([key(49), key(125)]) { $0.setEnabled(false) }
        XCTAssertTrue(intents.isEmpty)
    }

    func testDisablingMidHoldCancelsWithoutTap() {
        let source = AppKitInputSource()
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }

        _ = source.handle(key(123))     // press and hold Left
        source.setEnabled(false)        // e.g. a modal sheet opens

        XCTAssertEqual(captured.count, 2)
        guard case let .scrubEnded(direction, performTap) = captured[1] else {
            return XCTFail("expected a cancelling scrubEnded, got \(captured)")
        }
        XCTAssertEqual(direction, .backward)
        XCTAssertFalse(performTap, "a cancelled hold must not seek")
    }

    /// Added beyond the brief's set: the `where heldDirection == …` guards mean
    /// a key-up for the arrow that is *not* held must be ignored entirely, so a
    /// stray release cannot end someone else's scrub.
    func testKeyUpForTheOppositeArrowDoesNotEndTheHold() {
        let source = AppKitInputSource()
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }

        _ = source.handle(key(123))                          // hold Left
        XCTAssertFalse(
            source.handle(key(124, type: .keyUp)),
            "releasing Right while Left is held is not ours to consume"
        )
        XCTAssertEqual(captured.count, 1, "only the scrubBegan should have been emitted")

        _ = source.handle(key(123, type: .keyUp))            // release Left
        XCTAssertEqual(captured.count, 2)
        guard case let .scrubEnded(direction, performTap) = captured[1] else {
            return XCTFail("expected a scrubEnded, got \(captured)")
        }
        XCTAssertEqual(direction, .backward)
        XCTAssertTrue(performTap)
    }

    func testUnhandledKeyIsNotConsumed() {
        let source = AppKitInputSource()
        XCTAssertFalse(source.handle(key(0)), "'a' must pass through to the app")
        XCTAssertTrue(source.handle(key(49)), "space must be consumed")
    }
}
