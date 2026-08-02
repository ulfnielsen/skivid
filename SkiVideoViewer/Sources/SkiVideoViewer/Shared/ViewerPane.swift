import SkiVideoCore
import SwiftUI

/// The video, its caption and the one touch gesture.
///
/// The athlete name and clip description used to be two rows of the control
/// band. Over the letterbox they cost nothing: the comparison screen's
/// equivalent caption measured 29.0pt minimum height, identical to a plain
/// `Text`, because the letterbox area already exists.
struct ViewerPane: View {
    @ObservedObject var model: ViewerModel
    let athleteName: String

    var body: some View {
        NativePlayerView(player: model.player)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Tap to play/pause: the one universal video gesture, and without it
            // the video is inert to touch. Deliberately the *only* gesture here
            // — swipe-for-clip and edge-hold-to-shuttle would duplicate controls
            // the bar already carries.
            .contentShape(Rectangle())
            .onTapGesture { model.applyTransport(.playPause) }
            .overlay(alignment: .bottomLeading) { caption }
            .overlay(alignment: .topTrailing) { statusChip }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(athleteName)
                .font(.headline)
            Text(model.clipDescription)
                .font(.caption)
        }
        .foregroundStyle(.white.opacity(0.85))
        .shadow(radius: 2)
        .padding(12)
        .allowsHitTesting(false)
    }

    /// Capped and non-hit-testable for the same two reasons the comparison
    /// screen's chip is: unbounded it runs past the video's edge, and
    /// hit-testable it eats taps meant for the video underneath — which here is
    /// the play/pause gesture.
    private var statusChip: some View {
        Text(model.status)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.45), in: Capsule())
            .frame(maxWidth: 320)
            .padding(12)
            .allowsHitTesting(false)
            .accessibilityLabel("Status: \(model.status)")
    }
}
