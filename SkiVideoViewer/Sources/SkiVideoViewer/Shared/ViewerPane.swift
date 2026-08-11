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
    /// The pane's measured size, reported upward on every layout.
    ///
    /// `ContentView` holds it and hands it to `ViewerControlBar`, which is
    /// where the zoom control lives: the bar is this pane's *sibling* and has
    /// no geometry that describes the video, but `setZoomScale` re-clamps the
    /// pan against the pane. Defaulted so the wiring tests that host this pane
    /// on its own stay honest about not consuming the size.
    var onPaneSizeChange: (CGSize) -> Void = { _ in }

    /// Where the current drag had reached at its previous change.
    ///
    /// `DragGesture` reports `translation` from where the drag *began*, not
    /// since the last change, so this is what turns it into a per-change delta.
    /// See `panGesture`.
    @State private var lastDrag: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            SinglePlayerView(player: model.player, zoom: model.zoom)
                // Tap to play/pause: the one universal video gesture, and
                // without it the video is inert to touch. Still the only
                // *unconditional* gesture here — swipe-for-clip and
                // edge-hold-to-shuttle would duplicate controls the bar already
                // carries.
                .contentShape(Rectangle())
                .onTapGesture { model.applyTransport(.playPause) }
                // Only installed while zoomed, so at 1x it cannot swallow
                // anything meant for the tap above.
                .gesture(model.zoom.isZoomed ? panGesture(in: proxy.size) : nil)
                .onAppear { onPaneSizeChange(proxy.size) }
                .onChange(of: proxy.size) { onPaneSizeChange($0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) { caption }
        .overlay(alignment: .topTrailing) { statusChip }
    }

    /// A drag pans, and each step is relative to the previous one — SwiftUI
    /// reports the translation from where the drag *began*, so feeding it
    /// straight to `panZoom` would re-apply the whole distance on every change
    /// and run away. Measured in
    /// `ZoomWiringTests.testDraggingThePanePansByEachStepsDeltaRatherThanTheWholeTranslation`:
    /// a 60pt drag in three steps lands `center.x` on 0.5375 with the
    /// subtraction and 0.575 — a 60pt drag moving the picture 120pt — without.
    private func panGesture(in paneSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let delta = CGSize(
                    width: value.translation.width - lastDrag.width,
                    height: value.translation.height - lastDrag.height
                )
                lastDrag = value.translation
                model.panZoom(by: delta, in: paneSize)
            }
            .onEnded { _ in lastDrag = .zero }
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
    ///
    /// `.frame(maxWidth: 320)` sits on the `Text`, *before* the padding and
    /// background — matching `ComparisonStatusChip`, and not the order
    /// review caught here originally. After the background it caps the
    /// transparent container the capsule sits inside rather than the capsule
    /// itself, which lets the pill grow and shrink with every word in
    /// `model.status` instead of holding a constant width. Measured in an
    /// 800pt container: with the frame after the background the pill's right
    /// edge moved ~70pt as the status text changed; with it here, first, the
    /// width is constant.
    private var statusChip: some View {
        Text(model.status)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
            .frame(maxWidth: 320)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(12)
            .allowsHitTesting(false)
            .accessibilityLabel("Status: \(model.status)")
    }
}
