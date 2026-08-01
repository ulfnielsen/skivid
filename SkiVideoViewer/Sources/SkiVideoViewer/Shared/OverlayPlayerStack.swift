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
    /// Already resolved by the caller — `ComparisonModel.topLayerOpacity` is
    /// where "difference mode ignores the slider" lives, so this view does not
    /// branch on `blend` a second time. Two copies of that rule would drift.
    let topOpacity: Double
    let blend: OverlayBlend

    var body: some View {
        ZStack {
            Color.black
            SinglePlayerView(player: bottomPlayer)
            SinglePlayerView(player: topPlayer)
                // The clamp is the one thing kept from the macOS view's
                // `apply(topOpacity:blend:)`: `CALayer.opacity` was clamped
                // there, and SwiftUI's `.opacity` is undefined outside 0...1.
                .opacity(max(0, min(1, topOpacity)))
                .blendMode(blend == .difference ? .difference : .normal)
        }
        // Without this the blend composites against everything behind the
        // stack, not just the bottom player.
        .compositingGroup()
    }
}
