import SkiVideoCore
import SwiftUI

/// The video, its caption, its zoom chip and the two touch gestures.
///
/// The athlete name and clip description used to be two rows of the control
/// band. Over the letterbox they cost nothing: the comparison screen's
/// equivalent caption measured 29.0pt minimum height, identical to a plain
/// `Text`, because the letterbox area already exists. The zoom chip is here
/// for the same reason and on the strength of the same argument, measured a
/// second time — see `zoomChip(in:)`.
struct ViewerPane: View {
    @ObservedObject var model: ViewerModel
    let athleteName: String

    /// Where the current drag had reached at its previous change.
    ///
    /// `DragGesture` reports `translation` from where the drag *began*, not
    /// since the last change, so this is what turns it into a per-change delta.
    /// See `panGesture`.
    @State private var lastDrag: CGSize = .zero

    /// **One `GeometryReader`, three consumers.** The drag, the zoom chip's
    /// slider and the model call underneath both of them all need the pane's
    /// size — `VideoZoom` clamps the pan against it — and reading it in one
    /// place here is what keeps that size out of `ContentView` and out of the
    /// control bar. An earlier round relayed it to `ViewerControlBar` through
    /// `ContentView` because the control lived in the bar; moving the control
    /// onto the video removed the relay along with the layout cost.
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
                // After the gestures, so the chip is layered above them and
                // takes its own clicks rather than the video's play/pause —
                // measured in `ZoomWiringTests`, both directions.
                .overlay(alignment: .bottomTrailing) { zoomChip(in: proxy.size) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) { caption }
        .overlay(alignment: .topTrailing) { statusChip }
    }

    /// The zoom control, over the letterbox rather than in the control bar.
    ///
    /// **It was in `ViewerControlBar` first, and a measurement is why it
    /// moved.** There it pushed the bar's ideal width from 557.0pt to 793.0pt,
    /// which is above the 744pt iPad mini portrait width: the bar took its
    /// `ViewThatFits` fallback and the scrubber-plus-bar band grew from 104pt
    /// to 156pt — taller than the ~130pt control band an earlier redesign
    /// deleted, and spent on the smallest screen, where video area is
    /// scarcest. Over the letterbox it costs no layout height at all. Same
    /// reasoning, and the same `.thinMaterial` capsule, as `ClipSourceMenu`'s
    /// chip on the comparison panes.
    ///
    /// **Hit-testable, unlike the caption and the status chip beside it.**
    /// Those two carry `.allowsHitTesting(false)` because they are decoration
    /// floating over the play/pause tap, and a chip that claimed hits would eat
    /// it. This one is a control: it has to receive its own clicks, so it keeps
    /// the tap safe by *position* rather than by declining hits — it occupies
    /// one corner and the video's tap target is everything else. Both halves
    /// are measured in `ZoomWiringTests`: a click on the chip leaves
    /// `player.rate` at 0, and a click on the pane's centre still toggles it.
    ///
    /// Bottom-trailing specifically, because the other two corners in use are
    /// bottom-leading (the caption) and top-trailing (the status chip).
    ///
    /// `.frame(maxWidth: 220)` for the same reason the status chip is capped:
    /// unbounded, the control's own ideal width is 224pt and it would grow into
    /// the caption on a narrow pane.
    private func zoomChip(in paneSize: CGSize) -> some View {
        ZoomControl(
            zoom: model.zoom,
            isEnabled: model.currentPlaybackURL != nil,
            // Out-of-range requests — the minus button at 1.0x, the plus button
            // at 4.0x — reach the model unfiltered on purpose: `setScale` clamps
            // to `VideoZoom.range` unconditionally, so the range is enforced in
            // exactly one place and no call site restates it.
            onScale: { model.setZoomScale($0, in: paneSize) },
            onReset: { model.resetZoom() }
        )
        .frame(maxWidth: 220)
        .padding(.horizontal, 8)
        .background(.thinMaterial, in: Capsule())
        .padding(12)
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
