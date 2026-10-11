import XCTest
@testable import SkiVideoCore

final class DrawingGeometryTests: XCTestCase {
    private let video = CGSize(width: 1920, height: 1080)

    func testRoundTripAtSeveralZoomsAndPans() {
        let pane = CGSize(width: 800, height: 600)   // letterboxed: different aspect
        for scale in [1.0, 2.0, 4.0] {
            for pan in [CGSize.zero, CGSize(width: 5000, height: 5000), CGSize(width: -5000, height: -5000)] {
                var zoom = VideoZoom()
                zoom.setScale(scale, in: pane, videoSize: video)
                zoom.pan(by: pan, in: pane, videoSize: video)
                let g = DrawingGeometry(zoom: zoom, paneSize: pane, videoSize: video)
                for p in [CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.8), CGPoint(x: 1, y: 1)] {
                    let back = g.toPicture(g.toPane(p))
                    XCTAssertEqual(back.x, p.x, accuracy: 1e-9, "scale \(scale) pan \(pan)")
                    XCTAssertEqual(back.y, p.y, accuracy: 1e-9, "scale \(scale) pan \(pan)")
                }
            }
        }
    }

    /// The mapping must be the picture's own frame — the one the player layer
    /// is placed at — or marks drift off the snow when zooming.
    func testThePictureFrameIsTheZoomedLayerFrame() {
        let pane = CGSize(width: 800, height: 600)
        var zoom = VideoZoom()
        zoom.setScale(3, in: pane, videoSize: video)
        let g = DrawingGeometry(zoom: zoom, paneSize: pane, videoSize: video)
        XCTAssertEqual(g.pictureFrame, zoom.layerFrame(in: pane, videoSize: video))
        XCTAssertEqual(g.toPane(CGPoint(x: 0, y: 0)), g.pictureFrame.origin)
    }

    func testARightAngle() {
        let a = DrawingGeometry.angle(corner: CGPoint(x: 0.5, y: 0.5), a: CGPoint(x: 0.8, y: 0.5),
                                      b: CGPoint(x: 0.5, y: 0.1), videoSize: video)
        XCTAssertEqual(a, 90, accuracy: 1e-9)
    }

    /// 45° in pixels on a 16:9 picture is NOT 45° in normalized space: equal
    /// pixel offsets are (0.1, 0.1·16/9) in fractions. A normalized-space
    /// computation reads ~29.4° here.
    func testAnAngleIsMeasuredInPixelsNotFractions() {
        let corner = CGPoint(x: 0.5, y: 0.5)
        let a = CGPoint(x: 0.6, y: 0.5)
        let b = CGPoint(x: 0.6, y: 0.5 - 0.1 * 1920 / 1080)
        XCTAssertEqual(DrawingGeometry.angle(corner: corner, a: a, b: b, videoSize: video), 45, accuracy: 1e-6)
    }

    func testADegenerateArmReadsZeroRatherThanNaN() {
        let p = CGPoint(x: 0.5, y: 0.5)
        XCTAssertEqual(DrawingGeometry.angle(corner: p, a: p, b: CGPoint(x: 0.9, y: 0.5), videoSize: video), 0)
    }

    func testHitFindsALineNearItsSegmentAndPrefersTheTopmost() {
        let g = DrawingGeometry(pictureFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000), videoSize: video)
        let under = Drawing(kind: .line, color: .red, points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5)], start: 0)
        let over = Drawing(kind: .line, color: .blue, points: [CGPoint(x: 0.5, y: 0.1), CGPoint(x: 0.5, y: 0.9)], start: 0)
        XCTAssertEqual(g.hit(CGPoint(x: 300, y: 510), in: [under, over]), under.id)
        XCTAssertEqual(g.hit(CGPoint(x: 500, y: 500), in: [under, over]), over.id, "the later mark is drawn on top")
        XCTAssertNil(g.hit(CGPoint(x: 300, y: 600), in: [under, over]))
    }

    func testHitFindsAnAngleByEitherArm() {
        let g = DrawingGeometry(pictureFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000), videoSize: video)
        let angle = Drawing(kind: .angle, color: .red,
                            points: [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.9, y: 0.5), CGPoint(x: 0.5, y: 0.1)], start: 0)
        XCTAssertEqual(g.hit(CGPoint(x: 700, y: 505), in: [angle]), angle.id)
        XCTAssertEqual(g.hit(CGPoint(x: 505, y: 300), in: [angle]), angle.id)
        XCTAssertNil(g.hit(CGPoint(x: 700, y: 300), in: [angle]), "the space between the arms is not the mark")
    }

    func testHandlesAreOfferedForLinesAndAnglesOnly() {
        let g = DrawingGeometry(pictureFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000), videoSize: video)
        let line = Drawing(kind: .line, color: .red, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.9)], start: 0)
        XCTAssertEqual(g.handle(CGPoint(x: 905, y: 895), of: line), 1)
        XCTAssertNil(g.handle(CGPoint(x: 500, y: 500), of: line), "the middle of a line is not a handle")
        let pen = Drawing(kind: .pen, color: .red, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.9)], start: 0)
        XCTAssertNil(g.handle(CGPoint(x: 100, y: 100), of: pen), "pen strokes cannot be reshaped")
    }
}
