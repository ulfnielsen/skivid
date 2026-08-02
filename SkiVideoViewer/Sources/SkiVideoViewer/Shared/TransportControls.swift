import SkiVideoCore
import SwiftUI

/// The six transport buttons, shared by the comparison screen and the viewer.
///
/// Values and a closure, no model: the two screens have different models and
/// nothing here needs to know which one it is driving.
///
/// A `ForEach` over `allCases` rather than a restatement of the list —
/// `TransportAction`'s declaration order *is* left-to-right button order, and
/// the exhaustive `switch` in `appearance(of:)` means a case added to the model
/// cannot silently fail to appear here.
struct TransportControls: View {
    let isEnabled: Bool
    let perform: (TransportAction) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(TransportAction.allCases) { button($0) }
        }
    }

    private func button(_ action: TransportAction) -> some View {
        let appearance = Self.appearance(of: action)
        return Button {
            perform(action)
        } label: {
            Image(systemName: appearance.symbol)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(appearance.label)
        .accessibilityLabel(appearance.label)
        .disabled(!isEnabled)
    }

    /// `contentShape` above is deliberate and load-bearing: these are plain
    /// `Button`s, so it genuinely enlarges the hit region to 44×44. Do not copy
    /// it onto a `Picker` or a `Slider` — measured three times with dispatched
    /// `NSEvent` clicks, a parent's content shape cannot route hits into a child
    /// control's segments, and its only effect there is swallowing clicks meant
    /// for what sits behind.
    private static func appearance(of action: TransportAction) -> (symbol: String, label: String) {
        switch action {
        case .back5: return ("gobackward.5", "Back 5 seconds")
        case .back1: return ("gobackward.minus", "Back 1 second")
        case .playPause: return ("playpause.fill", "Play or pause")
        case .forward1: return ("goforward.plus", "Forward 1 second")
        case .forward5: return ("goforward.5", "Forward 5 seconds")
        // A one-shot action, not a toggle. The rate it sets lives on `AVPlayer`,
        // which publishes nothing — a toggle rendered from it would show stale
        // state whenever the periodic time observer is idle, which is precisely
        // while paused. The way back to 1× is play/pause. Labelled as the action
        // it is.
        case .slow: return ("tortoise.fill", "Play at quarter speed")
        }
    }
}
