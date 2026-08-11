import CoreGraphics

/// How far into a clip the operator has zoomed, and where they have panned to.
///
/// A value type with no player and no view: the geometry is pure arithmetic,
/// and keeping it that way is what lets the clamping invariant below be tested
/// exhaustively without a media fixture. `SinglePlayerView`'s layer host is a
/// thin applier of `layerFrame`.
///
/// **The invariant.** At scale `s` the visible picture shows `1/s` of the
/// video's own content, so the visible half-extent is `1/(2s)` and the centre
/// is confined to `[1/(2s), 1 - 1/(2s)]` in both axes. At `s == 1` that
/// interval collapses to the single point `0.5`, so 1x is centred by
/// construction rather than by a special case. Both mutators re-establish it
/// — see `setScale`, where forgetting to is the defect this type exists to
/// prevent. It bounds a fraction of the *video*, not of the pane: when the
/// pane's aspect does not match the clip's, `layerFrame` still letterboxes at
/// 1x exactly as `.resizeAspect` would on its own — that is inherent to the
/// aspect mismatch, not a gap in this invariant.
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

    /// Re-clamps the centre. Zooming *out* narrows the legal interval, so a
    /// centre that was legal at 4x is not at 1.5x; without this the picture
    /// hangs off one edge with black down the side, which reads as a rendering
    /// bug rather than as a pan that needed correcting.
    ///
    /// A non-finite `newScale` — reachable from a slider binding or a gesture
    /// magnitude — is rejected outright rather than clamped: `min`/`max`
    /// propagate NaN instead of absorbing it, so clamping a NaN leaves `scale`
    /// itself NaN, which breaks the type's headline promise that `scale`
    /// always lives in `range`.
    public mutating func setScale(_ newScale: Double) {
        guard newScale.isFinite else { return }
        scale = min(max(newScale, Self.range.lowerBound), Self.range.upperBound)
        center = Self.clamped(center, at: scale)
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
    public mutating func pan(by translation: CGSize, in paneSize: CGSize) {
        guard
            isZoomed,
            paneSize.width > 0, paneSize.height > 0,
            translation.width.isFinite, translation.height.isFinite
        else { return }
        let moved = CGPoint(
            x: center.x - translation.width / (paneSize.width * scale),
            y: center.y - translation.height / (paneSize.height * scale)
        )
        center = Self.clamped(moved, at: scale)
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
    public func layerFrame(in bounds: CGSize, videoSize: CGSize) -> CGRect {
        let base = Self.fitted(videoSize, in: bounds)
        let size = CGSize(width: base.width * scale, height: base.height * scale)
        return CGRect(
            x: bounds.width * 0.5 - center.x * size.width,
            y: bounds.height * 0.5 - center.y * size.height,
            width: size.width,
            height: size.height
        )
    }

    private static func clamped(_ point: CGPoint, at scale: Double) -> CGPoint {
        let half = 1 / (2 * scale)
        return CGPoint(
            x: min(max(point.x, half), 1 - half),
            y: min(max(point.y, half), 1 - half)
        )
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
