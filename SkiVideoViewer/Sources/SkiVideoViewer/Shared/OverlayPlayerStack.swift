import AVFoundation
import SkiVideoCore
import SwiftUI

/// Two clips drawn into the same rect, `bottomPlayer` beneath `topPlayer`.
/// Both use aspect-fit so neither is cropped and both occupy the same frame.
///
/// This is SwiftUI rather than the two-`AVPlayerLayer` view macOS used, because
/// `CALayer.compositingFilter` is a silent no-op on iOS — measured on an iPad
/// Pro 11-inch (M5) simulator, where a red layer under a cyan one with
/// `CIDifferenceBlendMode` rendered the overlap plain cyan instead of white.
/// `.blendMode(.difference)` does work, including on `AVPlayerLayer`-backed
/// views: the same clips rendered white, and an `.opacity(0.5)` control
/// rendered grey. Do not "simplify" this back toward `compositingFilter`.
///
/// **Re-measured after the zoom work moved the `AVPlayerLayer`.** That first
/// measurement was taken when `SinglePlayerView`'s iOS host overrode
/// `layerClass`, so the view's *own* layer was the `AVPlayerLayer`; it is now a
/// sublayer of a plain `CALayer`, which is a different thing for SwiftUI to
/// composite and could have regressed the blend silently. It did not. Same
/// simulator, this stack driven over two solid-colour clips — red underneath,
/// cyan on top — and read back with `simctl io screenshot`, which captures the
/// composited framebuffer from outside the process (no in-process snapshot
/// shows video at all; see `offset` below):
///
/// | mode                    | centre RGB      |
/// | ----------------------- | --------------- |
/// | `.difference`           | (211, 255, 251) |
/// | `.blend`, opacity 1     | (22, 255, 253)  |
/// | `.blend`, opacity 0.5   | (127, 128, 128) |
///
/// The difference row is white, not the plain cyan a no-op produces — the two
/// are 189 apart in the red channel, and the opacity-1 row is the control that
/// says what a no-op would have looked like. It is off-white rather than 255
/// because H.264's YUV round-trip does not return the source's exact red.
///
/// **Only the region the two clips share is drawn.** Offsetting the top clip
/// leaves a strip down one side and along one edge where only one clip has
/// picture; in blend mode that strip is a single clip at half opacity and in
/// difference mode it is a clip differenced against black, and both read as
/// artefacts rather than as "there is nothing to compare here". Both players
/// are masked to their intersection — see `sharedRect` — and outside it the
/// same black the letterbox already uses shows through, so the frame simply
/// appears smaller.
///
/// **Still a pure renderer.** It takes players and values — never a track, a
/// store or a model — which is what lets the blend compositing be tested
/// without one, and what keeps every judgement about *whether* to align in
/// `AlignmentGate`, where both the live overlay and a future exporter reach it.
struct OverlayPlayerStack: View {
    let bottomPlayer: AVPlayer
    let topPlayer: AVPlayer
    /// Expected to be already resolved by the caller — `topLayerOpacity` on
    /// `ComparisonModel` is where "difference mode ignores the slider" lives.
    /// The body re-applies that rule anyway; see `body` for why that cannot
    /// drift.
    let topOpacity: Double
    let blend: OverlayBlend
    /// How far to move the **top** clip to bring it onto the bottom one, in
    /// normalised frame widths. `.zero` draws them unaligned, which is what
    /// this view did unconditionally before alignment existed and still does
    /// whenever the gate says identity.
    ///
    /// **The top clip and not the bottom.** `AlignmentAnalyzer` registers the
    /// right clip onto the left and stores the transform that moves the right
    /// one; `ComparisonVideos` puts the left clip underneath and the right on
    /// top. Moving the bottom clip instead would align the pair just as well
    /// geometrically and be wrong in the frame: the reference would drift
    /// around the window while the floating clip sat still.
    ///
    /// Defaulted so the pure-renderer call sites in the tests, which have no
    /// track, stay honest about not passing one.
    var translation: CGVector = .zero
    /// **One zoom for the pair, not one each.**
    ///
    /// `translation` is in normalised frame widths and both clips are masked to
    /// the region they share, so magnifying the two by different amounts would
    /// invalidate the registration and the mask at once. Scaling them together
    /// leaves both correct — but not for free, and not by leaving the geometry
    /// alone: a normalised frame width is `renderedVideoWidth` points on screen
    /// at 1× and `renderedVideoWidth × scale` at any other scale, so both
    /// `offset` and `sharedRect` take this and scale by it. See `offset` for the
    /// measurement of what ignoring it costs.
    ///
    /// `ComparisonVideos` hands this the **left** side's zoom and drives it from
    /// one chip; `ComparisonModel.leftZoom` records why the two sides otherwise
    /// zoom independently.
    ///
    /// Defaulted so the pure-renderer call sites in the tests stay honest about
    /// not passing one.
    var zoom: VideoZoom = VideoZoom()

    var body: some View {
        GeometryReader { proxy in
            // One video size for the whole geometry — the floating clip's, the
            // same one `offset` has always scaled by. The pair is two cameras
            // on one hill at one resolution; if that ever stops holding, the
            // shared region needs both rects, not this one twice — and so does
            // the zoom, which is applied to both clips from this one value.
            let videoSize = topPlayer.currentItem?.presentationSize ?? .zero
            let shared = Self.sharedRect(for: translation, in: proxy.size, videoSize: videoSize, zoom: zoom)
            ZStack {
                Color.black
                SinglePlayerView(player: bottomPlayer, zoom: zoom)
                    // The stationary clip is masked too, and to the *same*
                    // rect. Masking only the moved one leaves the reference
                    // showing through the strip where the other clip has no
                    // picture at all, which is the artefact this removes.
                    .mask { Self.sharedRegion(shared) }
                SinglePlayerView(player: topPlayer, zoom: zoom)
                    .offset(Self.offset(for: translation, in: proxy.size, videoSize: videoSize, zoom: zoom))
                    // After `.offset`, deliberately. `.offset` is a render-time
                    // effect and does not move the layout frame a mask is
                    // placed against, so this rect stays put in the container
                    // while the picture slides under it — measured, by
                    // rendering a `Color` stand-in through `ImageRenderer` at
                    // both orderings before this line was written.
                    .mask { Self.sharedRegion(shared) }
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
            .frame(width: proxy.size.width, height: proxy.size.height)
            // Insurance, not a load-bearing fix. Deleting it was tested on iPad and
            // gave pixel-identical output with no backdrop leak — the opaque
            // `Color.black` at the bottom of this `ZStack` already bounds what the
            // blend can see. Kept so the bound does not depend on that one child
            // staying opaque.
            .compositingGroup()
            // Now load-bearing, where it was not before: an offset clip reaches
            // past this rect, and without the clip it would paint over the
            // status chip and the chrome below.
            .clipped()
        }
    }

    /// The offset in points for a normalised translation.
    ///
    /// **Both components scale by the video's rendered *width*.** That is not a
    /// slip for "width and height": `AlignmentAnalyzer` divides both `dx` and
    /// `dy` by the reference frame's pixel width precisely so the vector keeps
    /// its aspect through a change of resolution, and undoing that with two
    /// different divisors here would skew every alignment on any clip that is
    /// not square.
    ///
    /// **And by the zoom, which is the part that is not obvious.** The plan for
    /// the zoom said to leave this alone, on the grounds that "the translation
    /// stays normalised". The translation does; its conversion to points does
    /// not. `VideoZoom.layerFrame` draws the fitted picture at `scale` times its
    /// size, so one normalised frame width is `renderedVideoWidth × scale`
    /// points on screen. Ignoring that under-moves the top clip by
    /// `(scale − 1) × dx × renderedVideoWidth` and takes the pair apart —
    /// measured, an 800pt stack at `dx 0.1`: the feature at normalised 0.6 in
    /// the reference lands at 560pt and its partner at 480pt, an 80pt gap at 2×
    /// and 240pt at 4×, on the one screen whose entire job is alignment.
    /// `ZoomWiringTests.testTheAlignmentOffsetScalesWithTheZoomSoTheClipsStayRegistered`
    /// pins the invariant rather than this formula.
    ///
    /// Static and taking explicit sizes so the arithmetic is testable. The
    /// alternative — reading it back out of a rendered `NSHostingView` — is the
    /// measurement this project has repeatedly found says nothing: a view-tree
    /// search finds no `NSControl` for controls that plainly render, and
    /// `ImageRenderer` draws `SinglePlayerView` as a placeholder rather than as
    /// video.
    static func offset(
        for translation: CGVector, in container: CGSize, videoSize: CGSize, zoom: VideoZoom = VideoZoom()
    ) -> CGSize {
        let width = renderedVideoWidth(container: container, videoSize: videoSize) * zoom.scale
        return CGSize(width: translation.dx * width, height: translation.dy * width)
    }

    /// The region of `container` both clips have picture in, in the
    /// container's own coordinates: everything outside it is masked to black.
    ///
    /// **This is where "overlap" stops being an abstract score.** For a pure
    /// translation the shared region is the frame inset by `|dx|` on the
    /// horizontal side the shift moves away from and `|dy|` on the vertical
    /// one, so its area over the frame's area *is* the overlap `AlignmentGate`
    /// gates on. Engaging at 0.68 is visibly throwing away nearly a third of
    /// the picture, which is why the gate's defaults moved to 0.75 / 0.65.
    ///
    /// **A mask, never a zoom.** Nothing here scales the shared region back up
    /// to fill the container. It could — the arithmetic is right there — and
    /// the pair would then change size every time the gate engaged or
    /// disengaged. A picture that jumps scale mid-run is worse than one that
    /// loses a border.
    ///
    /// **Identity is the whole container, not the video rect.** With no shift
    /// there is no non-shared strip to hide, so the unaligned overlay draws
    /// exactly what it drew before alignment existed. The two differ only by
    /// the letterbox bars, which are black either way, so the step at
    /// `translation == .zero` is arithmetic rather than anything visible.
    ///
    /// **Zoomed, the picture each clip paints is bounded by the container, and
    /// that is not a shortcut.** `PlayerLayerHostView` masks its
    /// `AVPlayerLayer` to its own bounds — see `configure`, pinned by
    /// `ZoomWiringTests.testTheHostViewClipsItsLayer` — and SwiftUI's `.offset`
    /// moves that already-clipped host, as `OverlayAlignmentWiringTests`
    /// probed. So the strip the shift opens at the leading edge has no top-clip
    /// picture in it at *any* scale, even where the magnified picture would
    /// have had content to put there, and the mask has to keep covering it.
    /// Taking the two rects unclipped instead would leave 320pt of a 800pt
    /// stack showing one clip alone at 4× and `dx 0.1` — half-opacity in blend
    /// mode, differenced against black in difference mode, which is the artefact
    /// this exists to remove.
    ///
    /// **What that costs, stated rather than discovered later.** The shared
    /// region shrinks as the operator zooms in, because the shift it is inset by
    /// grows with the scale while the container does not. On an 800pt stack:
    ///
    /// | `dx`  | 1×    | 2×    | 4×             |
    /// | ----- | ----- | ----- | -------------- |
    /// | 0.05  | 760pt | 720pt | 640pt          |
    /// | 0.10  | 720pt | 640pt | 480pt          |
    /// | 0.30  | 560pt | 320pt | 0 — all black  |
    ///
    /// A gate-passing alignment at the far end of its range can therefore black
    /// the overlay out at 4×. That is honest — it says "there is nothing here
    /// both clips can be compared on", the same thing the letterbox says at 1× —
    /// but it is a limitation and not a design. It comes entirely from the clip
    /// happening before the offset: moving the shift into the layer's own frame,
    /// inside the host, would clip only content that is off-screen anyway and
    /// remove the strip loss at every scale. That is a change to
    /// `SinglePlayerView`, which the viewer and both comparison panes also
    /// draw through, so it is left as its own piece of work.
    ///
    /// Static and taking explicit sizes for the same reason `offset` is: this
    /// is the geometry that has to be *asserted*, and the four ways this
    /// project has measured an offscreen render lying about a SwiftUI view are
    /// listed on `offset` below.
    static func sharedRect(
        for translation: CGVector, in container: CGSize, videoSize: CGSize, zoom: VideoZoom = VideoZoom()
    ) -> CGRect {
        let full = CGRect(origin: .zero, size: container)
        guard translation != .zero else { return full }

        let video = videoRect(container: container, videoSize: videoSize, zoom: zoom).intersection(full)
        guard !video.isNull else { return .zero }
        let shift = offset(for: translation, in: container, videoSize: videoSize, zoom: zoom)
        let moved = video.offsetBy(dx: shift.width, dy: shift.height)
        let shared = video.intersection(moved)
        // A shift of a whole frame or more shares nothing. `intersection`
        // answers that with the null rect, whose origin is infinite; a mask
        // wants an empty one.
        return shared.isNull ? .zero : shared
    }

    /// Where the video actually lands inside `container`: the aspect-fit rect,
    /// centred, with the letterbox or pillarbox bars outside it — magnified and
    /// re-placed by `zoom` once the operator has zoomed in.
    ///
    /// **That is `VideoZoom.layerFrame`, and delegating to it is the point.**
    /// The host gives its `AVPlayerLayer` exactly that rect, so any second
    /// arithmetic for the same thing here would be a copy free to drift from
    /// what is on screen — and it would have to reproduce the pan as well as the
    /// scale, since a panned picture is not centred. At `VideoZoom()` it is
    /// bit-for-bit the centred aspect-fit rect this returned before the zoom
    /// existed: `layerFrame` falls back to the container for a video size that
    /// cannot describe an aspect, exactly as `renderedVideoWidth` does, and at
    /// scale 1 its centre clamp collapses to the container's own middle.
    static func videoRect(container: CGSize, videoSize: CGSize, zoom: VideoZoom = VideoZoom()) -> CGRect {
        zoom.layerFrame(in: container, videoSize: videoSize)
    }

    /// The mask the two players are drawn through: opaque inside `rect`,
    /// nothing outside it, so the black already under the stack shows there.
    private static func sharedRegion(_ rect: CGRect) -> some View {
        Rectangle()
            .frame(width: max(0, rect.width), height: max(0, rect.height))
            .position(x: rect.midX, y: rect.midY)
    }

    /// How wide the video actually draws inside `container`, which is not the
    /// container's own width whenever the two aspects differ.
    ///
    /// `SinglePlayerView` uses `resizeAspect` — deliberately, because cropping
    /// either clip would make the comparison lie — so a 16:9 clip in a 2:1
    /// video area is pillarboxed and draws about 11% narrower than the area it
    /// sits in. Scaling a normalised translation by the container width there
    /// would overshoot every offset by that same fraction, in a screen whose
    /// entire job is alignment.
    ///
    /// A clip whose presentation size is not known yet — every player before
    /// its item finishes loading — falls back to the container width. There is
    /// nothing better to say at that point, and the fallback is only wrong by
    /// the pillarbox fraction for the moment before the size arrives.
    static func renderedVideoWidth(container: CGSize, videoSize: CGSize) -> CGFloat {
        guard container.width > 0, container.height > 0,
              videoSize.width > 0, videoSize.height > 0
        else { return container.width }
        let scale = min(container.width / videoSize.width, container.height / videoSize.height)
        return videoSize.width * scale
    }

    /// The other side of the same aspect fit — where the picture *starts and
    /// stops* vertically, which is not something a normalised translation ever
    /// needed to know.
    ///
    /// This is not a second ruler for `dy`. Both components of a translation
    /// still scale by the rendered **width**; see `offset`.
    ///
    /// **Nothing in this file reads it since `videoRect` began delegating to
    /// `VideoZoom.layerFrame`, and it stays anyway.** It is what
    /// `OverlayAlignmentWiringTests` measures the vertical crop against, and a
    /// ruler derived from the code under test would prove nothing there — the
    /// three `XCTAssertNotEqual`s in
    /// `testAPositiveDXAndANegativeDYCropFromTheLeftAndTheBottom` exist to catch
    /// exactly the mistake of scaling `dy` by this, and they need it spelled out
    /// to say so.
    static func renderedVideoHeight(container: CGSize, videoSize: CGSize) -> CGFloat {
        guard container.width > 0, container.height > 0,
              videoSize.width > 0, videoSize.height > 0
        else { return container.height }
        let scale = min(container.width / videoSize.width, container.height / videoSize.height)
        return videoSize.height * scale
    }
}
