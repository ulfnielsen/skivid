import CoreGraphics
import Foundation

/// How far into a clip the operator has zoomed, and where they have panned to.
///
/// A value type with no player and no view: the geometry is pure arithmetic,
/// and keeping it that way is what lets the clamping invariant below be tested
/// exhaustively without a media fixture. `SinglePlayerView`'s layer host is a
/// thin applier of `layerFrame`.
///
/// **The invariant.** At scale `s` the pane shows `1/s` of the frame, so the
/// visible half-extent is `1/(2s)` and the centre is confined to
/// `[1/(2s), 1 - 1/(2s)]` in both axes. At `s == 1` that interval collapses to
/// the single point `0.5`, so 1x is centred by construction rather than by a
/// special case. Both mutators re-establish it — see `setScale`, where
/// forgetting to is the defect this type exists to prevent.
public struct VideoZoom: Equatable, Sendable {
    /// 4x on a 1080p clip is roughly a 270p crop blown up to the pane, which is
    /// about as far as the source holds up. Below 1x the picture would shrink
    /// inside the pane with bars on all sides, which is not what a zoom control
    /// is for.
    public static let range: ClosedRange<Double> = 1.0...4.0

    public private(set) var scale: Double
    /// Which normalised point of the frame sits at the pane's middle.
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
    public mutating func setScale(_ newScale: Double) {
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
    /// A zero-sized pane is what a view reports before its first layout pass;
    /// dividing by it would give a NaN centre that no later clamp recovers.
    public mutating func pan(by translation: CGSize, in paneSize: CGSize) {
        guard isZoomed, paneSize.width > 0, paneSize.height > 0 else { return }
        let moved = CGPoint(
            x: center.x - translation.width / (paneSize.width * scale),
            y: center.y - translation.height / (paneSize.height * scale)
        )
        center = Self.clamped(moved, at: scale)
    }

    public mutating func reset() {
        self = VideoZoom()
    }

    /// The rect to give the `AVPlayerLayer`: the pane scaled by `scale`, placed
    /// so `center` lands at the pane's middle.
    ///
    /// **No aspect ratio anywhere.** The layer's gravity stays `.resizeAspect`,
    /// so it letterboxes its picture inside whatever frame it is given — which
    /// means scaling the *frame* scales the picture proportionally, bars and
    /// all. That is also why this is correct before the asset has loaded and
    /// can report a `presentationSize`.
    public func layerFrame(in bounds: CGSize) -> CGRect {
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
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
}
