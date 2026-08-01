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

    /// Lets Left/Right *auto-repeat* fire a fresh `.scrubBegan` while held.
    ///
    /// Off by default, and it must stay off for the viewer: its hold-to-slow-scrub
    /// state machine (`ViewerModel.beginArrow`/`endArrow`) is armed by
    /// `.scrubBegan` and disarmed by the paired `.scrubEnded`, so a repeated
    /// begin would re-enter the hold and break the pairing.
    ///
    /// The sorting window is again the opposite case. The monitor this seam
    /// replaced bound Left/Right with *no* `isARepeat` guard, so holding an arrow
    /// repeat-fired `seek(±5)` at the system key-repeat rate — that is how the
    /// window fast-scans a clip. `SortingModel.handle` acts on `.scrubBegan`
    /// only and ignores `.scrubEnded`, so one repeated begin is exactly one
    /// `seek(±5)` and nothing else: the old behaviour, reproduced.
    ///
    /// Arrow-only on purpose, matching the two keys that monitor bound. Space,
    /// the clip arrows and the page keys keep their repeat suppression.
    var arrowsRepeat = false

    /// Which arrow key is physically down. Deliberately *not* the same fact as
    /// `ViewerModel.heldDirection`, which is scrub state: the model clears its
    /// copy from `endArrow(performTap:false)` whenever the library changes
    /// (`openDirectory`, `selectAthlete`, `changeVideo`, `connectGoogleDrive`)
    /// while the key is still held, and this copy must survive that so the
    /// eventual key-up is still consumed rather than leaking to the app.
    ///
    /// Collapsing the two would mean this source querying the model, reversing
    /// the seam's dependency direction. `AppKitInputToModelTests
    /// .testReleasingASecondArrowMidHoldDoesNotEndTheScrub` is what pins the
    /// two copies together; neither file's own tests can see them drift.
    private var heldDirection: ScrubDirection?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp]
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
    /// on an instance that asked for it. Both key-down and key-up bypass, so a
    /// consumed press is always matched by a consumed release.
    private func bypassesTextFieldFocus(_ event: NSEvent) -> Bool {
        arrowsBypassTextFieldFocus && (event.keyCode == 123 || event.keyCode == 124)
    }

    private func cancelHold() {
        guard let direction = heldDirection else { return }
        heldDirection = nil
        onIntent?(.scrubEnded(direction, performTap: false))
    }

    private func emit(_ intent: PlaybackIntent) {
        onIntent?(intent)
    }

    func handle(_ event: NSEvent) -> Bool {
        guard isEnabled else { return false }
        if event.window?.firstResponder is NSTextView, !bypassesTextFieldFocus(event) {
            return false
        }
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            return false
        }

        if event.type == .keyUp {
            switch event.keyCode {
            case 123 where heldDirection == .backward:
                heldDirection = nil
                emit(.scrubEnded(.backward, performTap: true))
                return true
            case 124 where heldDirection == .forward:
                heldDirection = nil
                emit(.scrubEnded(.forward, performTap: true))
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
        // The `heldDirection == nil` guard mirrors the one `ViewerModel.beginArrow`
        // has always had. Without it a second arrow pressed mid-hold would steal
        // `heldDirection`, and its release would then end a scrub it never began.
        //
        // A repeat under `arrowsRepeat` deliberately leaves `heldDirection`
        // alone: the key is already down and its press/release pairing is already
        // recorded, so re-entering the hold-begin path would corrupt it. Repeats
        // stay consumed either way — that was already true before the flag.
        case 123: // Left Arrow
            if event.isARepeat {
                if arrowsRepeat { emit(.scrubBegan(.backward)) }
            } else if heldDirection == nil {
                heldDirection = .backward
                emit(.scrubBegan(.backward))
            }
        case 124: // Right Arrow
            if event.isARepeat {
                if arrowsRepeat { emit(.scrubBegan(.forward)) }
            } else if heldDirection == nil {
                heldDirection = .forward
                emit(.scrubBegan(.forward))
            }
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
    /// `.scrubEnded` that `cancelHold` would emit is deliberately not sent — the
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
