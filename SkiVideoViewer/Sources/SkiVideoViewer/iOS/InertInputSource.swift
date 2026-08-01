import SkiVideoCore

/// Phase 3 has no iPad input source. Touch gestures and hardware-keyboard
/// support arrive in phase 4; until then the app is driven entirely by the
/// on-screen list and transport buttons, and this emits nothing.
@MainActor
final class InertInputSource: PlaybackInputSource {
    var onIntent: ((PlaybackIntent) -> Void)?
    func setEnabled(_ enabled: Bool) {}
}
