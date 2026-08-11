import SkiVideoCore
import SwiftUI

/// One clip in side-by-side layout: the video, its name over the letterbox,
/// and the control that loads or replaces it.
///
/// The filename sits over the letterbox rather than in a header row, so it
/// costs no layout height; an empty pane puts its Choose control in the middle
/// of itself for the same reason. Those two header rows were the largest single
/// piece of chrome this redesign reclaims.
///
/// Both states are `ClipSourceMenu` now — same routes, two appearances — so the
/// side-by-side panes and the overlay layout offer the same ways to load a clip
/// by construction rather than by two lists staying in step.
struct ComparisonPane: View {
    @ObservedObject var model: ComparisonModel
    let side: ComparisonSide

    /// Where the current drag had reached at its previous change, so that
    /// `DragGesture`'s translation-from-the-start becomes a per-change delta.
    ///
    /// **`@GestureState` rather than `@State` with an `onEnded` reset, which is
    /// a measured bug and not a style preference** — see `ViewerPane.lastDrag`,
    /// which carries the measurement. The short version: `@GestureState`
    /// reverts when the gesture ends *or is cancelled*, and only the second of
    /// those covers `panGesture` being removed out from under a live drag,
    /// which happens here whenever the pane drops to 1×. A stale running total
    /// then sends the next drag the wrong way — 0.475 against 0.5125 on the
    /// harness, a leftward drag moving the picture 40pt right.
    ///
    /// One per pane rather than one per side, because each pane is its own
    /// `View` value with its own gesture; the two never share a drag.
    @GestureState private var lastDrag: CGSize = .zero

    private var name: String {
        side == .left ? model.leftName : model.rightName
    }

    private var isLoaded: Bool {
        ClipSourceMenu.isLoaded(model, side)
    }

    /// **One `GeometryReader`, two consumers**, exactly as `ViewerPane`: the
    /// drag and the chip's slider both have to tell the model how large *this
    /// pane* is, since `VideoZoom` clamps the pan against it. It has to be the
    /// pane's own size and not the window's — the panes are half the width of
    /// the pair — and reading it here is what keeps that number out of
    /// `ComparisonView`.
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                Color.black
                SinglePlayerView(
                    player: side == .left ? model.leftPlayer : model.rightPlayer,
                    zoom: model.zoom(for: side)
                )
                // Only installed while this side is zoomed. Unlike the viewer's
                // pane there is no tap gesture here for it to compete with, but
                // it is still conditional: at 1× there is nothing to pan, and
                // an always-live drag recognizer over the video would be one
                // more thing between the operator and the chooser chip.
                .gesture(model.zoom(for: side).isZoomed ? panGesture(in: proxy.size) : nil)

                if isLoaded {
                    loadedName
                } else {
                    emptyChooser
                }
            }
            .overlay(alignment: .bottomTrailing) { zoomChip(in: proxy.size) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The zoom control, over the letterbox and in the corner the pane's other
    /// chips leave free.
    ///
    /// Bottom-*trailing* specifically: `loadedName` is bottom-leading and the
    /// empty pane's chooser is centred, so this is the corner that is free on a
    /// pane of any usual width — see the arithmetic below for the narrow ones,
    /// where it and the filename menu do meet. The 8pt inset is `loadedName`'s,
    /// for the same reason —
    /// placement is the pane's decision, not the chip's — and it is the
    /// comparison screen's spacing rather than the viewer's 12pt, which is
    /// insetting from a window edge instead of from a pane boundary.
    ///
    /// **Disabled while this pane is empty**, matching the viewer's chip: with
    /// no clip loaded there is nothing to magnify, and a live control would let
    /// the operator drag the level to 2.5× over a black rectangle. The
    /// comparison window *opens* in that state on both sides, so it is the
    /// ordinary case here rather than an edge one.
    ///
    /// `.frame(maxWidth: 220)` as in `ViewerPane`: the control's own ideal
    /// width is 224pt, and a pane is half a window wide.
    ///
    /// **It shares the pane's bottom edge with the filename menu, and unlike
    /// the viewer's caption that menu is a control — so where they meet is
    /// arithmetic worth stating rather than a cosmetic detail.** Measured on a
    /// hosted pane with a long filename: `ClipSourceMenu`'s `overlayChip` is a
    /// constant 297pt wide (the same at 400, 600 and 800pt panes, so it is
    /// capped rather than growing with the name) and so occupies 305pt of
    /// leading width with its 8pt inset; this chip's capsule occupies 246pt of
    /// trailing width. They therefore meet only on a pane narrower than
    /// **551pt** — a comparison window under about 1100pt. At 400pt they
    /// overlap by 151pt and this chip, being the later view, takes the clicks
    /// in the shared strip; the menu keeps its leading 146pt, which is still
    /// more than the 44pt tap target it was given, so the route to swapping a
    /// clip narrows but does not close. Neither of the pane's other corners is
    /// free to move to: `ComparisonView` puts its status chip over the panes'
    /// top-trailing and its close button over their top-leading.
    ///
    /// **VoiceOver hears "Zoom" from both panes with nothing to tell them
    /// apart**, where `ClipSourceMenu.spokenLabel` deliberately names the side
    /// for the choosers. Naming it here would mean a label parameter on
    /// `ZoomControl`, which is shared with the viewer where there is no side to
    /// name; it is left for whoever adds one rather than guessed at here.
    private func zoomChip(in paneSize: CGSize) -> some View {
        ZoomControl(
            zoom: model.zoom(for: side),
            isEnabled: isLoaded,
            // Out-of-range requests — the minus button at 1.0×, the plus button
            // at 4.0× — reach the model unfiltered on purpose: `setScale`
            // clamps to `VideoZoom.range` unconditionally, so the range is
            // enforced in exactly one place and no call site restates it.
            onScale: { model.setZoomScale($0, in: paneSize, side: side) },
            onReset: { model.resetZoom(side: side) }
        )
        .frame(maxWidth: 220)
        .padding(.horizontal, 8)
        .background(.thinMaterial, in: Capsule())
        .padding(8)
    }

    /// A drag pans this side, each step relative to the previous one: SwiftUI
    /// reports the translation from where the drag *began*, so feeding it
    /// straight to `panZoom` would re-apply the whole distance on every change
    /// and run away — 120pt of pan for a 60pt drag, accelerating the further
    /// the operator drags.
    ///
    /// `updating`, not `onChanged` with an `onEnded` reset; see `lastDrag`.
    private func panGesture(in paneSize: CGSize) -> some Gesture {
        DragGesture()
            .updating($lastDrag) { value, lastDrag, _ in
                let delta = CGSize(
                    width: value.translation.width - lastDrag.width,
                    height: value.translation.height - lastDrag.height
                )
                lastDrag = value.translation
                model.panZoom(by: delta, in: paneSize, side: side)
            }
    }

    /// The filename is also the way to swap this side's clip. Deleting the
    /// header row deleted the only route to "From Open Folder…" and to loading
    /// a second clip into a pane that already has one — and comparing one run
    /// against several others is the whole workflow. A menu on the name keeps
    /// both routes at zero layout cost, which is the point of the redesign;
    /// dropping them would have been a feature deletion the spec never asked
    /// for.
    ///
    /// **It kept the route and lost the affordance.** At `.caption`, white on
    /// black, with the chevron the only hint that it was pressable, the
    /// operator's report was "I don't see a way to select the comparison video
    /// anymore" — the control was there and read as a caption. `overlayChip`
    /// is the same placement, at zero layout cost still, wearing a material
    /// capsule and a 44pt tap target. The 8pt inset lives here rather than in
    /// the chip because it is a placement decision, exactly as `ComparisonView`
    /// insets the status chip.
    ///
    /// The pane's own title needs no side prefix — which pane it is in says
    /// that — so this passes the bare filename and lets `ClipSourceMenu` name
    /// the side in the spoken label alone.
    private var loadedName: some View {
        ClipSourceMenu(model: model, side: side, appearance: .overlayChip, title: name)
            .padding(8)
    }

    /// The two panes read identically until clips are loaded, so the
    /// accessibility label names the side while the visible title stays the
    /// spec's "Choose Clip". That is not decoration: it is the only thing that
    /// distinguishes the panes to VoiceOver *or* to a test, and without it a
    /// pane wired to the wrong side is invisible to both. Mutation-verified —
    /// building both panes with `side: .left` passed every assertion before
    /// this label existed. See `ClipSourceMenu.spokenLabel`, which now owns it.
    private var emptyChooser: some View {
        ClipSourceMenu(
            model: model,
            side: side,
            appearance: .prominent,
            title: ClipSourceMenu.chooseTitle
        )
    }
}
