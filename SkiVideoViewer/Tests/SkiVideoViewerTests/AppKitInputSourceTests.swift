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
        isARepeat: Bool = false,
        windowNumber: Int = 0
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: isARepeat,
            keyCode: code
        )!
    }

    /// An off-screen window whose first responder really is an `NSTextView`,
    /// which is what SwiftUI's macOS `TextField` installs as its field editor.
    /// Events built with `windowNumber: window.windowNumber` resolve back to it
    /// through `NSEvent.window`, so `handle`'s focus check is genuinely reached
    /// — the rest of this file uses `windowNumber: 0`, where `event.window` is
    /// nil and that check can never fire.
    private func makeWindowWithFocusedTextView() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        window.contentView = textView
        XCTAssertTrue(window.makeFirstResponder(textView), "could not focus the text view")
        XCTAssertTrue(window.firstResponder is NSTextView, "the fixture must model a focused field")
        return window
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
        XCTAssertEqual(intents.count, 2)
        guard intents.count == 2 else { return }
        guard case let .clip(up) = intents[0], case let .clip(down) = intents[1] else {
            return XCTFail("expected two clip intents, got \(intents)")
        }
        XCTAssertEqual(up, .previous)
        XCTAssertEqual(down, .next)
    }

    func testPageKeysEmitAthleteSteps() {
        let intents = capture([key(116), key(121)])
        XCTAssertEqual(intents.count, 2)
        guard intents.count == 2 else { return }
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

    /// Regression test for the guard that `ViewerModel.beginArrow` has always
    /// had (`heldDirection == nil`) and that must survive the move into the
    /// input source. Pressing a second arrow mid-hold must not steal
    /// `heldDirection`, or that arrow's *release* ends a scrub it never began —
    /// and the real held arrow's release then does nothing.
    func testSecondArrowPressedMidHoldNeitherStartsNorEndsAScrub() {
        let source = AppKitInputSource()
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }

        _ = source.handle(key(123))                          // press and hold Left
        XCTAssertEqual(captured.count, 1, "only Left's scrubBegan so far")

        _ = source.handle(key(124))                          // press Right mid-hold
        XCTAssertEqual(captured.count, 1, "Right must not begin a second scrub")

        XCTAssertFalse(
            source.handle(key(124, type: .keyUp)),
            "releasing Right while Left is held is not ours to consume"
        )
        XCTAssertEqual(captured.count, 1, "Right's release must not end Left's scrub")

        _ = source.handle(key(123, type: .keyUp))            // release Left
        XCTAssertEqual(captured.count, 2)
        guard case let .scrubEnded(direction, performTap) = captured[1] else {
            return XCTFail("expected a scrubEnded, got \(captured)")
        }
        XCTAssertEqual(direction, .backward, "Left's release ends Left's scrub")
        XCTAssertTrue(performTap)
    }

    // MARK: - Text-field focus

    /// The default. The viewer's athlete-search field needs arrows to move its
    /// insertion point, so a focused text view suppresses everything.
    func testFocusedTextFieldSwallowsEverythingByDefault() {
        let window = makeWindowWithFocusedTextView()
        let event = key(123, windowNumber: window.windowNumber)
        XCTAssertTrue(
            event.window?.firstResponder is NSTextView,
            "premise: the event must resolve to the focused window, or this test proves nothing"
        )

        let source = AppKitInputSource()
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }

        XCTAssertFalse(source.handle(event), "a focused field owns the key")
        XCTAssertTrue(captured.isEmpty)
    }

    /// Regression: the sorting window parks focus in its athlete TextField and
    /// keeps putting it back, while advertising "←/→ seek 5s". Routed through
    /// this seam unchanged, the exemption above ate that feature — the model's
    /// `handle(_:)` was never reached. The opt-in restores exactly the two keys
    /// the sorting window's own `NSEvent` monitor used to bind.
    func testOptedInSourceDeliversArrowsThroughAFocusedTextField() {
        let window = makeWindowWithFocusedTextView()
        let source = AppKitInputSource()
        source.arrowsBypassTextFieldFocus = true
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }

        XCTAssertTrue(source.handle(key(123, windowNumber: window.windowNumber)))
        XCTAssertTrue(source.handle(key(123, type: .keyUp, windowNumber: window.windowNumber)))
        XCTAssertTrue(source.handle(key(124, windowNumber: window.windowNumber)))
        XCTAssertTrue(source.handle(key(124, type: .keyUp, windowNumber: window.windowNumber)))

        XCTAssertEqual(captured.count, 4)
        guard captured.count == 4,
              case let .scrubBegan(firstBegan) = captured[0],
              case let .scrubEnded(firstEnded, _) = captured[1],
              case let .scrubBegan(secondBegan) = captured[2],
              case let .scrubEnded(secondEnded, _) = captured[3]
        else {
            return XCTFail("expected two scrub pairs, got \(captured)")
        }
        XCTAssertEqual(firstBegan, .backward)
        XCTAssertEqual(firstEnded, .backward, "a bypassed press must have a bypassed release")
        XCTAssertEqual(secondBegan, .forward)
        XCTAssertEqual(secondEnded, .forward)
    }

    /// The opt-in is arrow-specific on purpose. Space above all must still reach
    /// the field, or an athlete named "Anna Marie" cannot be typed.
    func testOptedInSourceStillLetsEveryOtherKeyReachAFocusedTextField() {
        let window = makeWindowWithFocusedTextView()
        let source = AppKitInputSource()
        source.arrowsBypassTextFieldFocus = true
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }

        for code in [UInt16(49), 126, 125, 116, 121] {
            XCTAssertFalse(
                source.handle(key(code, windowNumber: window.windowNumber)),
                "keyCode \(code) belongs to the text field while it has focus"
            )
        }
        XCTAssertTrue(captured.isEmpty, "unexpected intents: \(captured)")
    }

    /// The opt-in must not change anything when no text field has focus.
    func testOptedInSourceBehavesNormallyWithoutTextFieldFocus() {
        let intents = capture([key(49)]) { $0.arrowsBypassTextFieldFocus = true }
        XCTAssertEqual(intents.count, 1)
        guard case .togglePlayback = intents[0] else {
            return XCTFail("expected togglePlayback, got \(intents[0])")
        }
    }

    func testUnhandledKeyIsNotConsumed() {
        let source = AppKitInputSource()
        XCTAssertFalse(source.handle(key(0)), "'a' must pass through to the app")
        XCTAssertTrue(source.handle(key(49)), "space must be consumed")
    }
}
