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
    /// Observed here because `model` only republishes its own properties:
    /// entering drawing mode changes `drawing.isDrawing`, not anything on
    /// `model`, and the tap and pan arbitration below depends on it.
    @ObservedObject private var drawing: DrawingController

    init(model: ViewerModel, athleteName: String) {
        self.model = model
        self.athleteName = athleteName
        _drawing = ObservedObject(wrappedValue: model.drawing)
    }

    /// Where the current drag had reached at its previous change.
    ///
    /// `DragGesture` reports `translation` from where the drag *began*, not
    /// since the last change, so this is what turns it into a per-change delta.
    /// See `panGesture`.
    ///
    /// **`@GestureState`, not `@State`, and the difference is a measured bug
    /// rather than a style preference.** `@GestureState` reverts to its initial
    /// value automatically when the gesture ends *or is cancelled*; a `@State`
    /// reset from `onEnded` only covers the first of those, and `onEnded` does
    /// not run when the recognizer is torn down mid-drag. That is reachable
    /// here — `panGesture` is only installed while `isZoomed`, so a second
    /// finger on the chip's `−` or its level readout removes it underneath a
    /// live drag, as does any system drag cancellation (an edge swipe to the
    /// app switcher, Slide Over, a notification), which needs no second finger.
    ///
    /// Measured on a hosted `ViewerPane` in a real window, 400×300 pane at 4×:
    /// a 60pt leftward drag torn down mid-flight, then a fresh 20pt leftward
    /// drag after re-arming.
    ///
    /// | | second drag's `center.x` |
    /// | ------------------------------ | ------ |
    /// | `@GestureState` (shipping)     | 0.5125 |
    /// | `@State` + `onEnded` reset     | 0.475  |
    ///
    /// 0.475 is the picture jumping 40pt *right* on the first frame of a
    /// leftward drag — the stale 60pt subtracted from the new 20pt — and it
    /// persists until one drag completes cleanly. Two consecutive *clean*
    /// drags are exactly additive under both, which is why a single-drag test
    /// cannot see this; `testASecondDragAfterTheGestureIsTornDownStartsFromRest`
    /// is what pins it.
    @GestureState private var lastDrag: CGSize = .zero

    /// **One `GeometryReader`, three consumers.** The drag, the zoom chip's
    /// slider and the model call underneath both of them all need the pane's
    /// size — `VideoZoom` clamps the pan against it — and reading it in one
    /// place here is what keeps that size out of `ContentView` and out of the
    /// control bar. An earlier round relayed it to `ViewerControlBar` through
    /// `ContentView` because the control lived in the bar; moving the control
    /// onto the video removed the relay along with the layout cost.
    @Environment(\.isShortOnHeight) private var isShortOnHeight

    var body: some View {
        GeometryReader { proxy in
            let area = Self.videoArea(in: proxy.size, picture: model.pictureSize)
            SinglePlayerView(player: model.player, zoom: model.zoom)
                // Tap to play/pause: the one universal video gesture, and
                // without it the video is inert to touch. Still the only
                // *unconditional* gesture here — swipe-for-clip and
                // edge-hold-to-shuttle would duplicate controls the bar already
                // carries.
                .contentShape(Rectangle())
                // Not while drawing: a tap there places or selects a mark, and the
                // overlay's own gesture handles it.
                .onTapGesture { if !drawing.isDrawing { model.applyTransport(.playPause) } }
                // **There is deliberately no `.onTapGesture(count: 2)` reset
                // here, and the absence is the measurement's, not an
                // oversight — `ComparisonPane` has one. Do not add it back
                // without re-measuring.**
                //
                // A `count: 2` tap makes SwiftUI hold *every* single tap until
                // the double-click window closes, whether or not a second click
                // ever comes. Measured on this view hosted in a real window,
                // macOS 26.5, load average 18, five synthetic single clicks per
                // configuration, timing mouse-down to `player.rate` changing:
                //
                // | pane | median | max |
                // | ------------------------------- | ------ | ------ |
                // | single tap alone (shipping)     | 1.2 ms | 3.6 ms |
                // | with a `count: 2` tap beside it | 358 ms | 363 ms |
                //
                // 358 ms is 2.4× the 150 ms the plan called perceptible, on the
                // app's most-used gesture, and it is paid on every play/pause
                // whether or not anyone ever double-clicks. Declaration order
                // does not buy it back: 357 ms with the double-tap first, 358
                // with it second (so the "higher count must come first" rule is
                // not what is costing the time — the wait is). The zoom chip's
                // level readout remains the reset route here, and it needs no
                // arbitration at all.
                //
                // At 4× the numbers are the same — 1.5 ms against 358 ms — so
                // it is not the pan gesture below paying for it, and 358 is not
                // `NSEvent.doubleClickInterval` either, which reads 0.5 s here:
                // SwiftUI runs its own shorter timer. The absence is pinned by
                // `testDoubleClickingTheViewerPaneDoesNotResetTheZoom`, which
                // also fails on its *first* assertion when the gesture is put
                // back — the click no longer reaches play/pause in time.

                // Only installed while zoomed, so at 1x it cannot swallow
                // anything meant for the tap above.
                // While drawing, only the Move tool pans: the other tools use
                // the same drag to make marks.
                .gesture(model.zoom.isZoomed && (!drawing.isDrawing || drawing.session?.tool == .move)
                         ? panGesture(in: area) : nil)
                // Above the video and its gestures, below the zoom chip.
                .overlay {
                    if let session = drawing.session, drawing.isDrawing || drawing.showsDrawings {
                        DrawingOverlay(model: model, session: session,
                                       isDrawing: drawing.isDrawing, paneSize: area)
                    }
                }
                .frame(width: area.width, height: area.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // After the gestures, so the chip is layered above them and
                // takes its own clicks rather than the video's play/pause —
                // measured in `ZoomWiringTests`, both directions. On the
                // pane, not the picture, so it stays in the band below it.
                .overlay(alignment: .bottomTrailing) { zoomChip(in: area) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) { caption }
        .overlay(alignment: .topTrailing) { statusChip }
        .overlay(alignment: .top) { unsupportedFormatBanner }
        .overlay(alignment: .bottom) {
            if let notice = drawing.notice {
                Text(notice).font(.caption).padding(6)
                    .background(.thinMaterial, in: Capsule()).padding(.bottom, 56)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("drawing.notice")
            }
        }
    }

    /// Shown when this device cannot decode the current clip's video.
    ///
    /// Top-centre, which is the one edge not already spoken for — the caption
    /// holds bottom-leading, the status chip top-trailing, the zoom chip
    /// bottom-trailing.
    ///
    /// The message itself keeps `allowsHitTesting(false)`, like the caption and
    /// the status chip: it floats over the play/pause tap target and text that
    /// claimed hits would eat it.
    ///
    /// **The button is the exception, and deliberately so.** This banner used
    /// to say there was nothing to tap because "the remedy is in the club's
    /// library, not on this screen" — true when the only message here was
    /// "this device cannot decode that clip". It is not true for a clip
    /// refused for its size: that one the app can fix in place, and making the
    /// coach leave for the Drive web UI to do it would be the worse design.
    /// Hit testing is therefore re-enabled on the button alone, which is small
    /// and centred, rather than on the whole banner.
    ///
    /// `repairableClip` rather than the presence of a message: the decode
    /// warning uses this same surface, and offering "Resize and replace" there
    /// would promise a fix that does not apply.
    @ViewBuilder
    private var unsupportedFormatBanner: some View {
        if let message = model.unsupportedFormatMessage {
            VStack(spacing: 10) {
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .allowsHitTesting(false)

                if model.repairableClip != nil {
                    Button("Resize and replace in Drive") {
                        Task { await model.repairCurrentClip() }
                    }
                    .disabled(model.isPreparingClip)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 460)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 12)
            .transition(.opacity)
        }
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
    /// reasoning as `ClipSourceMenu`'s chip on the comparison panes. The
    /// backing is `darkFrostedBacking`, shared with the caption, which also
    /// forces the dark scheme so its glyphs and slider turn light on it (the
    /// light-mode `.thinMaterial` it had was white-on-white over snow).
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
    /// **`.frame(maxWidth: 220)` for the same reason the status chip is capped,
    /// and it binds — but not at 220.** `ZoomControl`'s slider is greedy, so
    /// unbounded the chip stretches to whatever it is offered: measured in an
    /// 800pt pane, a 768pt control in a 784pt capsule without the cap, against
    /// 224pt in a 240pt capsule with it. What
    /// the cap does is hold the control at its intrinsic minimum of 224pt
    /// (3 × 44pt buttons + 80pt slider + 3 × 4pt spacing), which it cannot go
    /// under — so 224 is the rendered width, and the 4pt overshoot is why the
    /// hit-testing test below reads the chip's frame off the hosted `NSSlider`
    /// rather than computing it.
    ///
    /// **It shares the pane's bottom edge with the caption, and the overlap
    /// point is arithmetic rather than a mystery.** The chip occupies 264pt of
    /// trailing width — the capsule measures 240pt (the control's 224pt
    /// intrinsic width, not the 220pt asked for, plus 8pt of inner padding on
    /// each side) inside 12pt of outer padding on each side — so a caption
    /// longer than `paneWidth − 264` runs under it. That is left alone deliberately: the
    /// caption draws *over* the chip and carries `.allowsHitTesting(false)`, so
    /// the chip still receives every click, and the cost is cosmetic on a pane
    /// narrow enough to reach it.
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
        .frame(maxWidth: isShortOnHeight ? 160 : 220)
        .padding(.horizontal, isShortOnHeight ? 4 : 8)
        .darkFrostedBacking(in: Capsule())
        .padding(isShortOnHeight ? 6 : 12)
    }

    /// The part of the pane the player occupies: the full width, and only as
    /// much height as the picture needs at that width, pinned to the top.
    ///
    /// **Centred, half the spare height sat between the title bar and the
    /// picture** as an empty grey band, so the video's top edge stood ~30pt
    /// below the sidebar's content beside it — the operator's 2026-10-11
    /// screenshot of a misaligned header. Pinned to the top, all of it goes to
    /// the band below the picture, which the caption and zoom chip already sit
    /// in. When the pane is wider than the picture (bars at the sides) there
    /// is no spare height and this is the whole pane, unchanged.
    ///
    /// The player, its gestures, the drawing overlay and the zoom all take this
    /// size, so `VideoZoom` and `DrawingGeometry` see a pane with no vertical
    /// letterbox and nothing in either needs to know the picture was moved.
    /// The cost: zoomed in, the picture fills this area rather than spilling
    /// into the band below. Before the clip's size is known it is the whole
    /// pane, as `VideoZoom.layerFrame` treats an unknown size.
    static func videoArea(in pane: CGSize, picture: CGSize) -> CGSize {
        guard picture.width > 0, picture.height > 0, pane.width > 0,
              picture.width.isFinite, picture.height.isFinite else { return pane }
        let fittedHeight = pane.width * picture.height / picture.width
        return CGSize(width: pane.width, height: min(pane.height, fittedHeight))
    }

    /// A drag pans, and each step is relative to the previous one — SwiftUI
    /// reports the translation from where the drag *began*, so feeding it
    /// straight to `panZoom` would re-apply the whole distance on every change
    /// and run away. Measured in
    /// `ZoomWiringTests.testDraggingThePanePansByEachStepsDeltaRatherThanTheWholeTranslation`:
    /// a 60pt drag in three steps lands `center.x` on 0.5375 with the
    /// subtraction and 0.575 — a 60pt drag moving the picture 120pt — without.
    ///
    /// **`updating`, not `onChanged` with an `onEnded` reset.** Both compute
    /// the same delta; only this one gets the running total cleared when the
    /// gesture is *cancelled* as well as when it ends. See `lastDrag` for the
    /// measurement, and note that the `onChanged`/`onEnded` shape is what this
    /// view shipped with first — it is not a worse-looking version of the same
    /// behaviour, it is a different and wrong one.
    private func panGesture(in paneSize: CGSize) -> some Gesture {
        DragGesture()
            .updating($lastDrag) { value, lastDrag, _ in
                let delta = CGSize(
                    width: value.translation.width - lastDrag.width,
                    height: value.translation.height - lastDrag.height
                )
                lastDrag = value.translation
                model.panZoom(by: delta, in: paneSize)
            }
    }

    /// The athlete and the clip, over the letterbox.
    ///
    /// **It was `.white.opacity(0.85)` with a `.shadow(radius: 2)` and no
    /// background, and against a bright snowy frame that is white-on-white.**
    /// The operator sent a screenshot in which both lines were barely
    /// discernible. A shadow separates light text from a *dark* backdrop; it has
    /// nothing to work with when the backdrop is snow, which is most of what
    /// this app ever shows.
    ///
    /// **A frosted capsule, but a dark one in every appearance** —
    /// `darkFrostedBacking`, which carries the measurements. A plain
    /// `.thinMaterial` is a light blur in light mode, and white text over snow
    /// was white on near-white again. The zoom chip in the opposite corner and
    /// the comparison screen's chips share it. The shadow stays gone: the
    /// capsule is the separation, and a shadow under a blurred capsule only
    /// muddies its edge.
    ///
    /// The type steps up with it — `.title3` semibold for the athlete, who is
    /// the thing a coach scanning a wall of runs is looking for, and
    /// `.subheadline` for the clip line, which was `.caption` and read as fine
    /// print at a metre from the screen.
    ///
    /// **`.allowsHitTesting(false)` is load-bearing, not defensive.** The whole
    /// pane is one big play/pause tap target; a caption that claimed hits would
    /// eat the gesture wherever it sits. Giving it a background makes the size
    /// of what it would have eaten visible for the first time, which is a reason
    /// to keep the modifier rather than to reconsider it. The status chip
    /// opposite carries it for the same reason; the zoom chip deliberately does
    /// not, because it is a control — see `zoomChip(in:)`.
    ///
    /// Internal rather than private so `ViewerCaptionLayoutTests` can measure
    /// the capsule the shipped view builds instead of a copy of it that could
    /// drift from it. `ClipSourceMenu.spokenLabel` is internal for the same
    /// reason.
    var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(athleteName)
                .font(.title3.weight(.semibold))
            Text(model.clipDescription)
                .font(.subheadline)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .darkFrostedBacking(in: Capsule())
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
