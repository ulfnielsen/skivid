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

    /// At scale s the visible picture shows 1/s of the video's own content, so
    /// the centre is confined to [1/(2s), 1 - 1/(2s)]. At s == 1 that interval
    /// is the single point 0.5.
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

    /// Not just "the centre is still 0.5" — a stub `pan` that never moved
    /// anything would pass that trivially. The contrasting drag at a real
    /// scale proves the no-op above is the `isZoomed` guard doing work against
    /// a `pan` that does move the centre elsewhere, not an inert function.
    func testPanningIsIgnoredAtOneTimes() {
        var zoom = VideoZoom()
        zoom.pan(by: CGSize(width: 100, height: 100), in: pane)
        XCTAssertEqual(zoom, VideoZoom(), "the whole value must be untouched, not merely the centre")

        var zoomed = VideoZoom()
        zoomed.setScale(2)
        zoomed.pan(by: CGSize(width: 100, height: 100), in: pane)
        XCTAssertNotEqual(zoomed.center, VideoZoom().center, "precondition: the same drag does move it when zoomed")
    }

    /// A zero-sized pane is what a view reports before its first layout pass.
    /// This drag is the ±infinity branch specifically: `40 / 0` is infinite,
    /// not NaN, and `clamped` resolves an infinite input to a definite (but
    /// wrong) edge on its own — which is exactly why the guard on `paneSize`
    /// cannot be skipped in favour of trusting the clamp. See
    /// `testPanningWithNoTranslationInAZeroSizedPaneChangesNothing` for the
    /// companion 0/0 = NaN branch, which the clamp cannot resolve at all.
    func testPanningInAZeroSizedPaneChangesNothing() {
        var zoom = VideoZoom()
        zoom.setScale(2)
        zoom.pan(by: CGSize(width: 40, height: 40), in: .zero)

        XCTAssertEqual(zoom.center.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(zoom.center.y, 0.5, accuracy: 0.0001)
    }

    /// The companion to the test above: a translation of exactly zero divided
    /// by a zero-sized pane is 0/0 = NaN, not infinity, and `clamped` cannot
    /// resolve a NaN at all — it would poison `center` permanently, recoverable
    /// only by `reset()`. The guard on `paneSize` closes this branch before the
    /// division ever happens, so it never reaches the clamp to fail there.
    func testPanningWithNoTranslationInAZeroSizedPaneChangesNothing() {
        var zoom = VideoZoom()
        zoom.setScale(2)
        zoom.pan(by: .zero, in: .zero)

        XCTAssertEqual(zoom.center.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(zoom.center.y, 0.5, accuracy: 0.0001)
    }

    // MARK: - Non-finite inputs

    /// Measured without the guard: a NaN `translation.width` poisons `center`
    /// to `(nan, 0.5)`, and neither a further `pan` nor `setScale` recovers
    /// it — only `reset()` does. `min`/`max` propagate NaN rather than
    /// absorbing it, so `clamped` cannot save a NaN centre once it exists;
    /// the fix is to never let one in.
    func testPanRejectsANonFiniteTranslation() {
        var zoom = VideoZoom()
        zoom.setScale(2)

        zoom.pan(by: CGSize(width: CGFloat.nan, height: 0), in: pane)
        XCTAssertEqual(zoom.center.x, 0.5, accuracy: 0.0001, "a NaN component must reject the whole drag")
        XCTAssertEqual(zoom.center.y, 0.5, accuracy: 0.0001)

        // A NaN translation must not linger and poison later, ordinary calls.
        zoom.pan(by: CGSize(width: -80, height: 0), in: pane)
        XCTAssertEqual(zoom.center.x, 0.5 + 0.1 / 2.0, accuracy: 0.0001, "a normal drag afterwards must still work")

        var afterSetScale = VideoZoom()
        afterSetScale.setScale(2)
        afterSetScale.pan(by: CGSize(width: CGFloat.nan, height: CGFloat.nan), in: pane)
        afterSetScale.setScale(3)
        XCTAssertEqual(afterSetScale.center.x, 0.5, accuracy: 0.0001, "setScale must not inherit a poisoned centre")
        XCTAssertEqual(afterSetScale.center.y, 0.5, accuracy: 0.0001)
    }

    /// `setScale`'s own clamp has the identical NaN hazard: `min(max(nan, 1),
    /// 4) == nan`, so an unguarded `setScale(.nan)` would leave `scale` itself
    /// NaN — breaking the type's headline promise that `scale` lives in
    /// `range` — and `isZoomed` would read false (`nan > 1` is false),
    /// silently killing every later `pan` with no signal why.
    func testSetScaleRejectsANonFiniteScale() {
        var zoom = VideoZoom()
        zoom.setScale(2)

        zoom.setScale(.nan)

        XCTAssertEqual(zoom.scale, 2, "a non-finite scale must be rejected, not applied")
        XCTAssertTrue(zoom.isZoomed)
        zoom.pan(by: CGSize(width: -80, height: 0), in: pane)
        XCTAssertEqual(zoom.center.x, 0.5 + 0.05, accuracy: 0.0001, "pan must still work after a rejected setScale")
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

    /// `videoSize == pane` makes the fitted rect exactly the pane, so this
    /// pins the same claim as before. The second half is the part a stub
    /// `layerFrame` that always returns `bounds` regardless of `scale` and
    /// `center` would not survive: a zoomed layer must be a different rect.
    func testAtOneTimesTheLayerIsExactlyThePane() {
        let frame = VideoZoom().layerFrame(in: pane, videoSize: pane)
        XCTAssertEqual(frame, CGRect(origin: .zero, size: pane))

        var zoomed = VideoZoom()
        zoomed.setScale(2)
        let zoomedFrame = zoomed.layerFrame(in: pane, videoSize: pane)
        XCTAssertNotEqual(zoomedFrame, CGRect(origin: .zero, size: pane))
    }

    /// Before the asset has loaded there is no `presentationSize` to pass —
    /// callers give `.zero`, or a size with a non-finite component. There is
    /// no picture on screen yet to bound, so this falls back to treating
    /// `bounds` as the fitted rect: the same numbers as
    /// `testTheLayerPutsTheCentredPointAtThePaneMiddle` below, which uses a
    /// `videoSize` equal to `pane` to establish that fitted-to-bounds is
    /// exactly the pre-load case.
    func testLayerFrameFallsBackToBoundsBeforeTheVideoSizeIsKnown() {
        var zoom = VideoZoom()
        zoom.setScale(2)
        zoom.pan(by: CGSize(width: 10_000, height: 10_000), in: pane)

        for videoSize in [
            CGSize.zero,
            CGSize(width: CGFloat.nan, height: 100),
            CGSize(width: 100, height: CGFloat.infinity),
        ] {
            let frame = zoom.layerFrame(in: pane, videoSize: videoSize)
            XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 1600, height: 900), "videoSize \(videoSize)")
        }
    }

    /// `origin = bounds * 0.5 - center * bounds * s`. The plausible wrong
    /// answer, `(0.5 - center) * bounds * s`, agrees at 1x and drifts
    /// everywhere else — this case is where the two disagree. `videoSize ==
    /// pane` keeps the fitted rect equal to `bounds`, isolating the origin
    /// arithmetic from the aspect-fitting this file tests separately below.
    func testTheLayerPutsTheCentredPointAtThePaneMiddle() {
        var zoom = VideoZoom()
        zoom.setScale(2)
        zoom.pan(by: CGSize(width: 10_000, height: 10_000), in: pane)
        XCTAssertEqual(zoom.center.x, 0.25, accuracy: 0.0001, "precondition: panned to the left/top bound")

        let frame = zoom.layerFrame(in: pane, videoSize: pane)

        XCTAssertEqual(frame.origin.x, 0, accuracy: 0.0001)
        XCTAssertEqual(frame.origin.y, 0, accuracy: 0.0001)
        XCTAssertEqual(frame.width, 1600, accuracy: 0.0001)
        XCTAssertEqual(frame.height, 900, accuracy: 0.0001)
    }

    /// The pane must never show a gap: whatever the scale and wherever the pan
    /// has landed, the layer covers the whole pane. This is the invariant's
    /// consequence, asserted where the operator would actually see it fail.
    /// `videoSize == pane` keeps this about the clamp, not about aspect
    /// fitting (see `testThePictureNeverLeavesANonSquarePaneEntirely` for
    /// that). The scale sweep is dense rather than five hand-picked values.
    ///
    /// Containment is checked edge-by-edge with a point-sized epsilon rather
    /// than via `union(_:).equalTo(_:)`: `frame.width` is computed directly
    /// (`base.width * scale`), while `union`'s width is reconstructed as
    /// `maxX - minX` — a different arithmetic path that lands a few ULPs off
    /// even when containment holds with room to spare, which made the exact
    /// `equalTo` comparison fail on drags nowhere near a real gap.
    func testTheLayerAlwaysCoversThePane() {
        let epsilon = 1e-9
        for scale in stride(from: 1.0, through: 4.0, by: 0.01) {
            for drag in [
                CGSize(width: -10_000, height: -10_000),
                CGSize(width: 10_000, height: 10_000),
                CGSize(width: -10_000, height: 10_000),
                CGSize(width: 37, height: -91),
            ] {
                var zoom = VideoZoom()
                zoom.setScale(scale)
                zoom.pan(by: drag, in: pane)
                let frame = zoom.layerFrame(in: pane, videoSize: pane)
                XCTAssertLessThanOrEqual(frame.minX, epsilon, "scale \(scale), drag \(drag): gap on the left")
                XCTAssertGreaterThanOrEqual(
                    frame.maxX, pane.width - epsilon, "scale \(scale), drag \(drag): gap on the right"
                )
                XCTAssertLessThanOrEqual(frame.minY, epsilon, "scale \(scale), drag \(drag): gap on the top")
                XCTAssertGreaterThanOrEqual(
                    frame.maxY, pane.height - epsilon, "scale \(scale), drag \(drag): gap on the bottom"
                )
            }
        }
    }

    /// A non-square pane is the normal case, and it is where an implementation
    /// that reuses one axis' arithmetic for both goes wrong. `videoSize ==
    /// tall` again isolates this from aspect fitting.
    func testTheGeometryIsCorrectInANonSquarePane() {
        let tall = CGSize(width: 300, height: 900)
        var zoom = VideoZoom()
        zoom.setScale(3)

        let frame = zoom.layerFrame(in: tall, videoSize: tall)

        XCTAssertEqual(frame.width, 900, accuracy: 0.0001)
        XCTAssertEqual(frame.height, 2700, accuracy: 0.0001)
        XCTAssertEqual(frame.midX, 150, accuracy: 0.0001)
        XCTAssertEqual(frame.midY, 450, accuracy: 0.0001)
    }

    // MARK: - Aspect fitting

    /// This is the case the first version of `layerFrame` got wrong: it
    /// scaled the pane's own (mismatched) aspect instead of the video's, so
    /// `.resizeAspect` could letterbox the real picture completely off the
    /// pane while the layer still nominally "covered" it. Measured there:
    /// a 500x800 pane with a 16:9 clip at 4x sent the picture to
    /// y=[1038, 2162] against a pane of [0, 800] — 0% visible, at the exact
    /// moment the operator has hit a pan bound and most needs to see the
    /// edge they hit.
    ///
    /// This does not claim the picture fully covers the pane at every bound
    /// — with a real aspect mismatch, some letterboxing surviving a hard pan
    /// is expected, not a bug. It claims the picture never vanishes, and that
    /// the axis matching the pane's own aspect (width, here) is still always
    /// fully covered exactly as it was before this fix.
    func testThePictureNeverLeavesANonSquarePaneEntirely() {
        let portraitPane = CGSize(width: 500, height: 800)
        let sixteenByNine = CGSize(width: 1920, height: 1080)
        let paneRect = CGRect(origin: .zero, size: portraitPane)

        for (drag, description) in [
            (CGSize(width: -10_000, height: 0), "left bound"),
            (CGSize(width: 10_000, height: 0), "right bound"),
            (CGSize(width: 0, height: -10_000), "bottom bound"),
            (CGSize(width: 0, height: 10_000), "top bound"),
        ] {
            var zoom = VideoZoom()
            zoom.setScale(4)
            zoom.pan(by: drag, in: portraitPane)

            let frame = zoom.layerFrame(in: portraitPane, videoSize: sixteenByNine)
            let overlap = frame.intersection(paneRect)

            XCTAssertFalse(overlap.isEmpty, "\(description): the picture must not vanish off the pane, got \(frame)")
            XCTAssertGreaterThan(
                overlap.width * overlap.height,
                portraitPane.width * portraitPane.height * 0.25,
                "\(description): the visible picture must be a substantial fraction of the pane, got \(frame)"
            )
            // The pane's own aspect (width-constrained here) is unaffected by
            // the letterboxing on the other axis and must still be exact.
            XCTAssertEqual(overlap.width, portraitPane.width, accuracy: 0.0001, description)
        }
    }

    /// A degenerate `videoSize` (zero, negative, or non-finite in either
    /// dimension) cannot describe a real aspect ratio, so this falls back to
    /// fitting `bounds` to itself — the same numbers `layerFrame` produced
    /// before this parameter existed.
    func testFittingFallsBackToBoundsForADegenerateVideoSize() {
        var zoom = VideoZoom()
        zoom.setScale(2)
        zoom.pan(by: CGSize(width: 10_000, height: 10_000), in: pane)

        for videoSize in [
            CGSize.zero,
            CGSize(width: -100, height: 100),
            CGSize(width: 100, height: 0),
            CGSize(width: CGFloat.infinity, height: 100),
        ] {
            let frame = zoom.layerFrame(in: pane, videoSize: videoSize)
            XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 1600, height: 900), "videoSize \(videoSize)")
        }
    }
}
