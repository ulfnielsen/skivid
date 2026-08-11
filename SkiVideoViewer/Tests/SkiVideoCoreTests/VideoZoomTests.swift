import CoreGraphics
import XCTest
@testable import SkiVideoCore

/// The zoom geometry, tested as pure arithmetic.
///
/// No player, no fixture, no view: every claim here is about numbers, which is
/// the reason `VideoZoom` is a value type separate from the layer that applies
/// it. The clamping invariant in particular has a failure mode that is nearly
/// invisible on screen — a picture hanging a few points off one edge — and
/// exhaustively cheap to pin here.
final class VideoZoomTests: XCTestCase {
    private let pane = CGSize(width: 800, height: 450)

    // MARK: - The invariant

    /// At scale s the pane shows 1/s of the frame, so the centre is confined to
    /// [1/(2s), 1 - 1/(2s)]. At s == 1 that interval is the single point 0.5.
    func testOneTimesPinsTheCentreWhateverThePanHistory() {
        var zoom = VideoZoom()
        zoom.setScale(4)
        zoom.pan(by: CGSize(width: -400, height: -300), in: pane)
        XCTAssertNotEqual(zoom.center.x, 0.5, accuracy: 0.0001, "precondition: the pan must have moved it")

        zoom.setScale(1)

        XCTAssertEqual(zoom.center.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(zoom.center.y, 0.5, accuracy: 0.0001)
    }

    /// Zooming *out* from a panned position is the case that gets forgotten:
    /// the legal interval narrows, so a centre that was legal at 4x is not at
    /// 1.5x. Without re-clamping in `setScale` the picture hangs off the edge
    /// with black down one side.
    func testZoomingOutReclampsAPannedCentre() {
        var zoom = VideoZoom()
        zoom.setScale(4)
        zoom.pan(by: CGSize(width: -10_000, height: 0), in: pane)
        XCTAssertEqual(zoom.center.x, 1 - 1 / 8.0, accuracy: 0.0001, "precondition: panned to the right edge at 4x")

        zoom.setScale(1.5)

        XCTAssertEqual(
            zoom.center.x, 1 - 1 / 3.0, accuracy: 0.0001,
            "the centre must move to 1.5x's bound, not stay at 4x's"
        )
    }

    func testPanStopsAtEveryEdge() {
        for (drag, expected) in [
            (CGSize(width: -10_000, height: 0), CGPoint(x: 0.75, y: 0.5)),
            (CGSize(width: 10_000, height: 0), CGPoint(x: 0.25, y: 0.5)),
            (CGSize(width: 0, height: -10_000), CGPoint(x: 0.5, y: 0.75)),
            (CGSize(width: 0, height: 10_000), CGPoint(x: 0.5, y: 0.25)),
        ] {
            var zoom = VideoZoom()
            zoom.setScale(2)
            zoom.pan(by: drag, in: pane)
            XCTAssertEqual(zoom.center.x, expected.x, accuracy: 0.0001, "drag \(drag)")
            XCTAssertEqual(zoom.center.y, expected.y, accuracy: 0.0001, "drag \(drag)")
        }
    }

    // MARK: - What a drag means

    /// A drag of d points must move the picture d points on screen at every
    /// scale. The centre therefore moves by d / (paneSize * scale) — without
    /// the scale divisor a drag at 4x runs four times as fast as at 1x, which
    /// is the difference between panning and flinging.
    func testADragMovesThePictureTheSameDistanceAtEveryScale() {
        var slow = VideoZoom()
        slow.setScale(1.5)
        slow.pan(by: CGSize(width: -80, height: 0), in: pane)

        var fast = VideoZoom()
        fast.setScale(4)
        fast.pan(by: CGSize(width: -80, height: 0), in: pane)

        // 80pt of an 800pt pane, divided by the scale.
        XCTAssertEqual(slow.center.x - 0.5, 0.1 / 1.5, accuracy: 0.0001)
        XCTAssertEqual(fast.center.x - 0.5, 0.1 / 4.0, accuracy: 0.0001)
    }

    /// The operator pushes the frame around; they do not push a viewport over
    /// it. Both conventions are defensible in the abstract and only one matches
    /// every video app they have used, so it is pinned rather than left to
    /// whoever writes the gesture.
    func testDraggingRightMovesThePictureRight() {
        var zoom = VideoZoom()
        zoom.setScale(2)
        zoom.pan(by: CGSize(width: 40, height: 0), in: pane)

        XCTAssertLessThan(zoom.center.x, 0.5, "dragging right must decrease the centre")
    }

    func testPanningIsIgnoredAtOneTimes() {
        var zoom = VideoZoom()
        zoom.pan(by: CGSize(width: 100, height: 100), in: pane)

        XCTAssertEqual(zoom.center.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(zoom.center.y, 0.5, accuracy: 0.0001)
    }

    /// A zero-sized pane is what a view reports before its first layout pass.
    /// Dividing by it would give a NaN centre that no later clamp can recover.
    func testPanningInAZeroSizedPaneChangesNothing() {
        var zoom = VideoZoom()
        zoom.setScale(2)
        zoom.pan(by: CGSize(width: 40, height: 40), in: .zero)

        XCTAssertEqual(zoom.center.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(zoom.center.y, 0.5, accuracy: 0.0001)
    }

    // MARK: - The range

    func testTheScaleIsClampedToItsRange() {
        var zoom = VideoZoom()
        zoom.setScale(100)
        XCTAssertEqual(zoom.scale, 4)
        zoom.setScale(0.1)
        XCTAssertEqual(zoom.scale, 1)
    }

    func testIsZoomedIsFalseOnlyAtOneTimes() {
        var zoom = VideoZoom()
        XCTAssertFalse(zoom.isZoomed)
        zoom.setScale(1.01)
        XCTAssertTrue(zoom.isZoomed)
    }

    func testResetReturnsToOneTimesAndCentre() {
        var zoom = VideoZoom()
        zoom.setScale(3)
        zoom.pan(by: CGSize(width: -200, height: -200), in: pane)

        zoom.reset()

        XCTAssertEqual(zoom, VideoZoom())
    }

    // MARK: - Layer geometry

    func testAtOneTimesTheLayerIsExactlyThePane() {
        let frame = VideoZoom().layerFrame(in: pane)

        XCTAssertEqual(frame, CGRect(origin: .zero, size: pane))
    }

    /// `origin = bounds * 0.5 - center * bounds * s`. The plausible wrong
    /// answer, `(0.5 - center) * bounds * s`, agrees at 1x and drifts
    /// everywhere else — this case is where the two disagree.
    func testTheLayerPutsTheCentredPointAtThePaneMiddle() {
        var zoom = VideoZoom()
        zoom.setScale(2)
        zoom.pan(by: CGSize(width: 10_000, height: 10_000), in: pane)
        XCTAssertEqual(zoom.center.x, 0.25, accuracy: 0.0001, "precondition: panned to the left/top bound")

        let frame = zoom.layerFrame(in: pane)

        XCTAssertEqual(frame.origin.x, 0, accuracy: 0.0001)
        XCTAssertEqual(frame.origin.y, 0, accuracy: 0.0001)
        XCTAssertEqual(frame.width, 1600, accuracy: 0.0001)
        XCTAssertEqual(frame.height, 900, accuracy: 0.0001)
    }

    /// The pane must never show a gap: whatever the scale and wherever the pan
    /// has landed, the layer covers the whole pane. This is the invariant's
    /// consequence, asserted where the operator would actually see it fail.
    func testTheLayerAlwaysCoversThePane() {
        let paneRect = CGRect(origin: .zero, size: pane)
        for scale in [1.0, 1.5, 2.0, 3.0, 4.0] {
            for drag in [
                CGSize(width: -10_000, height: -10_000),
                CGSize(width: 10_000, height: 10_000),
                CGSize(width: -10_000, height: 10_000),
                CGSize(width: 37, height: -91),
            ] {
                var zoom = VideoZoom()
                zoom.setScale(scale)
                zoom.pan(by: drag, in: pane)
                let frame = zoom.layerFrame(in: pane)
                XCTAssertTrue(
                    frame.union(paneRect).equalTo(frame),
                    "scale \(scale), drag \(drag): layer \(frame) leaves a gap in \(paneRect)"
                )
            }
        }
    }

    /// A non-square pane is the normal case, and it is where an implementation
    /// that reuses one axis' arithmetic for both goes wrong.
    func testTheGeometryIsCorrectInANonSquarePane() {
        let tall = CGSize(width: 300, height: 900)
        var zoom = VideoZoom()
        zoom.setScale(3)

        let frame = zoom.layerFrame(in: tall)

        XCTAssertEqual(frame.width, 900, accuracy: 0.0001)
        XCTAssertEqual(frame.height, 2700, accuracy: 0.0001)
        XCTAssertEqual(frame.midX, 150, accuracy: 0.0001)
        XCTAssertEqual(frame.midY, 450, accuracy: 0.0001)
    }
}
