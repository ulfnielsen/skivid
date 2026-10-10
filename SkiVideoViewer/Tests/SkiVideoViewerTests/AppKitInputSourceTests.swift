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

    private func flagsChanged(
        modifiers: NSEvent.ModifierFlags,
        windowNumber: Int = 0
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 55   // Left Command
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

    /// Regression: the sorting window's source stays enabled for as long as
    /// that window is open — including the whole upload tray after tagging.
    /// Unscoped, it answered Space typed into the viewer for the sorting
    /// player. (That was half of "Space does nothing in the viewer"; the other
    /// half was `ContentView` switching the viewer's own source off — see
    /// `AppKitInputSource.ownWindow`.)
    func testASourceScopedToItsWindowLetsOtherWindowsKeysThrough() {
        let own = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let source = AppKitInputSource()
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }
        source.ownWindow = own

        let elsewhere = key(49, windowNumber: other.windowNumber)
        XCTAssertTrue(elsewhere.window === other, "premise: the event must resolve to the other window")
        XCTAssertFalse(source.handle(elsewhere), "Space in another window must reach that window")
        XCTAssertTrue(captured.isEmpty)

        XCTAssertTrue(source.handle(key(49, windowNumber: own.windowNumber)))
        XCTAssertEqual(captured.count, 1, "Space in its own window still toggles playback")
    }

    /// The macOS arrangement once the viewer stays live beside the sorting and
    /// comparison windows: one source per window, each scoped to its own.
    /// Space in either window must toggle exactly that window's playback and
    /// leave the other's alone, whichever monitor AppKit happens to call first.
    func testTwoScopedSourcesEachHandleOnlyTheirOwnWindowsSpace() {
        let viewerWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
                                    styleMask: [.titled], backing: .buffered, defer: false)
        let sortingWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        let viewer = AppKitInputSource()
        let sorting = AppKitInputSource()
        var viewerIntents = 0
        var sortingIntents = 0
        viewer.onIntent = { _ in viewerIntents += 1 }
        sorting.onIntent = { _ in sortingIntents += 1 }
        viewer.ownWindow = viewerWindow
        sorting.ownWindow = sortingWindow

        let inViewer = key(49, windowNumber: viewerWindow.windowNumber)
        XCTAssertFalse(sorting.handle(inViewer), "the sorting source must let the viewer's Space through")
        XCTAssertTrue(viewer.handle(inViewer))
        let inSorting = key(49, windowNumber: sortingWindow.windowNumber)
        XCTAssertFalse(viewer.handle(inSorting), "the viewer source must let the sorting window's Space through")
        XCTAssertTrue(sorting.handle(inSorting))

        XCTAssertEqual(viewerIntents, 1)
        XCTAssertEqual(sortingIntents, 1)
    }

    /// `ownWindow` is weak. Once the window it named is gone, a scoped source
    /// must not quietly fall back to the app-wide behaviour of a source that
    /// was never scoped — that would put it back in front of every other
    /// window's keys, the very thing scoping exists to stop.
    func testASourceWhoseWindowHasGoneHandlesNothing() {
        let source = AppKitInputSource()
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }
        autoreleasepool {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            source.ownWindow = window
        }
        XCTAssertNil(source.ownWindow, "premise: the window must really be gone")
        XCTAssertFalse(source.handle(key(49)), "Space must pass through to whoever owns it now")
        XCTAssertTrue(captured.isEmpty)
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

    func testBareArrowSeeksOnKeyDownAndIsSilentOnKeyUp() {
        let source = AppKitInputSource()
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }

        XCTAssertTrue(source.handle(key(124)))
        XCTAssertEqual(captured.count, 1)
        guard case let .seek(direction) = captured[0] else {
            return XCTFail("expected a seek, got \(captured)")
        }
        XCTAssertEqual(direction, .forward)

        XCTAssertFalse(
            source.handle(key(124, type: .keyUp)),
            "a bare arrow's release is not ours to consume"
        )
        XCTAssertEqual(captured.count, 1)
    }

    func testKeyUpWithoutMatchingKeyDownEmitsNothing() {
        XCTAssertTrue(capture([key(123, type: .keyUp)]).isEmpty)
    }

    func testModifiedKeysAreIgnored() {
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
    func testOptedInSourceDeliversArrowSeeksThroughAFocusedTextField() {
        let window = makeWindowWithFocusedTextView()
        let source = AppKitInputSource()
        source.arrowsBypassTextFieldFocus = true
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }

        XCTAssertTrue(source.handle(key(123, windowNumber: window.windowNumber)))
        XCTAssertTrue(source.handle(key(124, windowNumber: window.windowNumber)))

        XCTAssertEqual(captured.count, 2)
        guard captured.count == 2,
              case let .seek(first) = captured[0],
              case let .seek(second) = captured[1]
        else {
            return XCTFail("expected two seeks, got \(captured)")
        }
        XCTAssertEqual(first, .backward)
        XCTAssertEqual(second, .forward)
    }

    /// The bypass predicate still matches arrow key-*ups*, so what happens to
    /// one is decided entirely by the key-up switch's default — and a bare
    /// arrow never sets `heldDirection`, so it lands there. The release is
    /// therefore neither consumed nor announced, and it leaks to the field
    /// editor. That is deliberate and harmless: `NSTextView` acts on arrow
    /// key-downs and ignores arrow key-ups, so there is nothing for it to do
    /// with one.
    ///
    /// Pinned separately because the press/release pairing this seam used to
    /// guarantee is retired, and a reader of `bypassesTextFieldFocus` could
    /// otherwise still take it for a live invariant.
    func testBypassedArrowKeyUpIsNeitherConsumedNorEmitted() {
        let window = makeWindowWithFocusedTextView()
        let source = AppKitInputSource()
        source.arrowsBypassTextFieldFocus = true
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }

        XCTAssertTrue(source.handle(key(124, windowNumber: window.windowNumber)))
        XCTAssertEqual(captured.count, 1, "the press seeks")

        XCTAssertFalse(
            source.handle(key(124, type: .keyUp, windowNumber: window.windowNumber)),
            "a bypassed arrow release is not ours to consume"
        )
        XCTAssertEqual(captured.count, 1, "and it emits nothing: \(captured)")
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

    // MARK: - Arrow auto-repeat

    /// Regression guard for the runaway held arrow. `ViewerModel
    /// .performArrowTap` is stateful: it reads ±1s or ±5s out of a 0.38s
    /// double-tap window and cannot tell an auto-repeat from a deliberate
    /// second press. macOS delivers repeats ~90ms apart, so every repeat lands
    /// inside that window and the seek alternates 1s, 5s, 1s, 5s — about 31s of
    /// media per 1.3s of holding, with the status line strobing between two
    /// messages. The viewer opts into nothing, so its repeats must stay silent.
    ///
    /// Consumed but silent, not ignored: the app must never see the repeat
    /// either, or the arrow reaches whatever else binds it.
    ///
    /// No text-view fixture on purpose: the viewer sets no bypass, so a focused
    /// field would swallow these events before the repeat guard is reached and
    /// the test would prove nothing.
    func testDefaultSourceDropsArrowRepeatsSoAHeldArrowCannotRunAway() {
        for code in [UInt16(123), 124] {
            let source = AppKitInputSource()
            var captured: [PlaybackIntent] = []
            source.onIntent = { captured.append($0) }

            XCTAssertTrue(source.handle(key(code)))
            XCTAssertEqual(captured.count, 1, "keyCode \(code): the press itself seeks once")

            XCTAssertTrue(
                source.handle(key(code, isARepeat: true)),
                "keyCode \(code): a repeat must stay consumed, just silent"
            )
            XCTAssertTrue(source.handle(key(code, isARepeat: true)))
            XCTAssertEqual(
                captured.count, 1,
                "keyCode \(code): repeats must not reach the double-tap detector: \(captured)"
            )
        }
    }

    /// The other direction, and the reason the opt-in exists. The sorting
    /// window fast-scans a clip by holding an arrow, as its original `NSEvent`
    /// monitor did with no `isARepeat` guard at all. That is safe there and
    /// only there because `SortingModel` answers every `.seek` with the same
    /// stateless ±5s jump — there is no window for a repeat to fall inside.
    func testOptedInSourceEmitsASeekForEveryArrowRepeat() {
        for code in [UInt16(123), 124] {
            let expected: ScrubDirection = code == 123 ? .backward : .forward
            let source = AppKitInputSource()
            source.arrowsRepeat = true
            var captured: [PlaybackIntent] = []
            source.onIntent = { captured.append($0) }

            // Press, then hold through two repeats.
            XCTAssertTrue(source.handle(key(code)))
            XCTAssertTrue(source.handle(key(code, isARepeat: true)))
            XCTAssertTrue(source.handle(key(code, isARepeat: true)))

            XCTAssertEqual(
                captured.count, 3,
                "keyCode \(code): each repeat is another seek: \(captured)"
            )
            guard captured.count == 3 else { return }
            for (index, intent) in captured.enumerated() {
                guard case let .seek(direction) = intent else {
                    return XCTFail("keyCode \(code): intent \(index) is not a seek: \(captured)")
                }
                XCTAssertEqual(direction, expected)
            }
        }
    }

    /// `arrowsRepeat` is arrow-only, matching the two keys the sorting window's
    /// monitor bound. Space, the clip arrows and the page keys are all one-shot
    /// actions; repeating them would page through the library at the key-repeat
    /// rate.
    ///
    /// Again no text-view fixture: none of these keys is bypassed, so a focused
    /// field would swallow them for the wrong reason.
    func testArrowRepeatOptInDoesNotUnlockRepeatsForAnyOtherKey() {
        for code in [UInt16(49), 126, 125, 116, 121] {
            let source = AppKitInputSource()
            source.arrowsBypassTextFieldFocus = true
            source.arrowsRepeat = true
            var captured: [PlaybackIntent] = []
            source.onIntent = { captured.append($0) }

            XCTAssertTrue(source.handle(key(code)))
            XCTAssertEqual(captured.count, 1, "keyCode \(code): the first press still acts")

            XCTAssertTrue(source.handle(key(code, isARepeat: true)))
            XCTAssertEqual(
                captured.count, 1,
                "keyCode \(code) must stay one-shot under arrowsRepeat: \(captured)"
            )
        }
    }

    // MARK: - Cmd+Arrow slow motion

    func testCommandArrowBeginsAndEndsSlowMotion() {
        let source = AppKitInputSource()
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }

        XCTAssertTrue(source.handle(key(124, modifiers: .command)))
        XCTAssertTrue(source.handle(key(124, type: .keyUp, modifiers: .command)))

        XCTAssertEqual(captured.count, 2)
        guard captured.count == 2,
              case let .slowMotionBegan(direction) = captured[0],
              case .slowMotionEnded = captured[1]
        else {
            return XCTFail("expected a slow-motion pair, got \(captured)")
        }
        XCTAssertEqual(direction, .forward)
    }

    /// AppKit may withhold `keyUp` while Command is down, and an operator can
    /// lift Command before the arrow in any case. Dropping the modifier must
    /// end the hold on its own.
    func testReleasingCommandEndsTheHold() {
        let source = AppKitInputSource()
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }

        XCTAssertTrue(source.handle(key(123, modifiers: .command)))
        XCTAssertFalse(
            source.handle(flagsChanged(modifiers: [])),
            "the hold ends, but the flags change still belongs to AppKit"
        )

        XCTAssertEqual(captured.count, 2)
        guard case .slowMotionEnded = captured[1] else {
            return XCTFail("expected slowMotionEnded, got \(captured)")
        }
    }

    /// And the release that follows must not end it a second time — a doubled
    /// end would restore the pre-hold rate twice, and the second restore reads
    /// a rate the hold itself set.
    func testTheHoldEndsExactlyOnceWhenCommandIsReleasedFirst() {
        let source = AppKitInputSource()
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }

        _ = source.handle(key(123, modifiers: .command))
        _ = source.handle(flagsChanged(modifiers: []))
        XCTAssertFalse(
            source.handle(key(123, type: .keyUp)),
            "the hold is already over; this release is not ours"
        )

        XCTAssertEqual(captured.count, 2, "exactly one begin and one end: \(captured)")
    }

    func testCommandArrowRepeatsDoNotRebeginTheHold() {
        let source = AppKitInputSource()
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }

        _ = source.handle(key(124, modifiers: .command))
        _ = source.handle(key(124, modifiers: .command, isARepeat: true))
        _ = source.handle(key(124, modifiers: .command, isARepeat: true))

        XCTAssertEqual(captured.count, 1, "one physical press is one hold: \(captured)")
    }

    /// `arrowsRepeat` unlocks repeats for the *bare* arrows, whose repeat means
    /// another seek in the sorting window. A ⌘+arrow repeat is a different
    /// thing entirely — the same physical press, still held — so the flag must
    /// not reach it. One press is one hold on every instance.
    func testCommandArrowRepeatsAreStillOneHoldForAnOptedInSource() {
        let source = AppKitInputSource()
        source.arrowsRepeat = true
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }

        _ = source.handle(key(123, modifiers: .command))
        _ = source.handle(key(123, modifiers: .command, isARepeat: true))
        _ = source.handle(key(123, modifiers: .command, isARepeat: true))

        XCTAssertEqual(captured.count, 1, "arrowsRepeat must not re-begin a hold: \(captured)")
    }

    /// A second arrow pressed mid-hold must not steal the hold, or its release
    /// ends a hold it never began and the real held arrow's release does
    /// nothing. This is the Cmd-era replacement for the guard the bare arrows
    /// used to need.
    func testASecondCommandArrowMidHoldNeitherBeginsNorEnds() {
        let source = AppKitInputSource()
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }

        _ = source.handle(key(123, modifiers: .command))
        XCTAssertEqual(captured.count, 1)

        _ = source.handle(key(124, modifiers: .command))
        XCTAssertEqual(captured.count, 1, "the second arrow must not begin a hold")

        XCTAssertFalse(
            source.handle(key(124, type: .keyUp, modifiers: .command)),
            "releasing the second arrow is not ours to consume"
        )
        XCTAssertEqual(captured.count, 1)

        _ = source.handle(key(123, type: .keyUp, modifiers: .command))
        XCTAssertEqual(captured.count, 2)
        guard case .slowMotionEnded = captured[1] else {
            return XCTFail("the held arrow's release ends the hold, got \(captured)")
        }
    }

    func testDisablingMidHoldEndsIt() {
        let source = AppKitInputSource()
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }

        _ = source.handle(key(123, modifiers: .command))
        source.setEnabled(false)

        XCTAssertEqual(captured.count, 2)
        guard case .slowMotionEnded = captured[1] else {
            return XCTFail("expected a cancelling slowMotionEnded, got \(captured)")
        }
    }

    /// Command is meaningful on the two arrows only. Cmd-O and Cmd-F belong to
    /// the menu, and Cmd-Space to the system.
    func testCommandIsIgnoredOnEveryOtherKey() {
        for code in [UInt16(49), 126, 125, 116, 121] {
            XCTAssertTrue(
                capture([key(code, modifiers: .command)]).isEmpty,
                "keyCode \(code) must not act under Command"
            )
        }
    }

    /// Regression: the bypass matched on the keyCode alone, so a ⌘ chord
    /// cleared the field-editor guard, reached the switch and was consumed —
    /// and ⌘← in the sorting window's athlete field, which every macOS user
    /// presses to jump to the start of a line, did nothing at all. Before the ⌘
    /// bindings the blanket modifier gate refused the event and the field editor
    /// got it; this restores that.
    func testCommandArrowsReachAFocusedTextFieldEvenOnAnOptedInSource() {
        let window = makeWindowWithFocusedTextView()
        let source = AppKitInputSource()
        source.arrowsBypassTextFieldFocus = true
        source.arrowsRepeat = true
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }

        for code in [UInt16(123), 124] {
            XCTAssertFalse(
                source.handle(key(code, modifiers: .command, windowNumber: window.windowNumber)),
                "⌘ + keyCode \(code) belongs to the field editor, not to slow motion"
            )
        }
        XCTAssertTrue(captured.isEmpty, "no hold may start inside a text field: \(captured)")
    }

    func testControlAndOptionAreStillRefusedOnTheArrows() {
        XCTAssertTrue(capture([key(124, modifiers: .control)]).isEmpty)
        XCTAssertTrue(capture([key(124, modifiers: .option)]).isEmpty)
        XCTAssertTrue(capture([key(124, modifiers: [.command, .option])]).isEmpty)
    }

    // MARK: - Teardown

    /// `deinit` is the safety net for a source whose window never delivered
    /// `onDisappear` — it stops the source consuming keys app-wide even then.
    /// That only helps if `deinit` is actually reached, so pin the thing that
    /// would silently disable it: the monitor and the resign observer must keep
    /// capturing `self` weakly. A strong capture leaks the source, and a leaked
    /// source swallows Space and the arrows for the rest of the session.
    func testSourceDeallocatesSoItsTeardownIsReached() {
        weak var weakSource: AppKitInputSource?
        autoreleasepool {
            let source = AppKitInputSource()
            source.onIntent = { _ in }
            _ = source.handle(key(123))  // dealloc after it has consumed a key
            weakSource = source
        }
        XCTAssertNil(weakSource, "a retained source outlives its window and keeps eating keys")
    }

    func testUnhandledKeyIsNotConsumed() {
        let source = AppKitInputSource()
        XCTAssertFalse(source.handle(key(0)), "'a' must pass through to the app")
        XCTAssertTrue(source.handle(key(49)), "space must be consumed")
    }
}
