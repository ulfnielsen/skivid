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
        if event.window?.firstResponder is NSTextView { return false }
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
        case 123: // Left Arrow
            if !event.isARepeat {
                heldDirection = .backward
                emit(.scrubBegan(.backward))
            }
        case 124: // Right Arrow
            if !event.isARepeat {
                heldDirection = .forward
                emit(.scrubBegan(.forward))
            }
        default:
            return false
        }
        return true
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}
