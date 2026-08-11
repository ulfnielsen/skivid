# Video Zoom and Pan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 1×–4× zoom with drag-to-pan to the single viewer and to the comparison window, per side in the latter.

**Architecture:** A pure `VideoZoom` value type in `SkiVideoCore` owns the scale, the pan centre, the clamping invariant, and the layer geometry. `SinglePlayerView`'s `AVPlayerLayer` host applies the geometry by setting the layer's frame, so the layer renders at the magnified size instead of upscaling a bitmap. The viewer moves onto that same view, retiring `NativePlayerView` on both platforms and making 1× mean the whole frame everywhere.

**Tech Stack:** Swift 6.1 toolchain, `swiftLanguageModes: [.v5]`, SwiftPM, AVFoundation, AppKit/UIKit representables, SwiftUI, XCTest.

## Global Constraints

- **Test command.** A bare `swift test` fails on this machine with `no such module 'XCTest'` — `xcode-select -p` points at `/Library/Developer/CommandLineTools`, which ships no XCTest. Always run:
  ```bash
  swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  ```
  Filtered runs need the same prefix. A full run is ~165 s and the baseline is **469 tests, 0 failures, 2 skipped**.
- **Known pre-existing flake, not yours:** `CorrectedStartWiringTests.testACorrectionSurvivesReopeningThePair` intermittently fails on a real-media `settle()` race. Re-run; do not investigate.
- Platforms: `.macOS(.v13)`, `.iOS(.v17)`. The iPad target is `TARGETED_DEVICE_FAMILY: "2"` — iPad only, no iPhone.
- `SkiVideoCore` must stay platform-agnostic: `CorePurityTests` fails the build if a core source names AppKit or UIKit. `VideoZoom` imports Foundation and CoreGraphics only.
- Access levels stay narrow: `public` marks only what the app target touches. `VideoZoom` is public (the views read it); helpers stay internal.
- **Exact values.** Zoom range `1.0...4.0`. Pan centre normalised, clamped to `[1/(2s), 1 − 1/(2s)]` in both axes. Layer frame: `fitted` = the largest rect of the video's aspect that fits `bounds`, then `size = fitted × s`, `origin = bounds × 0.5 − center × size`. (Corrected after Task 1's review — scaling `bounds` instead of `fitted` clamps a box around the picture rather than the picture, and lets a 16:9 clip be panned entirely off a 500×800 pane at 4×.) A drag of `d` points moves the centre by `d / (paneSize × scale)`, and **dragging right decreases `center.x`**.
- This codebase documents *why* heavily, with measured evidence. A load-bearing decision without its reasoning is a defect; a comment restating the code is noise.
- Commit messages: imperative mood, no `feat:`/`fix:` prefixes. End each with:
  ```
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  ```
- The repo has unrelated uncommitted images in `AppBundle/`. Stage by explicit path — never `git add -A`.

## File Structure

**Create:**
- `Sources/SkiVideoCore/VideoZoom.swift` — the value type: scale, centre, clamping, drag arithmetic, layer geometry. No AVFoundation, no UI.
- `Sources/SkiVideoViewer/Shared/ZoomControl.swift` — the reusable control (−, slider, +, resettable level readout). Values and a closure, no model, matching `TransportControls`.
- `Tests/SkiVideoCoreTests/VideoZoomTests.swift`
- `Tests/SkiVideoViewerTests/ZoomWiringTests.swift`

**Modify:**
- `Sources/SkiVideoViewer/Shared/SinglePlayerView.swift` — take a `VideoZoom`, apply `layerFrame`, clip.
- `Sources/SkiVideoCore/ViewerModel.swift` — `zoom`, its mutators, reset on library change.
- `Sources/SkiVideoCore/ComparisonModel.swift` — `leftZoom`/`rightZoom`, `zoom(for:)`, mutators.
- `Sources/SkiVideoViewer/Shared/ViewerPane.swift` — pass the zoom, drag to pan.
- `Sources/SkiVideoViewer/Shared/ViewerControlBar.swift` — the zoom control.
- `Sources/SkiVideoViewer/Shared/ComparisonPane.swift` — per-side chip and drag.
- `Sources/SkiVideoViewer/Shared/OverlayPlayerStack.swift` — one zoom for the stack.
- `Sources/SkiVideoViewer/Shared/ComparisonView.swift` — pass the left zoom to the stack, chip for the overlay.
- `Tests/SkiVideoViewerTests/ViewerLayoutMeasurementTests.swift` — re-measure the bar's ideal width.

**Delete:**
- `Sources/SkiVideoViewer/macOS/NativePlayerView.swift`
- `Sources/SkiVideoViewer/iOS/NativePlayerView.swift`

---

### Task 1: `VideoZoom`

The whole correctness question lives here, and it is testable with no media and no UI. Nothing else changes in this task.

**Files:**
- Create: `Sources/SkiVideoCore/VideoZoom.swift`
- Test: `Tests/SkiVideoCoreTests/VideoZoomTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public struct VideoZoom: Equatable, Sendable` with `public static let range: ClosedRange<Double>`, `public init()`, `public private(set) var scale: Double`, `public private(set) var center: CGPoint`, `public var isZoomed: Bool`, `public mutating func setScale(_: Double)`, `public mutating func pan(by: CGSize, in: CGSize)`, `public mutating func reset()`, `public func layerFrame(in bounds: CGSize) -> CGRect`. Every later task drives exactly these.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SkiVideoCoreTests/VideoZoomTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter VideoZoomTests`
Expected: FAIL to compile — `cannot find 'VideoZoom' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/SkiVideoCore/VideoZoom.swift`:

```swift
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter VideoZoomTests`
Expected: PASS, 14 tests.

- [ ] **Step 5: Run the whole suite and commit**

```bash
swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
git add Sources/SkiVideoCore/VideoZoom.swift Tests/SkiVideoCoreTests/VideoZoomTests.swift
git commit -m "Add the zoom geometry as a value type

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Apply the zoom in `SinglePlayerView`

> **Corrected 2026-08-11, after Task 1's review.** `layerFrame` gained a
> `videoSize:` parameter. Task 1's original form scaled the *pane's* rect, which
> clamps a box around the picture rather than the picture: measured, a 16:9 clip
> in a 500×800 pane could be panned until **0% of it was visible** at 4×, with
> the pan at its bound. It now scales the video's aspect-fitted rect, so the
> picture and the layer coincide.
>
> The consequence for this task: the host view must read the item's
> `presentationSize` and pass it, and must re-place the layer when that size
> *arrives* — it is `.zero` until the asset loads, so a layer placed once at
> `makeNSView` time would keep the pre-load fallback geometry forever. Observe
> `AVPlayerItem.presentationSize` (KVO) or re-apply on the periodic time
> observer's first non-zero reading; `ComparisonModel.observeDuration` is the
> house pattern for "the size arrives after the item does".

**Files:**
- Modify: `Sources/SkiVideoViewer/Shared/SinglePlayerView.swift`
- Test: `Tests/SkiVideoViewerTests/ZoomWiringTests.swift` (create)

**Interfaces:**
- Consumes: `VideoZoom.layerFrame(in:videoSize:)` from Task 1.
- Produces: `SinglePlayerView(player:zoom:)` with `zoom` defaulting to `VideoZoom()`; `PlayerLayerHostView.apply(_ zoom: VideoZoom)` and a readable `appliedZoom`. Tasks 3–6 construct the view with a zoom.

- [ ] **Step 1: Write the failing test**

Create `Tests/SkiVideoViewerTests/ZoomWiringTests.swift`:

```swift
import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import SkiVideoCore
@testable import SkiVideoViewer

/// That the zoom an operator sets actually reaches the layer that draws the
/// video, and that each screen passes the right one.
///
/// `VideoZoomTests` proves the arithmetic; this file proves the wiring. Neither
/// substitutes for the other: `layerFrame` can be perfect while the view hands
/// it the wrong pane size, or the wrong side's zoom.
@MainActor
final class ZoomWiringTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // NSHostingView lays nothing out until the shared application exists.
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    func testTheHostViewGivesItsLayerTheZoomedFrame() {
        let view = PlayerLayerHostView()
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 450)
        var zoom = VideoZoom()
        zoom.setScale(2)

        view.apply(zoom)
        view.layout()

        XCTAssertEqual(view.playerLayerFrame.width, 1600, accuracy: 0.5)
        XCTAssertEqual(view.playerLayerFrame.height, 900, accuracy: 0.5)
    }

    /// The layer must be clipped, or a zoomed pane paints over its neighbour —
    /// which in the comparison window is the other athlete.
    func testTheHostViewClipsItsLayer() {
        let view = PlayerLayerHostView()

        XCTAssertTrue(view.layer?.masksToBounds == true)
    }

    func testZoomingAfterLayoutMovesTheLayer() {
        let view = PlayerLayerHostView()
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 450)
        view.apply(VideoZoom())
        view.layout()
        XCTAssertEqual(view.playerLayerFrame.width, 800, accuracy: 0.5, "precondition: 1x is the pane")

        var zoom = VideoZoom()
        zoom.setScale(4)
        view.apply(zoom)

        XCTAssertEqual(
            view.playerLayerFrame.width, 3200, accuracy: 0.5,
            "apply must re-place the layer, not wait for the next layout pass"
        )
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ZoomWiringTests`
Expected: FAIL to compile — no `apply` and no `playerLayerFrame`.

- [ ] **Step 3: Implement**

In `Sources/SkiVideoViewer/Shared/SinglePlayerView.swift`, change the SwiftUI wrapper and both platform hosts. macOS branch:

```swift
struct SinglePlayerView: View {
    let player: AVPlayer
    /// Defaulted so the pure-renderer call sites that predate zoom — and the
    /// tests that build this view without one — stay honest about not passing
    /// one.
    var zoom: VideoZoom = VideoZoom()

    var body: some View {
        PlayerLayerRepresentable(player: player, zoom: zoom)
    }
}
```

The representable passes both through in `makeNSView`/`updateNSView`:

```swift
    func updateNSView(_ view: PlayerLayerHostView, context: Context) {
        view.attach(player)
        view.apply(zoom)
    }
```

On `PlayerLayerHostView`:

```swift
    private var zoom = VideoZoom()

    /// Readable for the same reason `attachedPlayer` is: the geometry is the
    /// whole of the zoom behaviour and no renderer this project has measured
    /// draws an `AVPlayerLayer`'s content, so pixels cannot answer "did it
    /// zoom".
    var playerLayerFrame: CGRect { playerLayer.frame }

    func apply(_ zoom: VideoZoom) {
        guard zoom != self.zoom else { return }
        self.zoom = zoom
        placeLayer()
    }

    override func layout() {
        super.layout()
        placeLayer()
    }

    /// Layer frame changes animate implicitly, which lags the video during a
    /// window resize and turns every zoom step into a slide. Apply them
    /// immediately.
    private func placeLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = zoom.layerFrame(
            in: bounds.size,
            videoSize: playerLayer.player?.currentItem?.presentationSize ?? .zero
        )
        CATransaction.commit()
    }
```

and in `configure()`, add `host.masksToBounds = true` beside the existing gravity line, with a comment that an unclipped zoomed layer paints over the neighbouring pane.

Mirror all of it in the UIKit branch. Note the UIKit host uses `layerClass`, so the `AVPlayerLayer` *is* the view's layer: there, `placeLayer` sets `layer.frame` on a sublayer added the same way as macOS — restructure the iOS branch to hold a separate `AVPlayerLayer` sublayer like macOS does, so both platforms have one geometry path. Say in the report that you did.

- [ ] **Step 4: Run the tests**

Run: `swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ZoomWiringTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Measure the sharpness risk**

The spec's first risk: enlarging the layer frame *should* make `AVPlayerLayer` render at the larger size rather than upscale a bitmap. Check it before anything is built on top.

Write a throwaway harness that loads a real clip (`makeRealVideoFile(in:name:seconds:)` in `Tests/SkiVideoCoreTests/RealVideoFixture.swift` generates one; use a larger `width`/`height` than its 160×90 default so upscaling would be visible), puts it in a `PlayerLayerHostView` at 4×, and reports whether the layer's `contentsScale` and rendered size follow the frame. Record what you measured in the report and delete the harness.

If it does upscale, STOP and report — the fallback (render at native resolution and clip) changes Task 2's shape and needs a decision.

- [ ] **Step 6: Run the suite and commit**

```bash
swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
git add Sources/SkiVideoViewer/Shared/SinglePlayerView.swift Tests/SkiVideoViewerTests/ZoomWiringTests.swift
git commit -m "Let the player layer draw a zoomed rect

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `ZoomControl`

The control on its own, with no caller — same shape as `TransportControls`: values and a closure, no model, so both screens can drive it.

**Files:**
- Create: `Sources/SkiVideoViewer/Shared/ZoomControl.swift`
- Test: `Tests/SkiVideoViewerTests/ZoomWiringTests.swift` (extend)

**Interfaces:**
- Consumes: `VideoZoom` (Task 1).
- Produces: `ZoomControl(zoom: VideoZoom, isEnabled: Bool, onScale: (Double) -> Void, onReset: () -> Void)`, and `static func label(for: Double) -> String`. Tasks 4 and 5 place it.

- [ ] **Step 1: Write the failing test**

Add to `Tests/SkiVideoViewerTests/ZoomWiringTests.swift`:

```swift
    // MARK: - The control

    func testTheZoomLabelReadsAsAMultiplier() {
        XCTAssertEqual(ZoomControl.label(for: 1), "1.0×")
        XCTAssertEqual(ZoomControl.label(for: 2.5), "2.5×")
        XCTAssertEqual(ZoomControl.label(for: 4), "4.0×")
    }

    func testTheMinusButtonStepsDownAndThePlusButtonStepsUp() {
        var requested: [Double] = []
        var zoom = VideoZoom()
        zoom.setScale(2)
        let control = ZoomControl(zoom: zoom, isEnabled: true, onScale: { requested.append($0) }, onReset: {})

        let host = NSHostingView(rootView: control.frame(width: 400, height: 60))
        host.layoutSubtreeIfNeeded()
        let buttons = Self.buttons(in: host)
        XCTAssertEqual(buttons.count, 3, "precondition: minus, plus and the resettable level")

        buttons[0].performClick(nil)
        buttons[1].performClick(nil)

        XCTAssertEqual(requested, [1.5, 2.5], "each press must step by 0.5 from the current scale")
    }

    func testTheLevelReadoutResets() {
        var didReset = false
        var zoom = VideoZoom()
        zoom.setScale(3)
        let control = ZoomControl(zoom: zoom, isEnabled: true, onScale: { _ in }, onReset: { didReset = true })

        let host = NSHostingView(rootView: control.frame(width: 400, height: 60))
        host.layoutSubtreeIfNeeded()
        Self.buttons(in: host)[2].performClick(nil)

        XCTAssertTrue(didReset, "the level is the route to 1x that does not depend on gesture arbitration")
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton { found.append(button) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ZoomWiringTests`
Expected: FAIL to compile — `cannot find 'ZoomControl' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/SkiVideoViewer/Shared/ZoomControl.swift`:

```swift
import SkiVideoCore
import SwiftUI

/// Zoom out, a slider, zoom in, and the level — which is itself the reset.
///
/// Values and a closure, no model, exactly as `TransportControls`: the viewer
/// and the two comparison panes have different models and nothing here needs to
/// know which one it is driving.
///
/// **The level is a button on purpose.** Double-clicking the video also resets,
/// but adding a double-tap beside the viewer's existing single-tap play/pause
/// makes SwiftUI wait to see whether a second tap is coming. This is the route
/// that does not depend on gesture arbitration, and if that delay measures
/// perceptible the double-click goes and this stays.
struct ZoomControl: View {
    let zoom: VideoZoom
    let isEnabled: Bool
    let onScale: (Double) -> Void
    let onReset: () -> Void

    /// Coarse enough that the buttons reach 4x in six presses, fine enough to
    /// frame two clips to the same size.
    private static let step = 0.5

    static func label(for scale: Double) -> String {
        String(format: "%.1f×", scale)
    }

    var body: some View {
        HStack(spacing: 4) {
            stepButton("minus.magnifyingglass", "Zoom out", to: zoom.scale - Self.step)
            Slider(
                value: Binding(get: { zoom.scale }, set: onScale),
                in: VideoZoom.range
            )
            .frame(minWidth: 80)
            .accessibilityLabel("Zoom")
            stepButton("plus.magnifyingglass", "Zoom in", to: zoom.scale + Self.step)
            Button {
                onReset()
            } label: {
                Text(Self.label(for: zoom.scale))
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Reset zoom")
            .accessibilityLabel("Reset zoom, currently \(Self.label(for: zoom.scale))")
            .disabled(!isEnabled)
        }
        .disabled(!isEnabled)
    }

    private func stepButton(_ symbol: String, _ label: String, to scale: Double) -> some View {
        Button {
            onScale(scale)
        } label: {
            Image(systemName: symbol)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
        .disabled(!isEnabled)
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ZoomWiringTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Run the suite and commit**

```bash
swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
git add Sources/SkiVideoViewer/Shared/ZoomControl.swift Tests/SkiVideoViewerTests/ZoomWiringTests.swift
git commit -m "Add the shared zoom control

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: The viewer zooms

**Files:**
- Modify: `Sources/SkiVideoCore/ViewerModel.swift`
- Modify: `Sources/SkiVideoViewer/Shared/ViewerPane.swift`
- Modify: `Sources/SkiVideoViewer/Shared/ViewerControlBar.swift`
- Delete: `Sources/SkiVideoViewer/macOS/NativePlayerView.swift`, `Sources/SkiVideoViewer/iOS/NativePlayerView.swift`
- Test: `Tests/SkiVideoCoreTests/ViewerModelIntentTests.swift`, `Tests/SkiVideoViewerTests/ZoomWiringTests.swift`, `Tests/SkiVideoViewerTests/ViewerLayoutMeasurementTests.swift`

**Interfaces:**
- Consumes: `VideoZoom` (1), `SinglePlayerView(player:zoom:)` (2), `ZoomControl` (3).
- Produces: `ViewerModel.zoom: VideoZoom` (published, `public private(set)`), `public func setZoomScale(_: Double)`, `public func panZoom(by: CGSize, in: CGSize)`, `public func resetZoom()`.

- [ ] **Step 1: Write the failing model tests**

Add to `Tests/SkiVideoCoreTests/ViewerModelIntentTests.swift`:

```swift
    // MARK: - Zoom

    func testTheViewerStartsUnzoomed() throws {
        let (model, _, _) = try makeModel()

        XCTAssertEqual(model.zoom, VideoZoom())
        XCTAssertFalse(model.zoom.isZoomed)
    }

    func testSettingTheZoomScaleReachesTheModel() throws {
        let (model, _, _) = try makeModel()

        model.setZoomScale(2.5)

        XCTAssertEqual(model.zoom.scale, 2.5, accuracy: 0.0001)
    }

    /// Zoom persists across clips: comparing several runs of one drill at a
    /// fixed magnification is the point of the control.
    func testZoomSurvivesAClipChange() throws {
        let (model, _, _) = try makeModel()
        model.setZoomScale(3)

        model.changeVideo(by: 1)

        XCTAssertEqual(model.zoom.scale, 3, accuracy: 0.0001)
    }

    /// It does not survive a new library, where a pan into one clip's corner
    /// means nothing about another's.
    func testOpeningADirectoryResetsTheZoom() throws {
        let (model, _, _) = try makeModel()
        model.setZoomScale(3)
        model.panZoom(by: CGSize(width: -100, height: 0), in: CGSize(width: 800, height: 450))

        model.openDirectory(try makeLibrary(athletes: ["Other"]))

        XCTAssertEqual(model.zoom, VideoZoom())
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ViewerModelIntentTests`
Expected: FAIL to compile — `value of type 'ViewerModel' has no member 'zoom'`.

- [ ] **Step 3: Implement the model**

In `Sources/SkiVideoCore/ViewerModel.swift`, beside the other published state:

```swift
    /// How far into the current clip the operator has zoomed.
    ///
    /// Kept across clip and athlete changes — watching several runs of one
    /// drill at a fixed magnification is what the control is for — and reset in
    /// `openDirectory`/`connectGoogleDrive`, where a pan into one library's
    /// corner says nothing about another's.
    @Published public private(set) var zoom = VideoZoom()
```

and the three mutators:

```swift
    public func setZoomScale(_ scale: Double) {
        zoom.setScale(scale)
    }

    public func panZoom(by translation: CGSize, in paneSize: CGSize) {
        zoom.pan(by: translation, in: paneSize)
    }

    public func resetZoom() {
        zoom.reset()
    }
```

Add `zoom.reset()` to `openDirectory` and to `connectGoogleDrive`'s success path, beside the existing `athleteQuery = ""`-style resets.

- [ ] **Step 4: Run the model tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ViewerModelIntentTests`
Expected: PASS.

- [ ] **Step 5: Write the failing view test**

Add to `Tests/SkiVideoViewerTests/ZoomWiringTests.swift`:

```swift
    // MARK: - The viewer

    func testDraggingTheZoomSliderReachesTheViewerModel() throws {
        let model = try Self.makeViewerModel()
        model.setZoomScale(2)

        let host = NSHostingView(rootView: ViewerControlBar(model: model).frame(width: 900, height: 200))
        host.layoutSubtreeIfNeeded()

        let sliders = Self.sliders(in: host)
        XCTAssertEqual(sliders.count, 1, "precondition: the bar carries exactly one slider")
        sliders[0].doubleValue = 3.5
        sliders[0].sendAction(sliders[0].action, to: sliders[0].target)

        XCTAssertEqual(
            model.zoom.scale, 3.5, accuracy: 0.0001,
            "the real slider must reach the model, not merely compile against it"
        )
    }

    private static func sliders(in view: NSView) -> [NSSlider] {
        var found: [NSSlider] = []
        func walk(_ view: NSView) {
            if let slider = view as? NSSlider { found.append(slider) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found
    }
```

Add a `makeViewerModel()` helper to the file, following `ViewerControlsWiringTests`' pattern: a temporary directory with one athlete folder holding `run1.mp4`, then `ViewerModel(input: AppKitInputSource(), folderPicker: AppKitFolderPicker(), oauthPresenter: StubOAuthPresenter())` and `openDirectory`. `StubOAuthPresenter` is internal in `Tests/SkiVideoViewerTests/AppKitOAuthPresenterTests.swift:10` and is already reused this way by `AppKitInputToModelTests.swift:61` — use it, do not write a second stub.

Note the fixture only needs to exist, not decode: `VideoLibrary.scan` inspects file extensions, and nothing in this test touches playback. A zero-byte `run1.mp4` is enough.

- [ ] **Step 6: Wire the views**

`ViewerPane`: swap `NativePlayerView(player: model.player)` for `SinglePlayerView(player: model.player, zoom: model.zoom)`, wrapped in a `GeometryReader` so the drag knows the pane size:

```swift
        GeometryReader { proxy in
            SinglePlayerView(player: model.player, zoom: model.zoom)
                .contentShape(Rectangle())
                .onTapGesture { model.applyTransport(.playPause) }
                // Only installed while zoomed, so at 1x it cannot swallow
                // anything meant for the tap above.
                .gesture(model.zoom.isZoomed ? panGesture(in: proxy.size) : nil)
        }
```

with

```swift
    /// A drag pans, and each step is relative to the previous one — SwiftUI
    /// reports the translation from where the drag *began*, so feeding it
    /// straight to `panZoom` would re-apply the whole distance on every change
    /// and run away.
    private func panGesture(in paneSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let delta = CGSize(
                    width: value.translation.width - lastDrag.width,
                    height: value.translation.height - lastDrag.height
                )
                lastDrag = value.translation
                model.panZoom(by: delta, in: paneSize)
            }
            .onEnded { _ in lastDrag = .zero }
    }
```

backed by `@State private var lastDrag: CGSize = .zero` on the view. Keep the caption and status-chip overlays as they are.

`ViewerControlBar`: add the control to the single-row `HStack` between `transport` and the `Spacer`, and to the wrapped layout's second row:

```swift
    private var zoomControl: some View {
        ZoomControl(
            zoom: model.zoom,
            isEnabled: model.currentPlaybackURL != nil,
            onScale: { model.setZoomScale($0) },
            onReset: { model.resetZoom() }
        )
        .frame(maxWidth: 220)
    }
```

Delete both `NativePlayerView.swift` files and confirm nothing references them:
`grep -rn "NativePlayerView" --include='*.swift' Sources Tests` must come back empty.

- [ ] **Step 7: Re-measure the viewer bar**

Adding a control moves the bar's ideal width. `ViewerLayoutMeasurementTests` records **557.0pt** as a measured constant and its own doc says to re-measure rather than adjust a control to preserve the number.

Binary-search the new ideal width with that file's `barHeight(model:width:)` harness to 0.05pt, update `idealWidth`, and update the doc comment with what you measured and why it moved. If the new ideal exceeds 744pt (the narrower iPad portrait width), the bar is now always wrapped on iPad — report that rather than working around it; it is a design decision, not a test failure.

- [ ] **Step 8: Run the suite and commit**

```bash
swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
git add Sources/SkiVideoCore/ViewerModel.swift Sources/SkiVideoViewer/Shared/ViewerPane.swift Sources/SkiVideoViewer/Shared/ViewerControlBar.swift Tests/SkiVideoCoreTests/ViewerModelIntentTests.swift Tests/SkiVideoViewerTests/ZoomWiringTests.swift Tests/SkiVideoViewerTests/ViewerLayoutMeasurementTests.swift
git rm Sources/SkiVideoViewer/macOS/NativePlayerView.swift Sources/SkiVideoViewer/iOS/NativePlayerView.swift
git commit -m "Zoom and pan the viewer, on the shared player view

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: The comparison window zooms, per side

**Files:**
- Modify: `Sources/SkiVideoCore/ComparisonModel.swift`
- Modify: `Sources/SkiVideoViewer/Shared/ComparisonPane.swift`
- Test: `Tests/SkiVideoCoreTests/ComparisonModelTests.swift`, `Tests/SkiVideoViewerTests/ZoomWiringTests.swift`

**Interfaces:**
- Consumes: `VideoZoom` (1), `SinglePlayerView(player:zoom:)` (2), `ZoomControl` (3).
- Produces: `ComparisonModel.leftZoom` / `rightZoom` (published, `public private(set)`), `public func zoom(for: ComparisonSide) -> VideoZoom`, `public func setZoomScale(_: Double, side: ComparisonSide)`, `public func panZoom(by: CGSize, in: CGSize, side: ComparisonSide)`, `public func resetZoom(side: ComparisonSide)`. Task 6 reads `zoom(for: .left)`.

- [ ] **Step 1: Write the failing model tests**

Add to `Tests/SkiVideoCoreTests/ComparisonModelTests.swift`:

```swift
    // MARK: - Zoom

    func testEachSideZoomsIndependently() throws {
        let model = try makeAlignedModel()
        defer { model.close() }

        model.setZoomScale(2.5, side: .right)

        XCTAssertEqual(model.zoom(for: .right).scale, 2.5, accuracy: 0.0001)
        XCTAssertEqual(
            model.zoom(for: .left).scale, 1, accuracy: 0.0001,
            "two runs shot from different distances is the whole reason zoom is per side"
        )
    }

    func testPanningOneSideLeavesTheOtherCentred() throws {
        let model = try makeAlignedModel()
        defer { model.close() }
        model.setZoomScale(2, side: .left)

        model.panZoom(by: CGSize(width: -100, height: 0), in: CGSize(width: 800, height: 450), side: .left)

        XCTAssertGreaterThan(model.zoom(for: .left).center.x, 0.5)
        XCTAssertEqual(model.zoom(for: .right).center.x, 0.5, accuracy: 0.0001)
    }

    func testResettingOneSideLeavesTheOther() throws {
        let model = try makeAlignedModel()
        defer { model.close() }
        model.setZoomScale(3, side: .left)
        model.setZoomScale(2, side: .right)

        model.resetZoom(side: .left)

        XCTAssertEqual(model.zoom(for: .left), VideoZoom())
        XCTAssertEqual(model.zoom(for: .right).scale, 2, accuracy: 0.0001)
    }

    /// Zoom is a view setting, not an alignment one: it must not disturb the
    /// sync points or drop the pair out of sync.
    func testZoomingDoesNotTouchTheSync() throws {
        let model = try makeSyncedModel()
        defer { model.close() }
        let points = model.syncPoints

        model.setZoomScale(3, side: .left)

        XCTAssertTrue(model.isSynced)
        XCTAssertEqual(model.syncPoints?.left, points?.left)
        XCTAssertEqual(model.syncPoints?.right, points?.right)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ComparisonModelTests`
Expected: FAIL to compile — no `zoom(for:)`.

- [ ] **Step 3: Implement the model**

In `Sources/SkiVideoCore/ComparisonModel.swift`:

```swift
    /// Per side, because the two clips are often shot from different distances
    /// and framing them to match is exactly what the operator needs before the
    /// comparison means anything. The overlay layout is the exception — see
    /// `ComparisonVideos`, which gives the stack the left side's zoom.
    @Published public private(set) var leftZoom = VideoZoom()
    @Published public private(set) var rightZoom = VideoZoom()

    public func zoom(for side: ComparisonSide) -> VideoZoom {
        side == .left ? leftZoom : rightZoom
    }

    public func setZoomScale(_ scale: Double, side: ComparisonSide) {
        mutateZoom(side) { $0.setScale(scale) }
    }

    public func panZoom(by translation: CGSize, in paneSize: CGSize, side: ComparisonSide) {
        mutateZoom(side) { $0.pan(by: translation, in: paneSize) }
    }

    public func resetZoom(side: ComparisonSide) {
        mutateZoom(side) { $0.reset() }
    }

    /// No `noteTouched` here, deliberately. That records which side a `both`
    /// demotion should land on, and it must only follow calls that express a
    /// preference about *playback*. Zoom is a view setting: zooming the right
    /// pane to read a boot buckle says nothing about which clip the transport
    /// should fall back to.
    private func mutateZoom(_ side: ComparisonSide, _ change: (inout VideoZoom) -> Void) {
        switch side {
        case .left: change(&leftZoom)
        case .right: change(&rightZoom)
        }
    }
```

- [ ] **Step 4: Run the model tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ComparisonModelTests`
Expected: PASS.

- [ ] **Step 5: Write the failing pane test**

Add to `Tests/SkiVideoViewerTests/ZoomWiringTests.swift`:

```swift
    // MARK: - The comparison panes

    /// Mutation-check for this test: building both panes with `side: .left`
    /// must make it fail. Without that, a pane wired to the wrong side is
    /// invisible — the two panes are otherwise identical.
    func testEachComparisonPaneDrivesItsOwnSide() throws {
        let model = ComparisonModel()
        defer { model.close() }
        model.setZoomScale(2, side: .left)

        let host = NSHostingView(
            rootView: ComparisonPane(model: model, side: .right).frame(width: 600, height: 400)
        )
        host.layoutSubtreeIfNeeded()

        let sliders = Self.sliders(in: host)
        XCTAssertEqual(sliders.count, 1, "precondition: one slider per pane")
        sliders[0].doubleValue = 3
        sliders[0].sendAction(sliders[0].action, to: sliders[0].target)

        XCTAssertEqual(model.zoom(for: .right).scale, 3, accuracy: 0.0001, "the right pane must move the right side")
        XCTAssertEqual(model.zoom(for: .left).scale, 2, accuracy: 0.0001, "and must not touch the left")
    }
```

- [ ] **Step 6: Wire the pane**

In `ComparisonPane`, pass the side's zoom to the player and add the chip and the drag:

```swift
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                Color.black
                SinglePlayerView(
                    player: side == .left ? model.leftPlayer : model.rightPlayer,
                    zoom: model.zoom(for: side)
                )
                .gesture(model.zoom(for: side).isZoomed ? panGesture(in: proxy.size) : nil)

                if isLoaded {
                    loadedName
                } else {
                    emptyChooser
                }
            }
            .overlay(alignment: .bottomTrailing) { zoomChip }
        }
    }
```

`zoomChip` is `ZoomControl` in a material capsule with 8pt padding, matching `loadedName`'s placement rule — bottom-*trailing* so it clears the clip-name chip at bottom-leading. Disable it when the side has no clip (`ClipSourceMenu.isLoaded(model, side)`). The pan gesture mirrors Task 4's, with the same `@State private var lastDrag` and the same reason in its comment.

- [ ] **Step 7: Run the tests, and run the mutation check**

Run: `swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ZoomWiringTests`
Expected: PASS.

Then change `ComparisonPane`'s two `side` uses to a literal `.left`, re-run, and confirm `testEachComparisonPaneDrivesItsOwnSide` FAILS. Restore. Report both runs.

- [ ] **Step 8: Run the suite and commit**

```bash
swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
git add Sources/SkiVideoCore/ComparisonModel.swift Sources/SkiVideoViewer/Shared/ComparisonPane.swift Tests/SkiVideoCoreTests/ComparisonModelTests.swift Tests/SkiVideoViewerTests/ZoomWiringTests.swift
git commit -m "Zoom each comparison pane on its own

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: The overlay layout zooms as one

**Files:**
- Modify: `Sources/SkiVideoViewer/Shared/OverlayPlayerStack.swift`
- Modify: `Sources/SkiVideoViewer/Shared/ComparisonView.swift`
- Test: `Tests/SkiVideoViewerTests/ZoomWiringTests.swift`

**Interfaces:**
- Consumes: `VideoZoom` (1), `SinglePlayerView(player:zoom:)` (2), `ZoomControl` (3), `ComparisonModel.zoom(for:)` (5).
- Produces: `OverlayPlayerStack(bottomPlayer:topPlayer:topOpacity:blend:translation:zoom:)` with `zoom` defaulting to `VideoZoom()`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/SkiVideoViewerTests/ZoomWiringTests.swift`:

```swift
    // MARK: - The overlay layout

    /// Both clips get the *same* zoom, and the alignment translation survives
    /// it. Per-side zoom cannot work here: the translation is expressed in
    /// normalised frame widths and both clips are masked to the region they
    /// share, so two independent scales would invalidate the registration and
    /// the mask together.
    func testTheOverlayStackZoomsBothClipsTogether() throws {
        let model = ComparisonModel()
        defer { model.close() }
        model.layout = .overlay
        model.setZoomScale(2, side: .left)
        model.setZoomScale(4, side: .right)

        let host = NSHostingView(
            rootView: ComparisonVideos(model: model, translation: CGVector(dx: 0.1, dy: 0))
                .frame(width: 800, height: 450)
        )
        host.layoutSubtreeIfNeeded()

        let hosts = Self.playerHosts(in: host)
        XCTAssertEqual(hosts.count, 2, "precondition: the stack draws two players")
        XCTAssertEqual(
            hosts[0].playerLayerFrame.width, hosts[1].playerLayerFrame.width, accuracy: 0.5,
            "the stack must magnify the aligned pair as a unit, not per side"
        )
        XCTAssertEqual(
            hosts[0].playerLayerFrame.width, 1600, accuracy: 0.5,
            "and at the left side's scale, which is the one the stack follows"
        )
    }

    private static func playerHosts(in view: NSView) -> [PlayerLayerHostView] {
        var found: [PlayerLayerHostView] = []
        func walk(_ view: NSView) {
            if let host = view as? PlayerLayerHostView { found.append(host) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ZoomWiringTests`
Expected: FAIL — both layers are the unzoomed pane width.

- [ ] **Step 3: Implement**

`OverlayPlayerStack` gains

```swift
    /// One zoom for the pair, not one each.
    ///
    /// `translation` is in normalised frame widths and both clips are masked to
    /// the region they share, so magnifying the two by different amounts would
    /// invalidate the registration and the mask at once. Scaling them together
    /// leaves both correct: the translation stays normalised, and the shared
    /// region scales with everything else.
    ///
    /// Defaulted so the pure-renderer call sites in the tests stay honest about
    /// not passing one.
    var zoom: VideoZoom = VideoZoom()
```

and passes it to both `SinglePlayerView`s. Leave `sharedRect`, `offset` and the masks untouched.

In `ComparisonView`'s `ComparisonVideos`, the overlay branch passes `zoom: model.zoom(for: .left)`, and `overlayChoosers` gains a `ZoomControl` driving `.left` — placed in the same `HStack`, after the two clip choosers.

- [ ] **Step 4: Run the tests**

Run: `swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ZoomWiringTests`
Expected: PASS.

- [ ] **Step 5: Run the suite and commit**

```bash
swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
git add Sources/SkiVideoViewer/Shared/OverlayPlayerStack.swift Sources/SkiVideoViewer/Shared/ComparisonView.swift Tests/SkiVideoViewerTests/ZoomWiringTests.swift
git commit -m "Zoom the overlay pair as one

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Double-click to reset, and the gesture measurement

The spec's second risk, settled rather than assumed. Split from Task 4 because it is the one piece that may be *removed* on the evidence, and a reviewer should be able to reject it without rejecting zoom.

**Files:**
- Modify: `Sources/SkiVideoViewer/Shared/ViewerPane.swift`, `Sources/SkiVideoViewer/Shared/ComparisonPane.swift`

- [ ] **Step 1: Add the double-click**

On both panes, before the existing single-tap:

```swift
                .onTapGesture(count: 2) { model.resetZoom() }
```

(the comparison pane's takes `side: side`). SwiftUI requires the higher count first, or the single tap consumes both.

- [ ] **Step 2: Measure the delay it introduces**

The viewer's single tap is play/pause. Adding a double-tap makes SwiftUI wait to see whether a second tap is coming.

Write a throwaway harness that dispatches a synthetic single click at `ViewerPane` and times how long until `model.player.rate` changes, with and without the `count: 2` gesture present. Record both numbers.

- [ ] **Step 3: Decide on the evidence**

If the delay is perceptible (>150 ms), **remove the double-click from `ViewerPane`** and keep it only on `ComparisonPane`, which has no single-tap gesture to arbitrate against. Record the measurement in the code comment either way — this is exactly the kind of decision that gets undone later by someone who assumes it was arbitrary.

Delete the harness.

- [ ] **Step 4: Run the suite and commit**

```bash
swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
git add Sources/SkiVideoViewer/Shared/ViewerPane.swift Sources/SkiVideoViewer/Shared/ComparisonPane.swift
git commit -m "Reset the zoom with a double-click

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Manual check in the real app

Unit tests cannot see picture quality, gesture feel, or whether a control lands where the hand expects it.

**Files:** none unless a defect turns up.

- [ ] **Step 1: Build and launch**

```bash
./run.sh
```

- [ ] **Step 2: Check the viewer**

| Do | Expect |
| --- | --- |
| Open a clip, look at 1× | the whole frame, letterboxed — black bars where the aspect differs. **This is the visible change**; confirm it reads as right |
| Drag the zoom slider to 4× | the picture magnifies smoothly, stays sharp enough to judge technique |
| Drag on the video | the picture follows the finger; it stops at each edge with no black gap |
| Zoom back to 1× while panned | the picture re-centres rather than hanging off one side |
| Click the level readout | back to 1×, centred |
| Tap the video | play/pause, with no delay you would notice |
| Change clip | the zoom stays |
| Open a different folder | the zoom resets |

- [ ] **Step 3: Check the comparison window**

| Do | Expect |
| --- | --- |
| Load two clips side by side | a zoom chip on each pane, bottom-right |
| Zoom the left only | only the left magnifies |
| Frame a far-shot run to match a close one | the two athletes read at the same size |
| Sync the pair, then zoom one side | still synced; the transport still moves both |
| Switch to Overlay while both sides are zoomed differently | one chip, both clips at the left's zoom, still aligned |
| Zoom the overlay to 3× | both clips magnify together and stay registered |

- [ ] **Step 4: Report**

Write up what happened, especially the 1× change and the sharpness at 4×. Nothing is committed here unless a defect turns up and is fixed.

---

## Self-Review

**Spec coverage.** Behaviour table → Tasks 4, 5, 6, 7. `1× = whole frame` → Task 4 (viewer moves to `SinglePlayerView`, `NativePlayerView` deleted). `VideoZoom`, the invariant, drag semantics, `layerFrame` → Task 1. Rendering path and the `.scaleEffect` rejection → Task 2. State and persistence → Tasks 4, 5. Overlay uses the left's zoom → Task 6. Controls: viewer bar → Task 4, pane chips → Task 5, overlay chip → Task 6. Gestures → Tasks 4, 5, 7. Testing section → the test steps throughout, plus the bar re-measurement in Task 4 Step 7. Risk 1 (sharpness) → Task 2 Step 5. Risk 2 (double-tap delay) → Task 7. Risk 3 (`sharedRect` under zoom) → Task 6 Step 1.

**One thing the spec named that this plan handles differently:** the spec's testing section asks for an overlay test "with a non-zero translation at 2× confirming both clips stay masked to the same rect". Task 6's test passes a non-zero translation and asserts both layers get the same frame, which is the reachable half — the masks are SwiftUI `.mask` modifiers with no AppKit view to inspect, and this repo's `ClipChooserTests` records that `ImageRenderer` cannot draw `NSViewRepresentable` content, so a pixel assertion on a masked `AVPlayerLayer` would be vacuous. Task 8's manual check covers the visual half.

**Names checked across tasks:** `VideoZoom.setScale/pan/reset/layerFrame/isZoomed/range`, `SinglePlayerView(player:zoom:)`, `PlayerLayerHostView.apply/playerLayerFrame`, `ZoomControl(zoom:isEnabled:onScale:onReset:)` and `.label(for:)`, `ViewerModel.zoom/setZoomScale/panZoom/resetZoom`, `ComparisonModel.zoom(for:)/setZoomScale(_:side:)/panZoom(by:in:side:)/resetZoom(side:)`, `OverlayPlayerStack.zoom`. Consistent as used.
