import AppKit
import SkiVideoCore

/// Translates the app's `NSEvent` stream into `PlaybackIntent`s. This is the
/// macOS half of the `PlaybackInputSource` seam.
@MainActor
final class AppKitInputSource: PlaybackInputSource {
    var onIntent: ((PlaybackIntent) -> Void)?

    private var monitor: Any?
    private var resignObserver: Any?
    private var isEnabled = true

    /// Lets the Left/Right arrows through even while a text field holds focus.
    ///
    /// Off by default: the viewer's athlete-search field must keep the blanket
    /// exemption below, or arrow keys could not move the insertion point.
    ///
    /// The sorting window is the opposite case. It parks focus in the athlete
    /// TextField and keeps putting it back (`SortingSheet`'s `.onAppear` and
    /// `.onChange(of:)`), while advertising "←/→ seek 5s" — and SwiftUI's macOS
    /// field editor is an `NSTextView`, so the exemption would swallow the
    /// feature outright. The monitor this seam replaced had no exemption at all;
    /// this flag restores exactly the two keys it bound, and no others. Space in
    /// particular must keep the exemption, or an athlete named "Anna Marie"
    /// cannot be typed.
    var arrowsBypassTextFieldFocus = false

    /// Lets Left/Right *auto-repeat* fire a fresh `.seek` while held.
    ///
    /// Off by default, and it must stay off for the viewer, because
    /// `ViewerModel.performArrowTap` is stateful: it reads ±1s or ±5s out of a
    /// 0.38s double-tap window and cannot tell an auto-repeat from a deliberate
    /// second press. macOS delivers repeats roughly 90ms apart, so every repeat
    /// lands inside that window and the detector alternates — 1s, 5s, 1s, 5s —
    /// for as long as the key is down. Measured: about 31s of media moved per
    /// 1.3s of holding, with the status line strobing between two messages.
    /// One press, one seek is what the viewer wants, so the repeat is dropped.
    ///
    /// The sorting window is the opposite case, and the reason this is a flag
    /// rather than a blanket rule. `SortingModel.handle` answers `.seek` with a
    /// stateless `seek(±5)` — every intent is the same fixed jump, with no
    /// window to confuse — so repeats compose into the fast-scan the window
    /// advertises as "←/→ seek 5s", exactly as its original `NSEvent` monitor
    /// did with no `isARepeat` guard at all. `SortingWindowController.show` is
    /// the only opted-in instance; the viewer and the comparison window (whose
    /// `.seek` is a stateless ±1s) both keep the default.
    ///
    /// Arrow-only on purpose, matching the two keys that monitor bound. Space,
    /// the clip arrows and the page keys are one-shot actions and keep their
    /// repeat suppression unconditionally. A repeated arrow stays *consumed*
    /// whether or not the flag is set — that was already true — it is merely
    /// silent when it is off.
    var arrowsRepeat = false

    /// When set, only keys typed into this window are handled; every other
    /// window's keys pass through untouched.
    ///
    /// Needed because the monitor is app-wide and the newest monitor sees keys
    /// first. The sorting window's source is created after the viewer's and
    /// stays enabled until that window closes — through the whole upload tray
    /// after tagging — so, unscoped, it swallowed Space typed into the viewer
    /// and play/pause stopped working there. Nil keeps the app-wide
    /// behaviour, which the viewer's own source relies on.
    weak var ownWindow: NSWindow?

    /// Which arrow key is physically held for slow motion. Deliberately *not*
    /// the same fact as the model's `SlowMotionHold`, which is hold state: the
    /// model tears its hold down from `endSlowMotion()` whenever the library
    /// changes (`openDirectory`, `selectAthlete`, `changeVideo`,
    /// `openRemoteLibrary`) while the key is still held, and this copy must
    /// survive that so the eventual key-up is still consumed rather than
    /// leaking to the app.
    ///
    /// Collapsing the two would mean this source querying the model, reversing
    /// the seam's dependency direction.
    ///
    /// Set by ⌘+Left/⌘+Right only. A bare arrow seeks on key-down and never
    /// arms a hold, so it leaves this nil — which is what makes its key-up fall
    /// through the key-up switch's default instead of ending someone else's
    /// hold.
    private var heldDirection: ScrubDirection?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cancelHold()
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { cancelHold() }
    }

    /// Only the two arrows the sorting window's monitor used to bind, and only
    /// on an instance that asked for it.
    ///
    /// The name is still exact: what it exempts is the sorting window's ±5s
    /// seeks, and those are what a bare *unmodified* arrow now produces.
    ///
    /// Unmodified is load-bearing. Matching on the keyCode alone would let a ⌘
    /// chord clear the field-editor guard, reach the switch and be consumed —
    /// so ⌘← in the sorting window's athlete field, which the operator pressed
    /// to jump to the start of the line, would do nothing at all. The sorting
    /// window binds no chord and `SortingModel` drops the slow-motion intents,
    /// so there is nothing to be gained by admitting them either.
    ///
    /// Both event types bypass, but only the key-down produces anything now
    /// that a bare arrow seeks instead of arming a hold: nothing sets
    /// `heldDirection` for it, so its key-up falls through the key-up switch's
    /// default and is *not* consumed. That release leaks to the field editor,
    /// which is harmless — `NSTextView` acts on arrow key-downs and ignores
    /// arrow key-ups, so there is nothing for it to do with one. Do not read
    /// the old press/release pairing into this predicate; it was retired with
    /// the bare-arrow hold.
    private func bypassesTextFieldFocus(_ event: NSEvent) -> Bool {
        arrowsBypassTextFieldFocus
            && (event.keyCode == 123 || event.keyCode == 124)
            && event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    }

    private func cancelHold() {
        guard heldDirection != nil else { return }
        heldDirection = nil
        onIntent?(.slowMotionEnded)
    }

    private func emit(_ intent: PlaybackIntent) {
        onIntent?(intent)
    }

    /// The two arrows are the only keys Command means anything on. Control and
    /// Option are refused everywhere, and Command anywhere else belongs to the
    /// menu (⌘O, ⌘F) or to the system.
    private func isSlowMotionArrow(_ event: NSEvent) -> Bool {
        (event.keyCode == 123 || event.keyCode == 124)
            && event.modifierFlags.intersection([.command, .control, .option]) == [.command]
    }

    func handle(_ event: NSEvent) -> Bool {
        guard isEnabled else { return false }

        // A dropped Command ends the hold on its own. AppKit may withhold
        // `keyUp` while Command is down, and an operator can lift the modifier
        // first regardless — either way the hold must not outlive the chord.
        //
        // Never consumed. A flags change is how AppKit tracks modifier state
        // app-wide; swallowing it would leave menus and every other responder
        // believing Command is still down. This reads the event and lets it
        // through.
        //
        // Above the focus check on purpose. A flags change carries no keyCode
        // this source binds, so `bypassesTextFieldFocus` can never admit one:
        // put this below, and a hold begun before focus moved into a text field
        // would have no way left to end — neither the arrow's key-up nor the
        // dropped modifier would reach it. Ending a hold is not a keystroke the
        // field can have a claim on.
        if event.type == .flagsChanged {
            if heldDirection != nil, !event.modifierFlags.contains(.command) {
                cancelHold()
            }
            return false
        }

        // Below the flags-change branch: a hold must still be able to end
        // whichever window the modifier is lifted over.
        if let ownWindow, event.window !== ownWindow {
            return false
        }

        if event.window?.firstResponder is NSTextView, !bypassesTextFieldFocus(event) {
            return false
        }
        if !isSlowMotionArrow(event),
           !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            return false
        }

        // Keyed off the keyCode alone, never the modifier: by the time the
        // release arrives the operator may already have lifted Command, so the
        // key-up carries no flag to match on.
        if event.type == .keyUp {
            switch event.keyCode {
            case 123 where heldDirection == .backward,
                 124 where heldDirection == .forward:
                heldDirection = nil
                emit(.slowMotionEnded)
                return true
            default:
                return false
            }
        }

        switch event.keyCode {
        case 49: // Space
            if !event.isARepeat { emit(.togglePlayback) }
        case 126: // Up Arrow
            if !event.isARepeat { emit(.clip(.previous)) }
        case 125: // Down Arrow
            if !event.isARepeat { emit(.clip(.next)) }
        case 116: // Page Up
            if !event.isARepeat { emit(.athlete(.previous)) }
        case 121: // Page Down
            if !event.isARepeat { emit(.athlete(.next)) }
        // A repeat under Command is the same physical press, so it must not
        // re-begin the hold — `arrowsRepeat` is about the bare arrows and
        // deliberately does not reach these two cases. A second *arrow*
        // mid-hold must not steal it either — its release would then end a hold
        // it never began, and the real held arrow's release would do nothing.
        case 123 where isSlowMotionArrow(event):
            if !event.isARepeat, heldDirection == nil {
                heldDirection = .backward
                emit(.slowMotionBegan(.backward))
            }
        case 124 where isSlowMotionArrow(event):
            if !event.isARepeat, heldDirection == nil {
                heldDirection = .forward
                emit(.slowMotionBegan(.forward))
            }
        // The arrows are the one pair whose repeat can mean something, and only
        // where the receiving model is stateless enough to survive it — see
        // `arrowsRepeat`. The repeat stays consumed either way; the flag only
        // decides whether it also emits.
        case 123: // Left Arrow, unmodified
            if !event.isARepeat || arrowsRepeat { emit(.seek(.backward)) }
        case 124: // Right Arrow, unmodified
            if !event.isARepeat || arrowsRepeat { emit(.seek(.forward)) }
        default:
            return false
        }
        return true
    }

    /// Safety net. `ComparisonModel.close()` and `SortingModel.stopPlayback()`
    /// are what normally disable a source, and both run from SwiftUI's
    /// `onDisappear`. If that is ever missed, nothing else disables it — and it
    /// now consumes more keycodes than the monitors it replaced — so tear down
    /// unconditionally here as well.
    ///
    /// This is `setEnabled(false)` plus the two removals, not instead of them.
    /// It cannot literally call `setEnabled`: `deinit` is nonisolated and that
    /// method is main-actor isolated, so its effects are inlined. The
    /// `.slowMotionEnded` that `cancelHold` would emit is deliberately not sent — the
    /// consumer owns this source, so it is already gone or going by the time
    /// this runs, and `onIntent` is a main-actor closure that `deinit` has no
    /// guarantee of being on the main thread to call.
    ///
    /// Nothing double-removes. `isEnabled`/`heldDirection` are plain state; the
    /// two AppKit registrations are removed in exactly one place (here), reached
    /// once because `deinit` runs once, and both are `nil`-guarded. The normal
    /// teardown paths only ever call `setEnabled(false)`, which touches no
    /// registration, so they cannot race or duplicate this.
    deinit {
        isEnabled = false
        heldDirection = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}
