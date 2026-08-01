import AVFoundation
import SkiVideoCore
import SwiftUI

/// Two clips drawn into the same rect, `bottomPlayer` beneath `topPlayer`.
/// Both use aspect-fit so neither is cropped and both occupy the same frame.
/// There is deliberately no spatial alignment.
///
/// This is SwiftUI rather than the two-`AVPlayerLayer` view macOS used, because
/// `CALayer.compositingFilter` is a silent no-op on iOS — measured on an iPad
/// Pro 11-inch (M5) simulator, where a red layer under a cyan one with
/// `CIDifferenceBlendMode` rendered the overlap plain cyan instead of white.
/// `.blendMode(.difference)` does work, including on `AVPlayerLayer`-backed
/// views: the same clips rendered white, and an `.opacity(0.5)` control
/// rendered grey. Do not "simplify" this back toward `compositingFilter`.
struct OverlayPlayerStack: View {
    let bottomPlayer: AVPlayer
    let topPlayer: AVPlayer
    /// Expected to be already resolved by the caller — `topLayerOpacity` on
    /// `ComparisonModel` is where "difference mode ignores the slider" lives.
    /// The body re-applies that rule anyway; see `body` for why that cannot
    /// drift.
    let topOpacity: Double
    let blend: OverlayBlend

    var body: some View {
        ZStack {
            Color.black
            SinglePlayerView(player: bottomPlayer)
            SinglePlayerView(player: topPlayer)
                // Difference blending is defined at full opacity, so force it
                // here as well as in the model. This cannot disagree with the
                // model: applying the branch to a value the model has already
                // forced to 1 is idempotent. It is defence in depth against a
                // future call site passing `overlayOpacity` instead of
                // `topLayerOpacity` — that would give a translucent difference
                // blend with no compile error and no failing test.
                //
                // The clamp is the one thing kept from the macOS view's
                // `apply(topOpacity:blend:)`: `CALayer.opacity` was clamped
                // there, and SwiftUI's `.opacity` is undefined outside 0...1.
                .opacity(blend == .difference ? 1 : max(0, min(1, topOpacity)))
                .blendMode(blend == .difference ? .difference : .normal)
        }
        // Insurance, not a load-bearing fix. Deleting it was tested on iPad and
        // gave pixel-identical output with no backdrop leak — the opaque
        // `Color.black` at the bottom of this `ZStack` already bounds what the
        // blend can see. Kept so the bound does not depend on that one child
        // staying opaque.
        .compositingGroup()
    }
}
