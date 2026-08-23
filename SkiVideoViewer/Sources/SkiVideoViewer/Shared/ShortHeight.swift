import SwiftUI

/// Is there very little vertical room?
///
/// Landscape on a phone, and nothing else: iPad and Mac always report regular
/// height, so every use of this reads false there and the layouts they were
/// measured against do not move.
///
/// Height, not width. A phone turned sideways is *wider* than it was — the
/// horizontal size class stays compact but the pressure moves to the other
/// axis, and a coach holding the phone that way is doing it to make the video
/// bigger. Everything that is not the video should ask for less.
extension EnvironmentValues {
    var isShortOnHeight: Bool {
        #if os(iOS)
        verticalSizeClass == .compact
        #else
        false
        #endif
    }
}
