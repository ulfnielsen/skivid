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

    /// An independent reimplementation of `layerFrame`'s aspect-fit, used as
    /// an oracle in the tests below rather than reusing the production
    /// formula — so a sweep that asks "is the picture large enough to cover
    /// this axis" is checking the implementation against separately-derived
    /// arithmetic, not against itself.
    private func fittedSize(video: CGSize, pane: CGSize) -> CGSize {
        let videoAspect = video.width / video.height
        let paneAspect = pane.width / pane.height
        if videoAspect > paneAspect {
            return CGSize(width: pane.width, height: pane.width / videoAspect)
        } else {
            return CGSize(width: pane.height * videoAspect, height: pane.height)
        }
    }

    // MARK: - The invariant

    /// At scale s with matched aspect, the visible picture shows 1/s of the
    /// video's own content, so the centre is confined to [1/(2s), 1 - 1/(2s)].
    /// At s == 1 that interval is the single point 0.5.
    func testOneTimesPinsTheCentreWhateverThePanHistory() {
        var zoom = VideoZoom()
        zoom.setScale(4, in: pane, videoSize: pane)
        zoom.pan(by: CGSize(width: -400, height: -300), in: pane, videoSize: pane)
        XCTAssertNotEqual(zoom.center.x, 0.5, accuracy: 0.0001, "precondition: the pan must have moved it")

        zoom.setScale(1, in: pane, videoSize: pane)

        XCTAssertEqual(zoom.center.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(zoom.center.y, 0.5, accuracy: 0.0001)
    }

    /// Zooming *out* from a panned position is the case that gets forgotten:
    /// the legal interval narrows, so a centre that was legal at 4x is not at
    /// 1.5x. Without re-clamping in `setScale` the picture hangs off the edge
    /// with black down one side.
    func testZoomingOutReclampsAPannedCentre() {
        var zoom = VideoZoom()
        zoom.setScale(4, in: pane, videoSize: pane)
        zoom.pan(by: CGSize(width: -10_000, height: 0), in: pane, videoSize: pane)
        XCTAssertEqual(zoom.center.x, 1 - 1 / 8.0, accuracy: 0.0001, "precondition: panned to the right edge at 4x")

        zoom.setScale(1.5, in: pane, videoSize: pane)

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
            zoom.setScale(2, in: pane, videoSize: pane)
            zoom.pan(by: drag, in: pane, videoSize: pane)
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
        slow.setScale(1.5, in: pane, videoSize: pane)
        slow.pan(by: CGSize(width: -80, height: 0), in: pane, videoSize: pane)

        var fast = VideoZoom()
        fast.setScale(4, in: pane, videoSize: pane)
        fast.pan(by: CGSize(width: -80, height: 0), in: pane, videoSize: pane)

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
        zoom.setScale(2, in: pane, videoSize: pane)
        zoom.pan(by: CGSize(width: 40, height: 0), in: pane, videoSize: pane)

        XCTAssertLessThan(zoom.center.x, 0.5, "dragging right must decrease the centre")
    }

    /// Not just "the centre is still 0.5" — a stub `pan` that never moved
    /// anything would pass that trivially. The contrasting drag at a real
    /// scale proves `pan` genuinely moves the centre when zoomed, so the
    /// no-op above is meaningful evidence about 1x specifically, not about an
    /// inert function. It does *not* by itself prove the `isZoomed` guard is
    /// what blocks the drag at 1x: at s == 1 the clamp interval is already
    /// the single point 0.5 regardless of that guard, so deleting `isZoomed`
    /// from `pan` passes this test too (and every other test in this file) —
    /// the invariant alone already produces the same answer. The guard stays
    /// for what it is: a clear statement of intent, not a load-bearing check
    /// this test can claim to pin.
    func testPanningIsIgnoredAtOneTimes() {
        var zoom = VideoZoom()
        zoom.pan(by: CGSize(width: 100, height: 100), in: pane, videoSize: pane)
        XCTAssertEqual(zoom, VideoZoom(), "the whole value must be untouched, not merely the centre")

        var zoomed = VideoZoom()
        zoomed.setScale(2, in: pane, videoSize: pane)
        zoomed.pan(by: CGSize(width: 100, height: 100), in: pane, videoSize: pane)
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
        zoom.setScale(2, in: pane, videoSize: pane)
        zoom.pan(by: CGSize(width: 40, height: 40), in: .zero, videoSize: pane)

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
        zoom.setScale(2, in: pane, videoSize: pane)
        zoom.pan(by: .zero, in: .zero, videoSize: pane)

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
        zoom.setScale(2, in: pane, videoSize: pane)

        zoom.pan(by: CGSize(width: CGFloat.nan, height: 0), in: pane, videoSize: pane)
        XCTAssertEqual(zoom.center.x, 0.5, accuracy: 0.0001, "a NaN component must reject the whole drag")
        XCTAssertEqual(zoom.center.y, 0.5, accuracy: 0.0001)

        // A NaN translation must not linger and poison later, ordinary calls.
        zoom.pan(by: CGSize(width: -80, height: 0), in: pane, videoSize: pane)
        XCTAssertEqual(zoom.center.x, 0.5 + 0.1 / 2.0, accuracy: 0.0001, "a normal drag afterwards must still work")

        var afterSetScale = VideoZoom()
        afterSetScale.setScale(2, in: pane, videoSize: pane)
        afterSetScale.pan(by: CGSize(width: CGFloat.nan, height: CGFloat.nan), in: pane, videoSize: pane)
        afterSetScale.setScale(3, in: pane, videoSize: pane)
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
        zoom.setScale(2, in: pane, videoSize: pane)

        zoom.setScale(.nan, in: pane, videoSize: pane)

        XCTAssertEqual(zoom.scale, 2, "a non-finite scale must be rejected, not applied")
        XCTAssertTrue(zoom.isZoomed)
        zoom.pan(by: CGSize(width: -80, height: 0), in: pane, videoSize: pane)
        XCTAssertEqual(zoom.center.x, 0.5 + 0.05, accuracy: 0.0001, "pan must still work after a rejected setScale")
    }

    // MARK: - Degenerate bounds

    /// Regression introduced by the axis-aware clamp: `setScale` gained a
    /// `bounds` parameter but not a guard on it, so a degenerate `bounds` —
    /// `.zero`, which is exactly what a `GeometryReader`-sourced pane reports
    /// before its first layout pass — reached `half`, which cannot compute a
    /// real interval against a pane that isn't one and falls back to `0.5`.
    /// That silently recentred a pan that had nothing wrong with it. Measured
    /// before this fix, starting from a 4x pan sitting at the `(0.875,
    /// 0.875)` bound: `setScale(3, in: .zero, ...)` forced the centre to
    /// `(0.5, 0.5)` instead of leaving it at 3x's own bound `(0.8333,
    /// 0.8333)` — indistinguishable on screen from the drag being silently
    /// discarded, during exactly the window a `GeometryReader`-sourced pane
    /// can be `.zero`. `pan` was never affected: it has always guarded
    /// `paneSize` before ever calling `clamped`.
    func testSetScaleIgnoresTheClampForADegenerateBounds() {
        var zoom = VideoZoom()
        zoom.setScale(4, in: pane, videoSize: pane)
        zoom.pan(by: CGSize(width: -10_000, height: -10_000), in: pane, videoSize: pane)
        XCTAssertEqual(zoom.center.x, 0.875, accuracy: 1e-9, "precondition: panned to the 4x bound")
        XCTAssertEqual(zoom.center.y, 0.875, accuracy: 1e-9, "precondition: panned to the 4x bound")

        for degenerateBounds in [
            CGSize.zero,
            CGSize(width: 0, height: 450),
            CGSize(width: CGFloat.nan, height: CGFloat.nan),
        ] {
            var degenerate = zoom
            degenerate.setScale(3, in: degenerateBounds, videoSize: pane)

            XCTAssertEqual(degenerate.scale, 3, "bounds \(degenerateBounds): the scale itself must still apply")
            XCTAssertEqual(
                degenerate.center.x, zoom.center.x, accuracy: 1e-9,
                "bounds \(degenerateBounds): a degenerate pane must not recentre an untouched, legal centre"
            )
            XCTAssertEqual(
                degenerate.center.y, zoom.center.y, accuracy: 1e-9,
                "bounds \(degenerateBounds): a degenerate pane must not recentre an untouched, legal centre"
            )
        }
    }

    // MARK: - The range

    func testTheScaleIsClampedToItsRange() {
        var zoom = VideoZoom()
        zoom.setScale(100, in: pane, videoSize: pane)
        XCTAssertEqual(zoom.scale, 4)
        zoom.setScale(0.1, in: pane, videoSize: pane)
        XCTAssertEqual(zoom.scale, 1)
    }

    func testIsZoomedIsFalseOnlyAtOneTimes() {
        var zoom = VideoZoom()
        XCTAssertFalse(zoom.isZoomed)
        zoom.setScale(1.01, in: pane, videoSize: pane)
        XCTAssertTrue(zoom.isZoomed)
    }

    func testResetReturnsToOneTimesAndCentre() {
        var zoom = VideoZoom()
        zoom.setScale(3, in: pane, videoSize: pane)
        zoom.pan(by: CGSize(width: -200, height: -200), in: pane, videoSize: pane)

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
        zoomed.setScale(2, in: pane, videoSize: pane)
        let zoomedFrame = zoomed.layerFrame(in: pane, videoSize: pane)
        XCTAssertNotEqual(zoomedFrame, CGRect(origin: .zero, size: pane))
    }

    /// Before the asset has loaded there is no `presentationSize` to pass —
    /// callers give `.zero`, or a size with a non-finite component. There is
    /// no picture on screen yet to bound, so this falls back to treating
    /// `bounds` as the fitted rect: the same numbers as
    /// `testTheLayerPutsTheCentredPointAtThePaneMiddle` below, which uses a
    /// `videoSize` equal to `pane` to establish that fitted-to-bounds is
    /// exactly the pre-load case. The mutators are driven with `videoSize:
    /// pane` too, so the centre they leave behind is the known (0.25, 0.25)
    /// that test also relies on — only the final `layerFrame` call is what's
    /// under test here.
    func testLayerFrameFallsBackToBoundsBeforeTheVideoSizeIsKnown() {
        var zoom = VideoZoom()
        zoom.setScale(2, in: pane, videoSize: pane)
        zoom.pan(by: CGSize(width: 10_000, height: 10_000), in: pane, videoSize: pane)

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
        zoom.setScale(2, in: pane, videoSize: pane)
        zoom.pan(by: CGSize(width: 10_000, height: 10_000), in: pane, videoSize: pane)
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
    /// fitting (see `testCoverageAcrossMismatchedAspectPanesAndScales` below
    /// for that). The scale sweep is dense rather than five hand-picked
    /// values.
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
                zoom.setScale(scale, in: pane, videoSize: pane)
                zoom.pan(by: drag, in: pane, videoSize: pane)
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
        zoom.setScale(3, in: tall, videoSize: tall)

        let frame = zoom.layerFrame(in: tall, videoSize: tall)

        XCTAssertEqual(frame.width, 900, accuracy: 0.0001)
        XCTAssertEqual(frame.height, 2700, accuracy: 0.0001)
        XCTAssertEqual(frame.midX, 150, accuracy: 0.0001)
        XCTAssertEqual(frame.midY, 450, accuracy: 0.0001)
    }

    // MARK: - Aspect fitting

    /// A degenerate `videoSize` (zero, negative, or non-finite in either
    /// dimension) cannot describe a real aspect ratio, so this falls back to
    /// fitting `bounds` to itself — the same numbers `layerFrame` produced
    /// before this parameter existed.
    func testFittingFallsBackToBoundsForADegenerateVideoSize() {
        var zoom = VideoZoom()
        zoom.setScale(2, in: pane, videoSize: pane)
        zoom.pan(by: CGSize(width: 10_000, height: 10_000), in: pane, videoSize: pane)

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

    // MARK: - Coverage under aspect mismatch

    /// The coordinator's exact repro for the gap that survived the first
    /// aspect-fit fix: 500x800 pane, 16:9 clip, 4x. Measured before this
    /// round's fix: the picture is 1125pt tall against an 800pt pane — big
    /// enough to fully cover — yet panned to a y bound left a 259pt (32.4%)
    /// black band the operator could not pan away, because the aspect-
    /// independent `1/(2s)` clamp let the centre travel further than the
    /// picture's own edge allowed. The axis-aware half-extent
    /// (`min(bounds / (2 * fitted * scale), 0.5)`) closes it: at this
    /// geometry the y half-extent becomes ~0.3556 instead of 0.125, so the
    /// centre cannot travel past the point that keeps the picture flush with
    /// the pane.
    func testAPortraitPaneWithASixteenByNineClipCoversCompletelyAtFourX() {
        let portraitPane = CGSize(width: 500, height: 800)
        let sixteenByNine = CGSize(width: 1920, height: 1080)
        let epsilon = 1e-6

        for (drag, description) in [
            (CGSize(width: -10_000, height: 0), "left bound"),
            (CGSize(width: 10_000, height: 0), "right bound"),
            (CGSize(width: 0, height: -10_000), "bottom bound"),
            (CGSize(width: 0, height: 10_000), "top bound"),
        ] {
            var zoom = VideoZoom()
            zoom.setScale(4, in: portraitPane, videoSize: sixteenByNine)
            zoom.pan(by: drag, in: portraitPane, videoSize: sixteenByNine)

            let frame = zoom.layerFrame(in: portraitPane, videoSize: sixteenByNine)

            XCTAssertLessThanOrEqual(frame.minX, epsilon, description)
            XCTAssertGreaterThanOrEqual(frame.maxX, portraitPane.width - epsilon, description)
            XCTAssertLessThanOrEqual(frame.minY, epsilon, description)
            XCTAssertGreaterThanOrEqual(frame.maxY, portraitPane.height - epsilon, description)
        }
    }

    /// The dense version of the case above: a portrait and a landscape pane,
    /// both with a 16:9 clip, swept across scale and drag. At every point,
    /// `fittedSize` (this file's independent oracle) says whether the
    /// picture is at least as large as the pane on each axis; where it is,
    /// full coverage on that axis must hold, and where it is not, the centre
    /// must sit exactly at 0.5 on that axis (unavoidable letterboxing,
    /// centred rather than off to one side). The previous coverage sweep
    /// used `videoSize == pane` throughout and so never exercised an aspect
    /// mismatch at all — this is the sweep that would have caught the gap
    /// this round closes.
    func testCoverageAcrossMismatchedAspectPanesAndScales() {
        let sixteenByNine = CGSize(width: 1920, height: 1080)
        let panes = [
            CGSize(width: 500, height: 800),
            CGSize(width: 800, height: 500),
        ]
        let epsilon = 1e-6

        for testPane in panes {
            let base = fittedSize(video: sixteenByNine, pane: testPane)
            for scale in stride(from: 1.0, through: 4.0, by: 0.05) {
                let xCovers = base.width * scale >= testPane.width
                let yCovers = base.height * scale >= testPane.height
                for drag in [
                    CGSize(width: -10_000, height: -10_000),
                    CGSize(width: 10_000, height: 10_000),
                    CGSize(width: -10_000, height: 10_000),
                    CGSize(width: 10_000, height: -10_000),
                ] {
                    var zoom = VideoZoom()
                    zoom.setScale(scale, in: testPane, videoSize: sixteenByNine)
                    zoom.pan(by: drag, in: testPane, videoSize: sixteenByNine)
                    let frame = zoom.layerFrame(in: testPane, videoSize: sixteenByNine)
                    let context = "pane \(testPane), scale \(scale), drag \(drag)"

                    if xCovers {
                        XCTAssertLessThanOrEqual(frame.minX, epsilon, "\(context): x gap on the left")
                        XCTAssertGreaterThanOrEqual(frame.maxX, testPane.width - epsilon, "\(context): x gap on the right")
                    } else {
                        XCTAssertEqual(zoom.center.x, 0.5, accuracy: 1e-9, "\(context): unavoidable x letterboxing must stay centred")
                    }

                    if yCovers {
                        XCTAssertLessThanOrEqual(frame.minY, epsilon, "\(context): y gap on the top")
                        XCTAssertGreaterThanOrEqual(frame.maxY, testPane.height - epsilon, "\(context): y gap on the bottom")
                    } else {
                        XCTAssertEqual(zoom.center.y, 0.5, accuracy: 1e-9, "\(context): unavoidable y letterboxing must stay centred")
                    }
                }
            }
        }
    }

    /// The degenerate case at the other end from full coverage: a picture
    /// that stays smaller than the pane on one axis even at the maximum
    /// scale. The raw half-extent formula would ask for an interval wider
    /// than [0, 1] there; capped at 0.5 it collapses the centre to the
    /// middle instead, on that axis only — the matching axis (here, width,
    /// since the pane and clip share it) behaves exactly as the
    /// matched-aspect case throughout.
    func testAPictureSmallerThanThePaneOnAnAxisPinsTheCentreThereEvenAtMaxScale() {
        let squarePane = CGSize(width: 1000, height: 1000)
        let wideClip = CGSize(width: 1000, height: 100) // 10:1 — height letterboxes hard.

        var zoom = VideoZoom()
        zoom.setScale(4, in: squarePane, videoSize: wideClip)
        zoom.pan(by: CGSize(width: 0, height: 10_000), in: squarePane, videoSize: wideClip)

        XCTAssertEqual(
            zoom.center.y, 0.5, accuracy: 1e-9,
            "the picture is 400pt tall in a 1000pt pane even at 4x; no pan can cover it, so the centre must stay put"
        )

        zoom.pan(by: CGSize(width: -10_000, height: 0), in: squarePane, videoSize: wideClip)
        XCTAssertEqual(
            zoom.center.x, 1 - 1 / 8.0, accuracy: 1e-9,
            "the matching axis (width) is unaffected: half == 1/(2*4), same as the matched-aspect case"
        )
    }

    /// `layerFrame` re-clamps against whatever `bounds`/`videoSize` it is
    /// actually called with, not the geometry the last mutator saw. A window
    /// resize is exactly this: `bounds` changes with no mutator running, so
    /// a centre that was legal — even flush with the pane — for the old size
    /// can leave an avoidable gap against the new one if it is rendered
    /// as-is.
    func testLayerFrameReClampsAfterAWindowResize() {
        let originalPane = CGSize(width: 500, height: 300)
        let resizedPane = CGSize(width: 500, height: 600)
        let clip = CGSize(width: 1920, height: 1080)

        var zoom = VideoZoom()
        zoom.setScale(4, in: originalPane, videoSize: clip)
        zoom.pan(by: CGSize(width: 0, height: 10_000), in: originalPane, videoSize: clip)

        let base = fittedSize(video: clip, pane: originalPane)
        let expectedHalf = min(originalPane.height / (2 * base.height * 4), 0.5)
        XCTAssertEqual(
            zoom.center.y, expectedHalf, accuracy: 1e-9,
            "precondition: panned to the y bound legal for the original (shorter) pane"
        )

        // No mutator has run against `resizedPane`; only `layerFrame` sees it.
        let frame = zoom.layerFrame(in: resizedPane, videoSize: clip)

        XCTAssertLessThanOrEqual(frame.minY, 1e-6, "a stale centre must not leave an avoidable gap after a resize")
        XCTAssertGreaterThanOrEqual(frame.maxY, resizedPane.height - 1e-6)
        XCTAssertLessThanOrEqual(frame.minX, 1e-6)
        XCTAssertGreaterThanOrEqual(frame.maxX, resizedPane.width - 1e-6)
    }
}
