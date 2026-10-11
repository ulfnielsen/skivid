import SwiftUI

extension View {
    /// The backing every chip that floats over video shares: a frosted shape
    /// that is dark in every appearance, with the chip's own content forced to
    /// the dark scheme so its glyphs, text and slider turn light on it.
    ///
    /// **Plain `.thinMaterial` follows the colour scheme**, and in light mode it
    /// is a LIGHT blur: over snow, which is most of what this app ever shows,
    /// white text on it was white on near-white (the operator's 2026-10-11
    /// screenshot; `ViewerCaptionLayoutTests` measured the capsule at 0.94 mean
    /// luminance in light appearance over a white backdrop). Rendering the
    /// material under a forced dark scheme is not enough on its own: a dark
    /// `.thinMaterial` over white measured 0.63 (`.regular` 0.56, `.thick`
    /// 0.48, `.ultraThick` 0.40), mid-grey under white text. A 50% black tint
    /// on top brings it to 0.35 while it stays frosted rather than a solid pill.
    ///
    /// Forcing the dark scheme on the content as well is what makes it work for
    /// controls that do not set their own colour — `ZoomControl`'s buttons and
    /// slider, the comparison screen's close glyph — which would otherwise draw
    /// black on the dark backing in light mode.
    func darkFrostedBacking<S: Shape>(in shape: S) -> some View {
        background {
            shape
                .fill(.thinMaterial)
                .overlay(shape.fill(Color.black.opacity(0.5)))
        }
        .environment(\.colorScheme, .dark)
    }
}
