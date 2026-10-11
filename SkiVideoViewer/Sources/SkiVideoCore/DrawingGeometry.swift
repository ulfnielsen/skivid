import CoreGraphics
import Foundation

/// Where the picture is on screen, and the arithmetic that hangs off it.
///
/// Built from `VideoZoom.layerFrame` — the same rectangle the player layer is
/// placed at — so marks and picture cannot drift apart: there is one answer to
/// "where is the picture", and both use it.
public struct DrawingGeometry: Equatable, Sendable {
    /// A fingertip's worth of slack, in screen points, for hits and handles.
    public static let touchTolerance: CGFloat = 22

    public let pictureFrame: CGRect
    public let videoSize: CGSize

    public init(zoom: VideoZoom, paneSize: CGSize, videoSize: CGSize) {
        self.init(pictureFrame: zoom.layerFrame(in: paneSize, videoSize: videoSize), videoSize: videoSize)
    }

    public init(pictureFrame: CGRect, videoSize: CGSize) {
        self.pictureFrame = pictureFrame
        self.videoSize = videoSize
    }

    public func toPane(_ p: CGPoint) -> CGPoint {
        CGPoint(x: pictureFrame.minX + p.x * pictureFrame.width,
                y: pictureFrame.minY + p.y * pictureFrame.height)
    }

    public func toPicture(_ q: CGPoint) -> CGPoint {
        guard pictureFrame.width > 0, pictureFrame.height > 0 else { return .zero }
        return CGPoint(x: (q.x - pictureFrame.minX) / pictureFrame.width,
                       y: (q.y - pictureFrame.minY) / pictureFrame.height)
    }

    /// Degrees between the two arms, 0…180, in the clip's *pixel* space. In
    /// fractions a 16:9 picture's axes have different units, and the answer
    /// would be skewed — see `testAnAngleIsMeasuredInPixelsNotFractions`.
    public static func angle(corner: CGPoint, a: CGPoint, b: CGPoint, videoSize: CGSize) -> Double {
        let u = CGVector(dx: (a.x - corner.x) * videoSize.width, dy: (a.y - corner.y) * videoSize.height)
        let v = CGVector(dx: (b.x - corner.x) * videoSize.width, dy: (b.y - corner.y) * videoSize.height)
        let lu = hypot(u.dx, u.dy), lv = hypot(v.dx, v.dy)
        guard lu > 0, lv > 0 else { return 0 }
        let cosine = max(-1, min(1, (u.dx * v.dx + u.dy * v.dy) / (lu * lv)))
        return acos(Double(cosine)) * 180 / .pi
    }

    /// The topmost mark within `tolerance` screen points of `q`. Later marks
    /// are drawn over earlier ones, so the search runs backwards.
    public func hit(_ q: CGPoint, in drawings: [Drawing], tolerance: CGFloat = touchTolerance) -> UUID? {
        drawings.reversed().first { distance(from: q, to: $0) <= tolerance }?.id
    }

    /// Which point of a line or angle `q` grabs. Pen strokes and text have
    /// none: reshaping a stroke is out of scope.
    public func handle(_ q: CGPoint, of drawing: Drawing, tolerance: CGFloat = touchTolerance) -> Int? {
        guard drawing.kind == .line || drawing.kind == .angle else { return nil }
        let panePoints = drawing.points.map(toPane)
        let distances = panePoints.map { hypot($0.x - q.x, $0.y - q.y) }
        guard let best = distances.indices.min(by: { distances[$0] < distances[$1] }),
              distances[best] <= tolerance else { return nil }
        return best
    }

    private func distance(from q: CGPoint, to drawing: Drawing) -> CGFloat {
        let points = drawing.points.map(toPane)
        switch drawing.kind {
        case .text:
            // Text is drawn centred on its anchor; about 5pt per character
            // either side is the half-width at the overlay's font size.
            guard let anchor = points.first else { return .infinity }
            let halfWidth = max(Self.touchTolerance, CGFloat(drawing.text.count) * 5)
            return abs(q.x - anchor.x) <= halfWidth ? abs(q.y - anchor.y) : .infinity
        case .angle:
            guard let corner = points.first else { return .infinity }
            return points.dropFirst().map { Self.distance(q, corner, $0) }.min() ?? .infinity
        case .line, .pen:
            guard points.count > 1 else { return points.first.map { hypot($0.x - q.x, $0.y - q.y) } ?? .infinity }
            return zip(points, points.dropFirst()).map { Self.distance(q, $0, $1) }.min() ?? .infinity
        }
    }

    private static func distance(_ q: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = CGVector(dx: b.x - a.x, dy: b.y - a.y)
        let lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy
        guard lengthSquared > 0 else { return hypot(q.x - a.x, q.y - a.y) }
        let t = max(0, min(1, ((q.x - a.x) * ab.dx + (q.y - a.y) * ab.dy) / lengthSquared))
        return hypot(q.x - (a.x + t * ab.dx), q.y - (a.y + t * ab.dy))
    }
}
