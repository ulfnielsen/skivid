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

/// Is this a phone, in either orientation?
///
/// Compact in *either* axis: upright a phone is compact width, sideways it is
/// compact height (and, on the larger models, regular width). An iPad is
/// regular in both except in narrow multitasking splits, which want the same
/// economy anyway. Always false on the Mac.
extension EnvironmentValues {
    var isPhoneSized: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact || verticalSizeClass == .compact
        #else
        false
        #endif
    }
}
