import SkiVideoCore
import SwiftUI

/// Overlay-only: how strongly the top clip is drawn, and in which mode.
///
/// The slider is disabled in difference mode because `topLayerOpacity` forces
/// 1.0 there — an enabled control that does nothing is exactly what this
/// redesign is removing. The explanatory sentence the old bar carried beside it
/// is gone with the rest of the hint text; the disabled state says the same
/// thing without a row.
///
/// No `contentShape(Rectangle())` on the picker or the slider. Measured in
/// Task 2: a parent's content shape cannot route a hit into a child control's
/// segments — it only swallows clicks in the surrounding band, which here is
/// the video. Do not add it.
struct OverlayBlendBar: View {
    @ObservedObject var model: ComparisonModel

    var body: some View {
        HStack(spacing: 16) {
            Text("Left").font(.caption).foregroundStyle(.secondary)
            Slider(value: $model.overlayOpacity, in: 0...1)
                .disabled(model.blend == .difference)
                .accessibilityLabel("Blend between left and right")
            Text("Right").font(.caption).foregroundStyle(.secondary)

            Picker("Blend mode", selection: $model.blend) {
                ForEach(OverlayBlend.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
        }
        .padding(.horizontal, 12)
    }
}
