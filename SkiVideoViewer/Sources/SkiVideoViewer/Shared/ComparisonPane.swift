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
    /// Forwarded to this pane's `ClipSourceMenu` — see `ComparisonView.prepare`
    /// for where it comes from. Defaulted, not required: `ZoomWiringTests`
    /// builds panes directly to drive zoom and never picks a clip through the
    /// menu, so it has nothing to supply here and must not need to.
    var prepare: ClipPreparer = .none

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
                // Double-click resets this side, a faster route to the same
                // thing the chip's level readout does.
                //
                // **It is here and deliberately *not* on `ViewerPane`, on a
                // measurement.** A `count: 2` tap makes SwiftUI hold every
                // single tap until the double-click window closes. Measured on
                // a hosted pane in a real window, macOS 26.5, load average 18,
                // five synthetic single clicks each: with a single tap alone
                // the action ran in a median **1.2 ms**; with a `count: 2` tap
                // beside it, **358 ms** — 2.4× the 150 ms the plan called
                // perceptible, and identical whether the double-tap is declared
                // before or after the single one. `ViewerPane`'s single tap is
                // play/pause, the most-used gesture in the app, so it keeps the
                // fast tap and loses the double-click; this pane has no single
                // tap to hold up, so the gesture is free here. The asymmetry is
                // the measurement's — see the comment on `ViewerPane.body`.
                //
                // **And it is free in the other direction too**: the `count: 2`
                // tap costs `panGesture` nothing, though the two share this
                // view. Measured mouse-down to the pan actually moving, ten
                // drags each — 7.6 ms with the tap installed, 6.1 ms with it
                // deleted. Noise, not arbitration.
                //
                // Ahead of the drag because a double-click while zoomed is
                // exactly when this is wanted, and it survives that: measured
                // at 4× with `panGesture` installed, the drag does not swallow
                // the double-click. **The reason is not `minimumDistance`**,
                // which is the obvious guess and is wrong — with the drag set
                // to `minimumDistance: 0` both double-click tests still pass.
                // What was measured is simply that the tap wins arbitration for
                // a sequence with no movement in it, at a threshold of 0 as
                // well as at the default 10pt. So a finer pan is free to lower
                // that threshold without taking the reset with it.
                .onTapGesture(count: 2) { model.resetZoom(side: side) }
                // Only installed while this side is zoomed. Unlike the viewer's
                // pane there is no *single*-tap gesture here for it to compete
                // with, but it is still conditional: at 1× there is nothing to
                // pan, and an always-live drag recognizer over the video would
                // be one more thing between the operator and the chooser chip.
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
    /// empty pane's chooser is centred, so this is the furthest corner from
    /// both — though it does reach the filename menu across the bottom edge
    /// once a name is long enough, which is measured and accounted for below.
    /// The 8pt inset is `loadedName`'s, for the same reason —
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
    /// **`.frame(maxWidth: 220)` is load-bearing, and not because 220 is a
    /// width anything ends up being.** `ZoomControl`'s slider is greedy, so
    /// without a cap the chip stretches across the whole pane — measured, an
    /// 800pt pane: a 768pt control in a 784pt capsule with the cap removed,
    /// against 224pt in a 240pt capsule with it.
    /// The cap cannot squeeze *below* the control's intrinsic 224pt
    /// (3 × 44pt buttons + 80pt slider + 3 × 4pt spacing), so what it actually
    /// does is pin the control to that minimum, and 224 — not 220 — is what
    /// renders. `ViewerPane` carries the same modifier for the same reason.
    ///
    /// **It shares the pane's bottom edge with the filename menu, which unlike
    /// the viewer's caption is a *control*. The two do overlap, and that was
    /// accepted deliberately on the numbers below rather than overlooked — do
    /// not "fix" it by moving the chip.**
    ///
    /// `ClipSourceMenu`'s `overlayChip` grows with the filename (measured:
    /// 76pt at 5 characters, 94pt at 8, 257pt at 33, 388pt at 55), so there is
    /// no single width at which the two meet — the question is how much of the
    /// menu stays live. This chip's capsule takes 245.5pt of trailing width
    /// (224pt control, 8pt of inner padding each side, a 5.5pt outer margin)
    /// and the menu starts 8.5pt from the leading edge, so the menu always
    /// keeps its **leading 244.5pt** and it is the tail of a long name that
    /// goes behind the glass. Measured on a 498.5pt pane — what the panes are
    /// at the macOS 1000pt window floor, once the split's 1pt `Divider` and the
    /// `HStack`'s two 1pt gaps come off:
    ///
    /// | filename chip | covered | still live |
    /// | ------------------ | ------- | ------ |
    /// | 33 chars (257pt)   | 12.5pt  | 244.5pt |
    /// | 55 chars (388pt)   | 143.5pt | 244.5pt |
    /// | empty pane         | none    | — the prominent chooser centres vertically, clear of this chip's [8, 52] band |
    ///
    /// Overlap therefore begins at about a 31-character name, and 244.5pt is
    /// **5.5× the 44pt minimum target**. Full occlusion would need a pane of
    /// 254pt or less — a window of about 511pt, below the 1000pt floor
    /// `ComparisonView` enforces on macOS. iPadOS has no floor and its narrow
    /// case is an 11-inch iPad in portrait: 834pt gives 415.5pt panes and
    /// 161.5pt of live menu, still 3.7× the minimum. So the route to swapping a
    /// clip never closes at any shipped size, which is what made the overlap
    /// acceptable.
    ///
    /// The covered strip is genuinely dead rather than merely obscured — the
    /// frosted capsule takes hits across its whole extent, not only
    /// where its controls are. Measured: a click 4pt inside the capsule's
    /// leading edge, in its padding and clear of every button and the slider,
    /// reached the menu 0 times; the same click at x = 20 reached it once.
    ///
    /// Neither of the pane's other corners is free to move to in any case:
    /// `ComparisonView` overlays its status chip on the panes' top-trailing and
    /// its close button on their top-leading.
    ///
    /// **VoiceOver hears two identical sets of "Zoom out / Zoom / Zoom in /
    /// Reset zoom, currently 1.0×"** on this screen, with nothing naming the
    /// side — the gap `ClipSourceMenu.spokenLabel` closes for the choosers.
    /// Confined to side-by-side: the overlay layout draws one stack with one
    /// zoom, so it has no second control to be confused with. The fix is a
    /// `label: String?` on `ZoomControl`, which is shared with the viewer where
    /// there is no side to name, so it is left for whoever adds one.
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
        .darkFrostedBacking(in: Capsule())
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
        ClipSourceMenu(model: model, side: side, appearance: .overlayChip, title: name, prepare: prepare)
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
            title: ClipSourceMenu.chooseTitle,
            prepare: prepare
        )
    }
}
