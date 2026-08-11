import CoreGraphics

/// How far into a clip the operator has zoomed, and where they have panned to.
///
/// A value type with no player and no view: the geometry is pure arithmetic,
/// and keeping it that way is what lets the clamping invariant below be tested
/// exhaustively without a media fixture. `SinglePlayerView`'s layer host is a
/// thin applier of `layerFrame`.
///
/// **The invariant.** On each axis independently, the centre is confined to
/// the widest interval that still keeps the picture covering the pane on that
/// axis, capped at `[0, 1]`'s own midpoint. Concretely, the half-extent on an
/// axis is `min(bounds / (2 · fitted · scale), 0.5)`, where `fitted` is that
/// axis' extent of the video once it has been letterboxed to fit `bounds`
/// (see `layerFrame`). Two cases fall out of that one formula:
///
/// - When the pane's aspect matches the clip's, `fitted == bounds` on both
///   axes and this degenerates to exactly `1/(2 · scale)` — the picture
///   shows `1/scale` of the video's own content, unaffected by pane shape.
/// - When the aspects don't match, the letterboxed axis (`fitted < bounds`)
///   gets a *narrower* legal interval than `1/(2 · scale)` once the picture
///   is at least as large as the pane on that axis, because letterboxing
///   already used up some of the scale before any of it could cover the
///   pane. Below that threshold — the picture is still smaller than the pane
///   on that axis even scaled up — the formula would ask for a half-extent
///   past `0.5`, i.e. an interval wider than legal; capping at `0.5`
///   collapses the centre to the middle instead, which is correct: no
///   position covers the pane there, so centring the unavoidable bars is the
///   right answer, not a special case bolted on.
///
/// At `scale == 1` with matched aspect that interval collapses to the single
/// point `0.5`, so 1x is centred by construction rather than by a special
/// case. Both mutators re-establish this — see `setScale`, where forgetting
/// to is the defect this type exists to prevent — and `layerFrame` enforces
/// it defensively too, because a window resize changes `bounds` without
/// running either mutator.
public struct VideoZoom: Equatable, Sendable {
    /// 4x on a 1080p clip is roughly a 270p crop blown up to the pane, which is
    /// about as far as the source holds up. Below 1x the picture would shrink
    /// inside the pane with bars on all sides, which is not what a zoom control
    /// is for.
    public static let range: ClosedRange<Double> = 1.0...4.0

    public private(set) var scale: Double
    /// Which normalised point of the video sits at the pane's middle.
    public private(set) var center: CGPoint

    public var isZoomed: Bool { scale > Self.range.lowerBound }

    public init() {
        scale = Self.range.lowerBound
        center = CGPoint(x: 0.5, y: 0.5)
    }

    /// Re-clamps the centre against `bounds`/`videoSize`. Zooming *out* narrows
    /// the legal interval, so a centre that was legal at 4x is not at 1.5x;
    /// without this the picture hangs off one edge with black down the side,
    /// which reads as a rendering bug rather than as a pan that needed
    /// correcting.
    ///
    /// A non-finite `newScale` — reachable from a slider binding or a gesture
    /// magnitude — is rejected outright rather than clamped: `min`/`max`
    /// propagate NaN instead of absorbing it, so clamping a NaN leaves `scale`
    /// itself NaN, which breaks the type's headline promise that `scale`
    /// always lives in `range`.
    public mutating func setScale(_ newScale: Double, in bounds: CGSize, videoSize: CGSize) {
        guard newScale.isFinite else { return }
        scale = min(max(newScale, Self.range.lowerBound), Self.range.upperBound)
        center = Self.clamped(center, bounds: bounds, videoSize: videoSize, scale: scale)
    }

    /// `translation` and `paneSize` are both in points.
    ///
    /// The centre moves by `translation / (paneSize * scale)`: the scale
    /// divisor is what makes a drag cover the same screen distance at 4x as at
    /// 1.5x, instead of running four times as fast just when the operator is
    /// looking closest.
    ///
    /// **Negated**, so dragging right moves the picture right. The operator is
    /// pushing the frame around, not pushing a viewport over it.
    ///
    /// A zero-sized pane is what a view reports before its first layout pass.
    /// Without this guard, dividing by a zero-width or zero-height pane hits
    /// one of two failure modes depending on the drag: a nonzero translation
    /// divided by zero is ±infinity, which `clamped` *does* resolve — to a
    /// definite but wrong edge, so the picture would silently snap to a bound
    /// with no drag on screen to justify it; a translation of exactly zero
    /// divided by zero is 0/0 = NaN, which `clamped` cannot resolve at all,
    /// and only `reset()` recovers from it. Guarding the pane size up front
    /// closes both branches rather than relying on the clamp to catch either.
    ///
    /// A non-finite `translation` — a NaN or infinite gesture value, which a
    /// pan gesture should never produce but which this guard does not trust
    /// it not to — is rejected the same way: `min`/`max` propagate rather than
    /// absorb it, so a NaN component would poison `center` permanently, with
    /// no later `pan` or `setScale` able to recover it.
    public mutating func pan(by translation: CGSize, in paneSize: CGSize, videoSize: CGSize) {
        guard
            isZoomed,
            paneSize.width > 0, paneSize.height > 0,
            translation.width.isFinite, translation.height.isFinite
        else { return }
        let moved = CGPoint(
            x: center.x - translation.width / (paneSize.width * scale),
            y: center.y - translation.height / (paneSize.height * scale)
        )
        center = Self.clamped(moved, bounds: paneSize, videoSize: videoSize, scale: scale)
    }

    public mutating func reset() {
        self = VideoZoom()
    }

    /// The rect to give the `AVPlayerLayer`: the video's on-pane picture —
    /// the largest rect of `videoSize`'s aspect that fits inside `bounds`,
    /// centred — scaled by `scale` and placed so `center` lands at the pane's
    /// middle.
    ///
    /// The layer's gravity stays `.resizeAspect`, but by fitting the frame to
    /// `videoSize` first there are no bars left for it to add: the layer's
    /// frame already *is* the picture. That is what lets the invariant above
    /// bound the thing the operator actually sees. Scaling `bounds` directly
    /// instead — this type's first version did — hands `.resizeAspect` an
    /// oversized frame of the wrong aspect; the frame still "covers" the pane
    /// by construction, but the letterboxed picture inside it can pan
    /// completely off the pane while that's true, which reads on screen as
    /// the video vanishing for no reason.
    ///
    /// `videoSize` is the clip's `presentationSize`. Before the asset has
    /// loaded there is no reported size — pass `.zero`, or anything
    /// non-finite — and this falls back to treating `bounds` as the fitted
    /// rect, today's pre-load behaviour. That fallback is correct rather than
    /// a fudge: there is no picture on screen yet to bound, and the next
    /// layout pass after the size arrives re-places the layer against the
    /// real aspect.
    ///
    /// **Defensively re-clamps `center` against the `bounds`/`videoSize` it
    /// was actually called with**, rather than trusting the stored value. The
    /// mutators keep `center` legal for the geometry they were given, but a
    /// window resize changes `bounds` with no mutator running at all — a
    /// centre that fully covered a portrait pane can leave a gap once the
    /// pane goes landscape. Belt and braces on purpose: re-clamping here is
    /// cheap, and the failure it prevents is a black band the operator has no
    /// gesture to explain or correct.
    public func layerFrame(in bounds: CGSize, videoSize: CGSize) -> CGRect {
        let base = Self.fitted(videoSize, in: bounds)
        let size = CGSize(width: base.width * scale, height: base.height * scale)
        let renderCenter = Self.clamped(center, bounds: bounds, videoSize: videoSize, scale: scale)
        return CGRect(
            x: bounds.width * 0.5 - renderCenter.x * size.width,
            y: bounds.height * 0.5 - renderCenter.y * size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Clamps `point` to the legal centre interval for `scale` against
    /// `bounds`/`videoSize`, independently on each axis. See the type-level
    /// doc comment for the formula and why it degenerates to `1/(2·scale)`
    /// when the aspects match.
    private static func clamped(_ point: CGPoint, bounds: CGSize, videoSize: CGSize, scale: Double) -> CGPoint {
        let base = Self.fitted(videoSize, in: bounds)
        let halfX = Self.half(bounds: bounds.width, fitted: base.width, scale: scale)
        let halfY = Self.half(bounds: bounds.height, fitted: base.height, scale: scale)
        return CGPoint(
            x: min(max(point.x, halfX), 1 - halfX),
            y: min(max(point.y, halfY), 1 - halfY)
        )
    }

    /// The half-extent of the legal centre interval on one axis:
    /// `bounds / (2 · fitted · scale)`, capped at `0.5`.
    ///
    /// When the picture is at least as large as the pane on this axis
    /// (`fitted · scale >= bounds`), this is exactly the fraction of the
    /// picture's own extent that must stay inside the pane's half — matching
    /// `1/(2·scale)` when `fitted == bounds` (aspects match), and shrinking
    /// as `fitted` shrinks relative to `bounds` (more letterboxing leaves
    /// less travel before the picture's own edge creates a gap).
    ///
    /// When the picture is smaller than the pane on this axis even at this
    /// scale, the raw formula exceeds `0.5` — an interval wider than `[0, 1]`
    /// can express. Capping at `0.5` collapses the centre to the middle
    /// instead: no placement covers the pane on this axis regardless of pan,
    /// so centring the unavoidable letterbox bars is the right answer.
    ///
    /// `fitted <= 0` only when `bounds` itself is degenerate (see
    /// `fitted(_:in:)`); there is no meaningful pane to bound against, so
    /// this collapses to the centre point the same as everywhere else that
    /// falls back on a degenerate geometry.
    private static func half(bounds: CGFloat, fitted: CGFloat, scale: Double) -> CGFloat {
        guard fitted > 0 else { return 0.5 }
        return min(bounds / (2 * fitted * scale), 0.5)
    }

    /// The largest rect of `videoSize`'s aspect that fits inside `bounds`,
    /// centred — i.e. what `.resizeAspect` would draw on its own. Falls back
    /// to `bounds` itself whenever `videoSize` (or `bounds`) cannot describe a
    /// real aspect ratio: zero, negative, or non-finite in either dimension.
    private static func fitted(_ videoSize: CGSize, in bounds: CGSize) -> CGSize {
        guard
            videoSize.width.isFinite, videoSize.height.isFinite,
            videoSize.width > 0, videoSize.height > 0,
            bounds.width.isFinite, bounds.height.isFinite,
            bounds.width > 0, bounds.height > 0
        else { return bounds }

        let videoAspect = videoSize.width / videoSize.height
        let boundsAspect = bounds.width / bounds.height
        if videoAspect > boundsAspect {
            return CGSize(width: bounds.width, height: bounds.width / videoAspect)
        } else {
            return CGSize(width: bounds.height * videoAspect, height: bounds.height)
        }
    }
}
