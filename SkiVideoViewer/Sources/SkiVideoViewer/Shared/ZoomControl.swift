import SkiVideoCore
import SwiftUI

/// Zoom out, a slider, zoom in, and the level — which is itself the reset.
///
/// Values and a closure, no model, exactly as `TransportControls`: the viewer
/// and the two comparison panes have different models and nothing here needs to
/// know which one it is driving.
///
/// **The level is a button on purpose.** Double-clicking the video also resets,
/// but adding a double-tap beside the viewer's existing single-tap play/pause
/// makes SwiftUI wait to see whether a second tap is coming. This is the route
/// that does not depend on gesture arbitration, and if that delay measures
/// perceptible the double-click goes and this stays.
struct ZoomControl: View {
    let zoom: VideoZoom
    let isEnabled: Bool
    let onScale: (Double) -> Void
    let onReset: () -> Void

    /// Coarse enough that the buttons reach 4x in six presses, fine enough to
    /// frame two clips to the same size.
    private static let step = 0.5

    @Environment(\.isShortOnHeight) private var isShortOnHeight

    /// 44 is Apple's touch minimum and the right default. Sideways on a phone
    /// this control floats *over* the video, so every point it takes is a point
    /// of the run the coach is trying to look at — 36 is still a comfortable
    /// thumb target for a control you press twice.
    private var buttonSide: CGFloat { isShortOnHeight ? 36 : 44 }

    static func label(for scale: Double) -> String {
        String(format: "%.1f×", scale)
    }

    var body: some View {
        HStack(spacing: isShortOnHeight ? 0 : 4) {
            stepButton("minus.magnifyingglass", "Zoom out", to: zoom.scale - Self.step)
            // The slider is the first thing to go when room is short: it is the
            // convenience, not the capability. Minus, plus and the reset
            // readout still reach every scale in the range, and the chip stops
            // eating a third of a sideways phone's video.
            if !isShortOnHeight {
                Slider(
                    value: Binding(get: { zoom.scale }, set: onScale),
                    in: VideoZoom.range
                )
                .frame(minWidth: 80)
                .accessibilityLabel("Zoom")
            }
            stepButton("plus.magnifyingglass", "Zoom in", to: zoom.scale + Self.step)
            Button {
                onReset()
            } label: {
                Text(Self.label(for: zoom.scale))
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: isShortOnHeight ? 38 : 44, minHeight: buttonSide)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Reset zoom")
            .accessibilityLabel("Reset zoom, currently \(Self.label(for: zoom.scale))")
            .disabled(!isEnabled)
        }
        .disabled(!isEnabled)
    }

    private func stepButton(_ symbol: String, _ label: String, to scale: Double) -> some View {
        Button {
            onScale(scale)
        } label: {
            Image(systemName: symbol)
                .frame(width: buttonSide, height: buttonSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
        .disabled(!isEnabled)
    }
}
