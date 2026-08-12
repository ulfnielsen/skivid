import AppKit
import AVFoundation
import CoreGraphics
import SwiftUI
import XCTest
@testable import SkiVideoCore
@testable import SkiVideoViewer

/// That the zoom an operator sets actually reaches the layer that draws the
/// video, and that the layer is re-placed when the clip's own size arrives.
///
/// `VideoZoomTests` proves the arithmetic; this file proves the wiring. Neither
/// substitutes for the other: `layerFrame` can be perfect while the view hands
/// it the wrong pane size, the wrong video size, or never asks again once the
/// asset has loaded.
@MainActor
final class ZoomWiringTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // NSHostingView lays nothing out until the shared application exists.
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    func testTheHostViewGivesItsLayerTheZoomedFrame() {
        let pane = CGSize(width: 800, height: 450)
        let view = PlayerLayerHostView()
        view.frame = NSRect(origin: .zero, size: pane)
        var zoom = VideoZoom()
        // No player, so no `presentationSize`: `layerFrame` falls back to
        // treating the pane as the fitted rect, and 2x is twice the pane.
        zoom.setScale(2, in: pane, videoSize: .zero)

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
        let pane = CGSize(width: 800, height: 450)
        let view = PlayerLayerHostView()
        view.frame = NSRect(origin: .zero, size: pane)
        view.apply(VideoZoom())
        view.layout()
        XCTAssertEqual(view.playerLayerFrame.width, 800, accuracy: 0.5, "precondition: 1x is the pane")

        var zoom = VideoZoom()
        zoom.setScale(4, in: pane, videoSize: .zero)
        view.apply(zoom)

        XCTAssertEqual(
            view.playerLayerFrame.width, 3200, accuracy: 0.5,
            "apply must re-place the layer, not wait for the next layout pass"
        )
    }

    /// The defect this whole observation exists to prevent: `presentationSize`
    /// is `.zero` until the asset loads, and `layerFrame` deliberately falls
    /// back to the pane's own rect for that window. A layer placed once at
    /// `makeNSView` time would therefore keep the pre-load geometry forever —
    /// the zoom silently wrong for every clip, on the wrong aspect, until some
    /// unrelated resize happened to run `layout` again.
    ///
    /// A 4:3 fixture in a 16:9 pane is what makes the two answers differ: at 2x
    /// the pre-load fallback is 1600x900 (twice the pane) and the loaded answer
    /// is 1200x900 (twice the letterboxed picture). A 16:9 fixture would give
    /// the same number either way and prove nothing.
    func testTheLayerIsRePlacedWhenThePresentationSizeArrives() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = try makeRealVideoFile(in: root, name: "clip.mov", seconds: 1, width: 320, height: 240)

        let pane = CGSize(width: 800, height: 450)
        let view = PlayerLayerHostView()
        view.frame = NSRect(origin: .zero, size: pane)
        let player = AVPlayer()
        view.attach(player)
        var zoom = VideoZoom()
        zoom.setScale(2, in: pane, videoSize: .zero)
        view.apply(zoom)
        view.layout()
        XCTAssertEqual(
            view.playerLayerFrame.width, 1600, accuracy: 0.5,
            "precondition: with no item loaded the fallback is twice the pane"
        )

        player.replaceCurrentItem(with: AVPlayerItem(url: url))

        // The size arrives asynchronously, like every other "after the item"
        // value in this project; poll a bounded run loop for it rather than
        // asserting immediately. Nothing else calls `layout` here, so without
        // the observation this never leaves 1600.
        let deadline = Date().addingTimeInterval(10)
        while view.playerLayerFrame.width > 1400, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(
            view.playerLayerFrame.width, 1200, accuracy: 0.5,
            "the layer must be re-placed against the clip's real aspect once its size is known"
        )
        XCTAssertEqual(view.playerLayerFrame.height, 900, accuracy: 0.5)

        // Let the item settle before the second half. `presentationSize` posts
        // more than once while an asset finishes loading, and a host attached
        // inside that window gets re-placed by a *change* — which passes
        // whether or not `.initial` is there, and is not the case being
        // tested.
        //
        // **What this test does and does not pin, mutation-checked.** Of the
        // two `.initial` options in `observeVideoSize`, only one is load-bearing
        // *here*:
        //
        //     remove the presentationSize observation entirely -> FAILS, 1600
        //     drop .initial from \.currentItem                 -> FAILS, 1600
        //     drop .initial from \.presentationSize            -> PASSES
        //
        // So something does re-post `presentationSize` when this second
        // `AVPlayerLayer` attaches to the settled player, and the inner
        // `.initial` is not what places the layer in this test. An earlier
        // probe concluded the opposite — that a settled item posts nothing for
        // a late layer — and the mutation above is the better evidence, so the
        // claim was withdrawn rather than restated.
        //
        // Both options stay. The reason is the difference between this test and
        // production: here the player already has an `AVPlayerLayer` and this is
        // its *second*, whereas the models own a long-lived player and the view
        // that attaches is the *first* layer on it. The inner `.initial` may
        // well be load-bearing in that arrangement while being invisible to
        // this one, and no test in this suite pins it either way.
        XCTAssertNotEqual(
            player.currentItem?.presentationSize, .zero,
            "precondition: the size is known before the settle"
        )
        RunLoop.main.run(until: Date().addingTimeInterval(2))

        // The *other* order, which is the one production actually runs: the
        // models own long-lived players and load clips into them, and the
        // SwiftUI view is built — and rebuilt on every navigation — after
        // that. `attach` then arrives at an item whose size is already real, so
        // the outer observation has no `currentItem` change left to wait for
        // and only its `.initial` delivery can start the chain — which is the
        // half the mutations above do pin. Note there is no `layout()` call
        // after `attach` here: that would place the layer correctly on its own
        // and hide exactly the defect being tested.
        let alreadyLoaded = PlayerLayerHostView()
        alreadyLoaded.frame = NSRect(origin: .zero, size: pane)
        alreadyLoaded.apply(zoom)
        XCTAssertEqual(
            alreadyLoaded.playerLayerFrame.width, 1600, accuracy: 0.5,
            "precondition: this host has no player yet either"
        )

        alreadyLoaded.attach(player)

        let initialDeadline = Date().addingTimeInterval(10)
        while alreadyLoaded.playerLayerFrame.width > 1400, Date() < initialDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(
            alreadyLoaded.playerLayerFrame.width, 1200, accuracy: 0.5,
            "a view attached to an already-loaded player must place itself from the observations' initial delivery"
        )
    }

    /// **Which end of the clip a pan reveals**, which the two platforms read
    /// out of `layerFrame`'s single `origin.y` in opposite directions unless
    /// the AppKit host is flipped. `layerFrame` is written top-down —
    /// `center.y == 0` is the picture's top — because that is what `pan`'s
    /// negation means once SwiftUI's positive-downward `DragGesture` feeds it.
    /// A `UIView`'s layer reads it that way already; an unflipped
    /// layer-backed `NSView` reads it from the bottom.
    ///
    /// Nothing on screen shows the difference at `center.y == 0.5`, where the
    /// expression is symmetric, which is why this is pinned by a test rather
    /// than left to be found in Task 4 as a gesture that scrolls the wrong way
    /// on one platform and debugged in the wrong file.
    ///
    /// **Asserted on rendered pixels, not on `isFlipped` itself.** Reading the
    /// flag back would be a tautology over the one line that implements it: it
    /// would still pass if `layerFrame`'s convention were later inverted, which
    /// is the change that would actually break this contract. So this places a
    /// marker sublayer at the *top* of the rect `layerFrame` returns and asserts
    /// that it renders at the top of the view.
    ///
    /// **A marker rather than the video.** `cacheDisplay` gives black for an
    /// `AVPlayerLayer`'s content — as `attachedPlayer`'s comment says — but that
    /// is a fact about video, not about layer *placement*, and placement is the
    /// whole of this contract. A plain `CALayer` with a background colour
    /// renders fine through `cacheDisplay` on a windowless, screenless view,
    /// which is what makes this a standing headless guard rather than one that
    /// skips wherever it cannot reach a screen. Use `cacheDisplay` and not
    /// `CALayer.render(in:)`: on the same view with the same marker, the two
    /// routes were measured side by side and only `cacheDisplay` discriminates.
    /// `render(in:)` reads top 0 / bottom 255 — the marker at the bottom —
    /// whether the view is flipped or not. Why it ignores the flip was not
    /// established; only that it does, which is enough to rule the route out.
    ///
    /// Measured, and mutation-checked by deleting `isFlipped` — the rect is
    /// identical in both variants, because `VideoZoom` is platform-independent
    /// and it is only the reading of it that differs:
    ///
    /// | `layerFrame` = (-480, 0, 1280, 720), marker = its top 90pt | top third | bottom third |
    /// | ---------------------------------------------------------- | --------- | ------------ |
    /// | `isFlipped = true` (shipping)                               | 255       | 0            |
    /// | flip deleted                                                | 0         | 255          |
    ///
    /// `testPanningDownRevealsTheTopOfThePicture` is the same contract proved
    /// against real video content on a real screen; it skips where it cannot
    /// capture, so this one is what guards the geometry on a headless run.
    func testTheHostIsFlippedSoTheSharedRectIsReadTopDown() throws {
        let pane = CGSize(width: 320, height: 180)
        let videoSize = CGSize(width: 640, height: 360)
        var zoom = VideoZoom()
        zoom.setScale(4, in: pane, videoSize: videoSize)
        // Positive height is a downward drag; `pan` negates it. This is
        // `center.y`'s legal minimum at 4x — the picture pushed as far down as
        // it goes, so the picture's top edge sits exactly on the pane's top and
        // `layerFrame`'s `origin.y` comes back 0.
        zoom.pan(by: CGSize(width: 0, height: 270), in: pane, videoSize: videoSize)
        XCTAssertEqual(zoom.center.y, 0.125, accuracy: 0.001, "precondition: panned to the bound")

        let rect = zoom.layerFrame(in: pane, videoSize: videoSize)
        XCTAssertEqual(rect.minY, 0, accuracy: 0.5, "precondition: the picture's top is at the pane's top")

        let view = PlayerLayerHostView(frame: NSRect(origin: .zero, size: pane))
        // The top eighth of the picture, in the same coordinates the host places
        // its player layer in. An eighth rather than the whole rect because the
        // whole rect is four times the pane and covers it in either convention,
        // which would discriminate nothing; 90pt is exactly half the pane, so
        // the two conventions put it in opposite halves.
        let marker = CALayer()
        marker.frame = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 8)
        marker.backgroundColor = NSColor.white.cgColor
        try XCTUnwrap(view.layer).addSublayer(marker)

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let (top, bottom) = try bands(of: try XCTUnwrap(rep.cgImage))

        XCTAssertGreaterThan(
            top, 200,
            "the top of the zoomed rect must render at the top of the view; an unflipped host puts it at the bottom"
        )
        XCTAssertLessThan(bottom, 40, "the marker must not reach the bottom third")
    }

    /// The same contract as above, but proved on the screen rather than by the
    /// flag that implements it: a clip whose top quarter is white, zoomed 4x
    /// and panned all the way down, must fill the pane with white — the
    /// picture's *top*. Unflipped it fills with black, the picture's bottom.
    /// Both were measured before `isFlipped` was added, and the inversion is
    /// clean in both directions.
    ///
    /// This is the only test in the project that asserts on what an
    /// `AVPlayerLayer` actually draws. It needs a real window on a real
    /// screen, so it establishes that the environment can render and capture
    /// one *first*, using the unzoomed pane as its own control, and skips when
    /// it cannot — a machine that cannot capture must not fail the suite, and
    /// an all-black capture is indistinguishable from the failure being
    /// tested.
    func testPanningDownRevealsTheTopOfThePicture() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = try makeRealVideoFile(
            in: root, name: "banded.mov", seconds: 2, width: 640, height: 360, whiteTopQuarter: true
        )

        let pane = CGSize(width: 320, height: 180)
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: 200, y: 200), size: pane),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isOpaque = true
        window.backgroundColor = .black
        let view = PlayerLayerHostView(frame: NSRect(origin: .zero, size: pane))
        window.contentView = view
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil) }

        let player = AVPlayer(url: url)
        view.attach(player)
        player.play()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        guard let unzoomed = capture(window),
              let (top, bottom) = try? bands(of: unzoomed),
              top > 150, bottom < 40
        else {
            throw XCTSkip("this environment cannot render or capture an on-screen AVPlayerLayer")
        }

        var zoom = VideoZoom()
        zoom.setScale(4, in: pane, videoSize: CGSize(width: 640, height: 360))
        // Positive height is a downward drag. `pan` negates it, so this is
        // `center.y`'s legal minimum for 4x — the picture pushed as far down
        // as it goes.
        zoom.pan(by: CGSize(width: 0, height: 270), in: pane, videoSize: CGSize(width: 640, height: 360))
        XCTAssertEqual(zoom.center.y, 0.125, accuracy: 0.001, "precondition: panned to the bound")
        view.apply(zoom)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))

        let zoomed = try XCTUnwrap(capture(window), "no capture at 4x")
        let (zoomedTop, zoomedBottom) = try bands(of: zoomed)
        XCTAssertGreaterThan(
            zoomedTop, 200,
            "dragging down must reveal the picture's white top band; an unflipped host shows its black bottom"
        )
        XCTAssertGreaterThan(zoomedBottom, 200, "the whole pane is inside the white band at 4x")
    }

    /// The other half of the wiring: that `SinglePlayerView` hands the zoom it
    /// is given down to the host view at all. `apply` can be perfect while the
    /// representable never calls it — Tasks 3-6 all construct this view with a
    /// zoom and would silently get 1x.
    func testTheSwiftUIViewHandsItsZoomToTheHost() throws {
        let pane = CGSize(width: 800, height: 450)
        var zoom = VideoZoom()
        zoom.setScale(3, in: pane, videoSize: .zero)

        let host = NSHostingView(
            rootView: SinglePlayerView(player: AVPlayer(), zoom: zoom)
                .frame(width: pane.width, height: pane.height)
        )
        host.layoutSubtreeIfNeeded()

        let layerHost = try XCTUnwrap(playerLayerHost(in: host), "expected SinglePlayerView to render a PlayerLayerHostView")
        XCTAssertEqual(layerHost.appliedZoom, zoom, "the view's zoom must reach the layer host")
        XCTAssertEqual(
            layerHost.playerLayerFrame.width, 2400, accuracy: 0.5,
            "and must actually be applied to the layer"
        )
    }

    /// **Not a wiring test** — it passes with `apply` deleted from both
    /// `makeNSView` and `updateNSView`, because the host's own initial `zoom`
    /// is the default too. `testTheSwiftUIViewHandsItsZoomToTheHost` above is
    /// what kills that mutant, and only it.
    ///
    /// What this pins instead is the four call sites that predate zoom
    /// (`ComparisonPane`, both in `OverlayPlayerStack`, and `ClipChooserTests`)
    /// still compiling without a zoom *and still drawing exactly what they
    /// drew before it existed*: the layer filling the pane, which is what
    /// `playerLayer.frame = bounds` did. A change to `VideoZoom()`'s default
    /// scale, or to `layerFrame`'s pre-load fallback, would move every screen
    /// in the app and this is the only test that would notice.
    func testAViewBuiltWithoutAZoomIsUnzoomed() throws {
        let host = NSHostingView(
            rootView: SinglePlayerView(player: AVPlayer()).frame(width: 800, height: 450)
        )
        host.layoutSubtreeIfNeeded()

        let layerHost = try XCTUnwrap(playerLayerHost(in: host))
        XCTAssertFalse(layerHost.appliedZoom.isZoomed)
        XCTAssertEqual(layerHost.playerLayerFrame.width, 800, accuracy: 0.5)
    }

    // MARK: - The control

    func testTheZoomLabelReadsAsAMultiplier() {
        XCTAssertEqual(ZoomControl.label(for: 1), "1.0×")
        XCTAssertEqual(ZoomControl.label(for: 2.5), "2.5×")
        XCTAssertEqual(ZoomControl.label(for: 4), "4.0×")
    }

    func testTheMinusButtonStepsDownAndThePlusButtonStepsUp() {
        var requested: [Double] = []
        var zoom = VideoZoom()
        zoom.setScale(2, in: CGSize(width: 400, height: 60), videoSize: .zero)
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
        zoom.setScale(3, in: CGSize(width: 400, height: 60), videoSize: .zero)
        let control = ZoomControl(zoom: zoom, isEnabled: true, onScale: { _ in }, onReset: { didReset = true })

        let host = NSHostingView(rootView: control.frame(width: 400, height: 60))
        host.layoutSubtreeIfNeeded()
        Self.buttons(in: host)[2].performClick(nil)

        XCTAssertTrue(didReset, "the level is the route to 1x that does not depend on gesture arbitration")
    }

    // MARK: - The viewer

    /// The zoom chip's slider must reach the model, not merely compile against
    /// it. `ZoomControl`'s own tests drive a closure; this one drives the real
    /// `NSSlider` that `ViewerPane` renders over the video, through the real
    /// `ViewerModel`.
    ///
    /// The chip is the pane's *only* slider, which is what makes finding it by
    /// type safe here: `TimelineScrubber` is a sibling in `ContentView`, not
    /// part of this view.
    ///
    /// **The hosted `NSSlider` is normalised, not scaled — measured, because
    /// the obvious spelling silently passes the wrong number.** Printing the
    /// slider's own bounds with `ZoomControl`'s `in: VideoZoom.range` in place
    /// gives `minValue 0.0, maxValue 1.0`, and at 2× it reads `0.3333…` —
    /// SwiftUI keeps the range in its own binding and hands AppKit a 0–1
    /// control. So `doubleValue = 3.5` saturates at 1.0 and asks the model for
    /// **4.0**, which is the max and would pass an `isZoomed`-style assertion
    /// while proving nothing about the value. The position is therefore written
    /// in normalised units and converted here.
    func testDraggingTheZoomSliderReachesTheViewerModel() throws {
        let model = try Self.makeViewerModel()
        let pane = CGSize(width: 800, height: 450)
        model.setZoomScale(2, in: pane)

        let host = NSHostingView(
            rootView: ViewerPane(model: model, athleteName: "Idun")
                .frame(width: pane.width, height: pane.height)
        )
        host.layoutSubtreeIfNeeded()

        let sliders = Self.sliders(in: host)
        XCTAssertEqual(sliders.count, 1, "precondition: the pane carries exactly one slider, the zoom chip's")
        XCTAssertEqual(
            sliders[0].maxValue, 1.0, accuracy: 0.0001,
            "precondition: the hosted slider is normalised; a 1...4 slider would make the line below ask for 1.83"
        )
        let target = 3.5
        let span = VideoZoom.range.upperBound - VideoZoom.range.lowerBound
        sliders[0].doubleValue = (target - VideoZoom.range.lowerBound) / span
        sliders[0].sendAction(sliders[0].action, to: sliders[0].target)

        XCTAssertEqual(
            model.zoom.scale, target, accuracy: 0.0001,
            "the real slider must reach the model, not merely compile against it"
        )
    }

    /// **The drag must not run away.** `DragGesture.value.translation` is
    /// measured from where the drag *began*, not since the previous change, so
    /// forwarding it straight to `panZoom` re-applies the whole distance on
    /// every event: a three-step drag of 20pt each would move the picture by
    /// 20 + 40 + 60 = 120pt instead of 60pt, accelerating the further the
    /// operator drags. `ViewerPane` subtracts its `lastDrag` to get a per-change
    /// delta, and this is the number that tells the two apart.
    ///
    /// Measured on this harness at 4× in a 400×300 pane, dragging 60pt left in
    /// three steps (`center.x` starts at 0.5, and `pan` negates, so leftward
    /// drags raise it):
    ///
    /// | | `center.x` |
    /// | --------------------------------- | ------ |
    /// | per-change delta (shipping)       | 0.5375 |
    /// | raw cumulative translation (bug)  | 0.575  |
    ///
    /// Both are inside the legal interval at 4× (`[0.03125, 0.96875]` for this
    /// pane), so the clamp cannot mask the difference — mutation-checked by
    /// deleting the `lastDrag` subtraction, which lands on 0.575.
    ///
    /// Same real-`NSWindow` technique as
    /// `ViewerControlsWiringTests.testTappingTheViewerPaneTogglesPlaybackOnMacOS`;
    /// see that test for why `view.mouseDown(with:)` alone does not reach
    /// SwiftUI's gesture recognition.
    func testDraggingThePanePansByEachStepsDeltaRatherThanTheWholeTranslation() throws {
        let model = try Self.makeViewerModel()
        let pane = CGSize(width: 400, height: 300)
        model.setZoomScale(4, in: pane)
        XCTAssertEqual(model.zoom.center.x, 0.5, accuracy: 0.0001, "precondition: centred")

        let host = NSHostingView(
            rootView: ViewerPane(model: model, athleteName: "Idun")
                .frame(width: pane.width, height: pane.height)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: pane),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        // Horizontal only: AppKit's y axis runs the other way from SwiftUI's,
        // and which end of the clip a vertical drag reveals is already pinned
        // by `testTheHostIsFlippedSoTheSharedRectIsReadTopDown`. This test is
        // about the *delta*, and one axis shows it.
        let start = CGPoint(x: 300, y: 150)
        window.sendEvent(Self.mouseEvent(.leftMouseDown, at: start, windowNumber: window.windowNumber))
        for step in 1...3 {
            let point = CGPoint(x: start.x - CGFloat(step) * 20, y: start.y)
            window.sendEvent(Self.mouseEvent(.leftMouseDragged, at: point, windowNumber: window.windowNumber))
        }
        window.sendEvent(
            Self.mouseEvent(.leftMouseUp, at: CGPoint(x: start.x - 60, y: start.y), windowNumber: window.windowNumber)
        )

        XCTAssertEqual(
            model.zoom.center.x, 0.5375, accuracy: 0.002,
            """
            a 60pt drag at 4x in a 400pt pane must move the centre by \
            60/(400*4) = 0.0375; 0.575 means each change re-applied the whole \
            translation from the drag's start
            """
        )
        XCTAssertEqual(model.zoom.center.y, 0.5, accuracy: 0.002, "a horizontal drag must not move the picture vertically")
    }

    /// **Two clean drags are exactly additive**, which is the control for the
    /// test below and worth pinning on its own: `lastDrag` has to be cleared
    /// between gestures, but it must be cleared *back to rest* rather than left
    /// holding anything, and a chain that drifted would show up here.
    ///
    /// Measured: 20pt left, mouse up, 20pt left again, at 4× in a 400pt pane —
    /// `0.5 + 2 × 20/(400×4) = 0.525`.
    func testTwoCleanDragsAreExactlyAdditive() throws {
        let model = try Self.makeViewerModel()
        let pane = CGSize(width: 400, height: 300)
        model.setZoomScale(4, in: pane)
        let (host, window) = try hostedPane(model: model, pane: pane)
        _ = host

        Self.drag(in: window, from: CGPoint(x: 300, y: 250), by: -20, releasing: true)
        XCTAssertEqual(model.zoom.center.x, 0.5125, accuracy: 0.002, "precondition: the first drag lands where one drag should")

        Self.drag(in: window, from: CGPoint(x: 300, y: 250), by: -20, releasing: true)

        XCTAssertEqual(
            model.zoom.center.x, 0.525, accuracy: 0.002,
            "two clean 20pt drags must total 40pt of pan, not more and not less"
        )
    }

    /// **A drag that is never ended must not poison the next one.**
    ///
    /// `panGesture` is installed only while `model.zoom.isZoomed`, so dropping
    /// to 1× removes the recognizer out from under a live drag and
    /// `DragGesture.onEnded` never runs. On iPadOS that is reachable two ways:
    /// a second finger on the chip's `−` or its level readout while the first
    /// is panning, and any system drag cancellation — an edge swipe to the app
    /// switcher, Slide Over, a notification — which needs no second finger at
    /// all.
    ///
    /// **Measured, and this is what `@GestureState` buys.** A 60pt leftward
    /// drag torn down mid-flight, then a fresh 20pt leftward drag after
    /// re-arming at 4×:
    ///
    /// | | second drag's `center.x` |
    /// | ------------------------------ | ------ |
    /// | `@GestureState` (shipping)     | 0.5125 |
    /// | `@State` + `onEnded` reset     | 0.475  |
    ///
    /// 0.475 is a leftward drag moving the picture 40pt to the *right* on its
    /// first frame — the dead drag's 60pt subtracted from the new 20pt — and it
    /// stays wrong until some drag completes cleanly. Mutation-checked by
    /// putting `@State` and `onEnded` back: this test fails at exactly 0.475
    /// while every other test in the file, including the additive control
    /// above, still passes.
    func testASecondDragAfterTheGestureIsTornDownStartsFromRest() throws {
        let model = try Self.makeViewerModel()
        let pane = CGSize(width: 400, height: 300)
        model.setZoomScale(4, in: pane)
        let (host, window) = try hostedPane(model: model, pane: pane)

        // A 60pt drag with no mouse-up: the gesture is torn down underneath it
        // instead, which is what `onEnded` cannot see.
        Self.drag(in: window, from: CGPoint(x: 300, y: 250), by: -60, releasing: false)
        XCTAssertEqual(model.zoom.center.x, 0.5375, accuracy: 0.002, "precondition: the first drag panned")

        model.resetZoom()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(model.zoom.isZoomed, "precondition: 1x, so the pan gesture is no longer installed")

        model.setZoomScale(4, in: pane)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(model.zoom.center.x, 0.5, accuracy: 0.0001, "precondition: the reset recentred the picture")

        Self.drag(in: window, from: CGPoint(x: 300, y: 250), by: -20, releasing: true)

        XCTAssertEqual(
            model.zoom.center.x, 0.5125, accuracy: 0.002,
            """
            the second drag must move by its own 20pt only; 0.475 means the \
            torn-down drag's 60pt was still being subtracted, sending a leftward \
            drag 40pt to the right
            """
        )
    }

    /// **The chip is dead until a clip is loaded**, matching
    /// `ViewerControlsWiringTests.testADisabledViewerControlBarDoesNotEnableAnyButton`
    /// for the bar. Without this, replacing `isEnabled: model.currentPlaybackURL != nil`
    /// with `isEnabled: true` passes the entire suite — and the failure it lets
    /// through is visible: on an empty library the operator drags the slider,
    /// `setZoomScale` runs against a player with no item, and the level readout
    /// reads 2.5× over a blank pane.
    ///
    /// Asserts the real `NSButton.isEnabled`/`NSSlider.isEnabled`, for the same
    /// reason that file does: they are plain AppKit properties, unlike the
    /// accessibility ones, which are dead in a `swift test` host process.
    ///
    /// **Every control on the chip is covered by state *and* by behaviour**,
    /// which the slider was not when this was first written. The convention in
    /// this file is now that a disabled control is proved dead by driving it,
    /// and the drive has to be the one the user has: buttons through
    /// `performClick`, sliders through real `NSEvent`s in a real `NSWindow`.
    ///
    /// **`NSSlider.sendAction(_:to:)` is what cannot be used, and that is
    /// measured rather than assumed.** With the chip correctly disabled and
    /// every assertion here passing, `slider.sendAction(...)` still drove
    /// `model.zoom.scale` to 4.0 — twice, on both this pane and the comparison
    /// one. It is a direct dispatch and not an event, so it bypasses
    /// `isEnabled` outright; no user can reach it, and asserting on it would
    /// pin a behaviour AppKit does not have. A synthesized *drag* on the
    /// slider's own rect is the user's route, and it does observe `isEnabled` —
    /// measured on the comparison chip, where the enabled control moved to 2.5×
    /// and the disabled one stayed at 1.0×. See
    /// `testAnEmptyComparisonPanesZoomChipIsDisabled`, which carries the
    /// enabled control for this technique.
    func testTheZoomChipIsDisabledWithNothingLoaded() throws {
        let model = ViewerModel(
            input: AppKitInputSource(),
            folderPicker: AppKitFolderPicker(),
            oauthPresenter: StubOAuthPresenter()
        )
        XCTAssertNil(model.currentPlaybackURL, "precondition: nothing is loaded")

        let pane = CGSize(width: 800, height: 450)
        let host = NSHostingView(
            rootView: ViewerPane(model: model, athleteName: "Idun")
                .frame(width: pane.width, height: pane.height)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: pane),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        let slider = try XCTUnwrap(Self.sliders(in: host).first, "precondition: the chip renders a slider")
        XCTAssertFalse(slider.isEnabled, "the zoom slider must read as disabled with no clip loaded")

        let buttons = Self.buttons(in: host)
        XCTAssertEqual(buttons.count, 3, "precondition: the chip's minus, plus and level-as-reset")
        for (index, button) in buttons.enumerated() {
            XCTAssertFalse(button.isEnabled, "chip button at index \(index) must read as disabled with no clip loaded")
        }

        for button in buttons {
            button.performClick(nil)
        }
        Self.dragAcross(slider, in: window)

        XCTAssertEqual(
            model.zoom, VideoZoom(),
            "nothing on a disabled zoom chip may reach the model: not its buttons, not a drag on its slider"
        )
    }

    /// **The chip takes its own clicks, and the video does not get them.**
    ///
    /// This is the rule the caption and the status chip meet by carrying
    /// `.allowsHitTesting(false)`: anything floating over `ViewerPane`'s video
    /// must not swallow the play/pause tap. The zoom chip cannot take that
    /// route — it is a control and needs its clicks — so it meets the rule by
    /// position instead, and that is a claim about hit-testing rather than
    /// about a modifier, so it is measured here rather than asserted.
    ///
    /// **The second click is the control, and it is not optional.** A click
    /// that landed on nothing at all would leave `rate` at 0 too, so the first
    /// assertion on its own would pass for the wrong reason — including if this
    /// test's arithmetic put the point outside the window. Clicking the pane's
    /// centre with the identical technique immediately afterwards proves the
    /// technique reaches the tap when it is *supposed* to.
    ///
    /// The chip's frame is read off the hosted `NSSlider` rather than computed
    /// from `ZoomControl`'s paddings and the 220pt cap `ViewerPane` gives it:
    /// that arithmetic would come out 4pt narrow. The cap cannot squeeze the
    /// control below its intrinsic 224pt, and nothing inside gives way to it —
    /// measured, the slider sits at exactly its 80pt minimum under the cap, so
    /// 224 is what renders. See `ViewerPane.zoomChip`.
    func testClickingTheZoomChipDoesNotAlsoToggleThePlaybackUnderneath() throws {
        let model = try Self.makeViewerModel()
        let pane = CGSize(width: 800, height: 450)
        XCTAssertEqual(model.player.rate, 0, "precondition: nothing is playing yet")

        let host = NSHostingView(
            rootView: ViewerPane(model: model, athleteName: "Idun")
                .frame(width: pane.width, height: pane.height)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: pane),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        let slider = try XCTUnwrap(Self.sliders(in: host).first, "precondition: the chip renders a slider")
        let inWindow = slider.convert(slider.bounds, to: nil)
        XCTAssertTrue(
            NSRect(origin: .zero, size: pane).contains(inWindow),
            "precondition: the chip must be inside the pane; measured \(inWindow)"
        )
        let onTheChip = CGPoint(x: inWindow.midX, y: inWindow.midY)
        window.sendEvent(Self.mouseEvent(.leftMouseDown, at: onTheChip, windowNumber: window.windowNumber))
        window.sendEvent(Self.mouseEvent(.leftMouseUp, at: onTheChip, windowNumber: window.windowNumber))

        XCTAssertEqual(
            model.player.rate, 0,
            """
            a click on the zoom chip must not fall through to the video's \
            play/pause tap; the chip sits above the gestures for exactly this \
            reason
            """
        )

        let onTheVideo = CGPoint(x: pane.width / 2, y: pane.height / 2)
        XCTAssertFalse(
            inWindow.contains(onTheVideo),
            "precondition: the pane's centre must be clear of the chip, or the control below proves nothing"
        )
        window.sendEvent(Self.mouseEvent(.leftMouseDown, at: onTheVideo, windowNumber: window.windowNumber))
        window.sendEvent(Self.mouseEvent(.leftMouseUp, at: onTheVideo, windowNumber: window.windowNumber))

        XCTAssertEqual(
            model.player.rate, 1,
            "control: the same technique on the video itself must toggle playback, or the assertion above is vacuous"
        )
    }

    /// At 1× the pan gesture is not installed at all, so it cannot swallow the
    /// single tap that plays and pauses — the one gesture `ViewerPane` had
    /// before zoom existed. A drag with the gesture present but the picture
    /// unzoomed would be harmless (`VideoZoom.pan` returns early unless
    /// `isZoomed`), but the tap would not be.
    func testTappingTheUnzoomedPaneStillTogglesPlayback() throws {
        let model = try Self.makeViewerModel()
        XCTAssertFalse(model.zoom.isZoomed, "precondition: 1x")
        XCTAssertEqual(model.player.rate, 0, "precondition: nothing is playing yet")

        let pane = CGSize(width: 400, height: 300)
        let host = NSHostingView(
            rootView: ViewerPane(model: model, athleteName: "Idun")
                .frame(width: pane.width, height: pane.height)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: pane),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        let point = CGPoint(x: 200, y: 150)
        window.sendEvent(Self.mouseEvent(.leftMouseDown, at: point, windowNumber: window.windowNumber))
        window.sendEvent(Self.mouseEvent(.leftMouseUp, at: point, windowNumber: window.windowNumber))

        XCTAssertEqual(model.player.rate, 1, "the zoom wiring must not have cost the pane its play/pause tap")
    }

    /// The other half of that arbitration, and the one that was *not* obvious:
    /// with the pan gesture installed, a stationary click must still reach the
    /// tap. **Measured** — `rate` goes to 1 and `center` stays exactly
    /// `(0.5, 0.5)`, so the drag neither swallows the click nor treats it as a
    /// zero-length pan.
    ///
    /// Worth its own test rather than folding into the one above: the two cover
    /// opposite sides of `ViewerPane`'s `isZoomed` condition, and only this one
    /// exercises a `DragGesture` and an `onTapGesture` competing for the same
    /// click.
    func testTappingTheZoomedPaneStillTogglesPlaybackWithoutPanning() throws {
        let model = try Self.makeViewerModel()
        let pane = CGSize(width: 400, height: 300)
        model.setZoomScale(4, in: pane)
        XCTAssertTrue(model.zoom.isZoomed, "precondition: the pan gesture is installed")
        XCTAssertEqual(model.player.rate, 0, "precondition: nothing is playing yet")

        let host = NSHostingView(
            rootView: ViewerPane(model: model, athleteName: "Idun")
                .frame(width: pane.width, height: pane.height)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: pane),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        let point = CGPoint(x: 200, y: 150)
        window.sendEvent(Self.mouseEvent(.leftMouseDown, at: point, windowNumber: window.windowNumber))
        window.sendEvent(Self.mouseEvent(.leftMouseUp, at: point, windowNumber: window.windowNumber))

        XCTAssertEqual(model.player.rate, 1, "the pan gesture must not swallow a stationary click")
        XCTAssertEqual(model.zoom.center.x, 0.5, accuracy: 0.0001, "a click is not a pan")
        XCTAssertEqual(model.zoom.center.y, 0.5, accuracy: 0.0001, "a click is not a pan")
    }

    /// **The viewer pane has no double-click reset, and this test is what keeps
    /// it that way.** `ComparisonPane` does have one, so the asymmetry looks
    /// like an omission; it is a measurement. Adding `.onTapGesture(count: 2)`
    /// beside the play/pause tap made SwiftUI hold *every* single tap until the
    /// double-click window closed — 358 ms against 1.2 ms, measured five clicks
    /// each on this view hosted in a real window, and paid whether or not
    /// anyone double-clicks. See the comment on `ViewerPane.body`.
    ///
    /// So what a double-click does here is play and then pause, which is what
    /// the two `rate` assertions pin: without them the "still 4×" assertion
    /// would pass on a click that landed on nothing at all.
    func testDoubleClickingTheViewerPaneDoesNotResetTheZoom() throws {
        let model = try Self.makeViewerModel()
        let pane = CGSize(width: 400, height: 300)
        model.setZoomScale(4, in: pane)
        model.panZoom(by: CGSize(width: -40, height: 0), in: pane)
        let panned = model.zoom.center.x
        XCTAssertNotEqual(panned, 0.5, accuracy: 0.0001, "precondition: the picture is zoomed and panned off centre")

        let (_, window) = try hostedPane(model: model, pane: pane)
        let point = CGPoint(x: 200, y: 150)

        Self.click(in: window, at: point, clickCount: 1)
        XCTAssertEqual(model.player.rate, 1, "control: the first click reaches the play/pause tap")

        Self.click(in: window, at: point, clickCount: 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        XCTAssertEqual(
            model.player.rate, 0,
            "control: the second click is a second play/pause toggle, which is all a double-click is here"
        )
        XCTAssertEqual(model.zoom.scale, 4, accuracy: 0.0001, "a double-click must not reset the viewer's zoom")
        XCTAssertEqual(model.zoom.center.x, panned, accuracy: 0.0001, "nor recentre the picture")
    }

    // MARK: - The comparison panes

    /// Double-click resets *this* side, and does it while the pan gesture is
    /// installed — 4× is the only state anyone would double-click in, and a
    /// `DragGesture` sharing the video can swallow taps. It does not.
    ///
    /// **Not because of `minimumDistance`**, which is the obvious explanation
    /// and is not the one: with `ComparisonPane`'s drag mutated to
    /// `minimumDistance: 0` this test and
    /// `testASingleClickOnAComparisonPaneLeavesTheZoomAlone` both still pass.
    /// The tap wins arbitration for a sequence that never moves, at a threshold
    /// of 0 as well as at the default 10pt — which is what this test measures
    /// and all it should be read as claiming.
    ///
    /// The left side is zoomed separately and asserted untouched, because
    /// `resetZoom(side:)` taking the wrong side — or ignoring it — is exactly
    /// the bug two identical panes hide.
    func testDoubleClickingAComparisonPaneResetsThatSideOnly() throws {
        let model = try Self.makeComparisonModel()
        defer { model.close() }
        let pane = CGSize(width: 400, height: 300)
        model.setZoomScale(2, in: pane, side: .left)
        model.setZoomScale(4, in: pane, side: .right)
        model.panZoom(by: CGSize(width: -40, height: 0), in: pane, side: .right)
        XCTAssertNotEqual(
            model.zoom(for: .right).center.x, 0.5, accuracy: 0.0001,
            "precondition: the right side is zoomed and panned off centre"
        )

        let (_, window) = try hostedComparisonPane(model: model, side: .right, pane: pane)
        let point = CGPoint(x: 200, y: 150)
        Self.click(in: window, at: point, clickCount: 1)
        Self.click(in: window, at: point, clickCount: 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        XCTAssertEqual(model.zoom(for: .right).scale, 1, accuracy: 0.0001, "the double-click must reset this side")
        XCTAssertEqual(
            model.zoom(for: .right).center.x, 0.5, accuracy: 0.0001,
            "and recentre it, which is the half a scale assertion alone would miss"
        )
        XCTAssertEqual(
            model.zoom(for: .left).scale, 2, accuracy: 0.0001,
            "and must leave the other side, which the operator framed separately, alone"
        )
    }

    /// The other half: a *single* click on a comparison pane must not reset it.
    /// Without this, `count: 2` could be `count: 1` and every test above would
    /// still pass — the pane has no single-tap action to notice the difference.
    func testASingleClickOnAComparisonPaneLeavesTheZoomAlone() throws {
        let model = try Self.makeComparisonModel()
        defer { model.close() }
        let pane = CGSize(width: 400, height: 300)
        model.setZoomScale(4, in: pane, side: .right)

        let (_, window) = try hostedComparisonPane(model: model, side: .right, pane: pane)
        Self.click(in: window, at: CGPoint(x: 200, y: 150), clickCount: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        XCTAssertEqual(
            model.zoom(for: .right).scale, 4, accuracy: 0.0001,
            "one click is not two; a single tap must leave the framing the operator set"
        )
    }


    /// **Mutation-check for this test: building both panes with `side: .left`
    /// must make it fail.** Without that, a pane wired to the wrong side is
    /// invisible — the two panes are otherwise identical, which is the same
    /// argument `ComparisonPane.emptyChooser` records for its accessibility
    /// label. Verified: with the chip's `side` uses replaced by a literal
    /// `.left` it fails on both assertions — the right side stays at 1.0 where
    /// 3.0 was asked for, and the left is driven to 3.0 from the 2.0 the
    /// operator had framed it at.
    ///
    /// **The slider position is written in normalised units**, for the reason
    /// `testDraggingTheZoomSliderReachesTheViewerModel` measured: SwiftUI keeps
    /// the `1...4` range in its own binding and hands AppKit a 0–1 control, so
    /// `doubleValue = 3` saturates at 1.0 and asks for 4.0 — the maximum, which
    /// would pass an assertion about *which side moved* while proving nothing
    /// about the value that got there.
    func testEachComparisonPaneDrivesItsOwnSide() throws {
        let model = try Self.makeComparisonModel()
        defer { model.close() }
        let pane = CGSize(width: 600, height: 400)
        model.setZoomScale(2, in: pane, side: .left)

        let host = NSHostingView(
            rootView: ComparisonPane(model: model, side: .right)
                .frame(width: pane.width, height: pane.height)
        )
        host.layoutSubtreeIfNeeded()

        let sliders = Self.sliders(in: host)
        XCTAssertEqual(sliders.count, 1, "precondition: one slider per pane, the zoom chip's")
        XCTAssertEqual(
            sliders[0].maxValue, 1.0, accuracy: 0.0001,
            "precondition: the hosted slider is normalised, so the target below is written in its units"
        )
        let target = 3.0
        let span = VideoZoom.range.upperBound - VideoZoom.range.lowerBound
        sliders[0].doubleValue = (target - VideoZoom.range.lowerBound) / span
        sliders[0].sendAction(sliders[0].action, to: sliders[0].target)

        XCTAssertEqual(
            model.zoom(for: .right).scale, target, accuracy: 0.0001,
            "the right pane's chip must move the right side"
        )
        XCTAssertEqual(
            model.zoom(for: .left).scale, 2, accuracy: 0.0001,
            "and must not touch the left, which the operator framed separately"
        )
    }

    /// The same per-side contract for the *drag*, which reaches the model by a
    /// completely different route — a gesture rather than a control's action —
    /// and so could be wired to the wrong side on its own.
    ///
    /// Mutation-checked the same way: with `panGesture`'s `side` replaced by a
    /// literal `.left` this fails, the left picture panning under a drag on the
    /// right pane — `0.5` where `0.5375` was asked for on the right, and
    /// `0.5375` on the left, which was to stay at `0.5`. All three of the
    /// comparison drag tests fail under that mutation, since each of them
    /// asserts on the side it dragged; this is the one that also pins the
    /// *other* side staying put.
    func testDraggingAComparisonPanePansOnlyThatSide() throws {
        let model = try Self.makeComparisonModel()
        defer { model.close() }
        let pane = CGSize(width: 400, height: 300)
        model.setZoomScale(4, in: pane, side: .right)
        model.setZoomScale(4, in: pane, side: .left)
        let (_, window) = try hostedComparisonPane(model: model, side: .right, pane: pane)

        Self.drag(in: window, from: CGPoint(x: 300, y: 250), by: -60, releasing: true)

        XCTAssertEqual(
            model.zoom(for: .right).center.x, 0.5375, accuracy: 0.002,
            "a 60pt drag at 4x in a 400pt pane must move that side's centre by 60/(400*4)"
        )
        XCTAssertEqual(
            model.zoom(for: .left).center.x, 0.5, accuracy: 0.0001,
            "the other pane's picture must not move under a drag it never received"
        )
    }

    /// The control for the test below, and the per-pane equivalent of
    /// `testTwoCleanDragsAreExactlyAdditive`: two clean drags total exactly
    /// their two distances, so `lastDrag` is cleared *back to rest* between
    /// gestures rather than left holding anything.
    func testTwoCleanDragsOnAComparisonPaneAreExactlyAdditive() throws {
        let model = try Self.makeComparisonModel()
        defer { model.close() }
        let pane = CGSize(width: 400, height: 300)
        model.setZoomScale(4, in: pane, side: .right)
        let (_, window) = try hostedComparisonPane(model: model, side: .right, pane: pane)

        Self.drag(in: window, from: CGPoint(x: 300, y: 250), by: -20, releasing: true)
        XCTAssertEqual(
            model.zoom(for: .right).center.x, 0.5125, accuracy: 0.002,
            "precondition: the first drag lands where one drag should"
        )

        Self.drag(in: window, from: CGPoint(x: 300, y: 250), by: -20, releasing: true)

        XCTAssertEqual(
            model.zoom(for: .right).center.x, 0.525, accuracy: 0.002,
            "two clean 20pt drags must total 40pt of pan, not more and not less"
        )
    }

    /// **The paired regression**, and the reason the pair exists: the defect
    /// this guards was invisible to five hundred tests because none of them
    /// exercised a *second* gesture after an interruption. The control above
    /// passes under both the right and the wrong implementation.
    ///
    /// `panGesture` is installed only while that side `isZoomed`, so dropping
    /// the pane to 1× removes the recognizer out from under a live drag and
    /// `DragGesture.onEnded` never runs — reachable here from the chip's own
    /// `−` and level buttons, and from any system drag cancellation. A `@State`
    /// running total reset in `onEnded` therefore goes stale; `@GestureState`
    /// reverts on cancel as well as on end.
    ///
    /// Measured on this harness, right pane at 4× in a 400×300 pane: a 60pt
    /// leftward drag torn down mid-flight, then a fresh 20pt leftward drag.
    ///
    /// | | second drag's `center.x` |
    /// | ------------------------------ | ------ |
    /// | `@GestureState` (shipping)     | 0.5125 |
    /// | `@State` + `onEnded` reset     | 0.475  |
    ///
    /// 0.475 is a leftward drag moving the picture 40pt to the *right* on its
    /// first frame — the dead drag's 60pt subtracted from the new 20pt.
    func testASecondDragOnAComparisonPaneAfterTheGestureIsTornDownStartsFromRest() throws {
        let model = try Self.makeComparisonModel()
        defer { model.close() }
        let pane = CGSize(width: 400, height: 300)
        model.setZoomScale(4, in: pane, side: .right)
        let (host, window) = try hostedComparisonPane(model: model, side: .right, pane: pane)

        // A 60pt drag with no mouse-up: the gesture is torn down underneath it
        // instead, which is what `onEnded` cannot see.
        Self.drag(in: window, from: CGPoint(x: 300, y: 250), by: -60, releasing: false)
        XCTAssertEqual(model.zoom(for: .right).center.x, 0.5375, accuracy: 0.002, "precondition: the first drag panned")

        model.resetZoom(side: .right)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(model.zoom(for: .right).isZoomed, "precondition: 1x, so the pan gesture is no longer installed")

        model.setZoomScale(4, in: pane, side: .right)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(model.zoom(for: .right).center.x, 0.5, accuracy: 0.0001, "precondition: the reset recentred")

        Self.drag(in: window, from: CGPoint(x: 300, y: 250), by: -20, releasing: true)

        XCTAssertEqual(
            model.zoom(for: .right).center.x, 0.5125, accuracy: 0.002,
            """
            the second drag must move by its own 20pt only; 0.475 means the \
            torn-down drag's 60pt was still being subtracted, sending a leftward \
            drag 40pt to the right
            """
        )
    }

    /// **An empty pane's chip is dead**, matching
    /// `testTheZoomChipIsDisabledWithNothingLoaded` for the viewer. The
    /// comparison window opens with both panes empty and the operator can leave
    /// one that way indefinitely, so this is the *ordinary* state of a
    /// comparison pane rather than an edge case.
    ///
    /// **Both halves are behavioural here, which is a departure from the
    /// viewer's test and the reason it is worth stating.** There the slider was
    /// covered by its `isEnabled` alone, because the obvious way to drive it —
    /// `NSSlider.sendAction(_:to:)` — bypasses `isEnabled` outright (measured:
    /// it drove a correctly-disabled chip to 4.0×) and asserting on it would
    /// pin a behaviour AppKit does not have. That left an asymmetry: buttons
    /// proved dead, the slider merely *read* dead. This test closes it by
    /// driving the slider the way a user does — real `NSEvent`s through a real
    /// `NSWindow`, the same technique the pan-gesture tests use — for which
    /// disabled is disabled.
    ///
    /// **The enabled control is not optional.** A synthesized drag that landed
    /// on nothing would leave the model untouched too, so the identical drag on
    /// a loaded pane's slider is what proves the technique reaches the control
    /// when it is supposed to. Measured, pressing at the slider's midpoint and
    /// dragging to its trailing edge: **1.0× on the empty pane, 2.5× on the
    /// loaded one**. 2.5 rather than 4.0 because the press itself lands the
    /// value at the midpoint and the drag that follows is not tracked further —
    /// which is immaterial here, since what this needs is a control that moves
    /// at all when it is enabled.
    ///
    /// Mutation-checked, and the slider drag carries its own weight rather than
    /// riding on the `isEnabled` assertions: with `isEnabled: isLoaded`
    /// replaced by `isEnabled: true` the empty pane's model ends at 2.5×, and
    /// all of that 2.5 is the drag — the three button clicks net back to 1.0
    /// (minus clamps, plus, then reset).
    func testAnEmptyComparisonPanesZoomChipIsDisabled() throws {
        let model = try Self.makeComparisonModel(load: [.left])
        defer { model.close() }
        XCTAssertFalse(ClipSourceMenu.isLoaded(model, .right), "precondition: the right pane is empty")

        let pane = CGSize(width: 600, height: 400)
        let (host, window) = try hostedComparisonPane(model: model, side: .right, pane: pane)

        let slider = try XCTUnwrap(Self.sliders(in: host).first, "precondition: the chip renders a slider")
        XCTAssertFalse(slider.isEnabled, "the zoom slider must read as disabled with no clip in this pane")
        let buttons = Self.buttons(in: host)
        XCTAssertEqual(buttons.count, 3, "precondition: the chip's minus, plus and level-as-reset")
        for (index, button) in buttons.enumerated() {
            XCTAssertFalse(button.isEnabled, "chip button at index \(index) must read as disabled with an empty pane")
        }

        for button in buttons {
            button.performClick(nil)
        }
        Self.dragAcross(slider, in: window)

        XCTAssertEqual(
            model.zoom(for: .right), VideoZoom(),
            "no control on a disabled chip may reach the model: neither its buttons nor a drag on its slider"
        )

        // The control. The same drag on the loaded pane's slider must move it,
        // or the assertion above passes for the wrong reason.
        let (loadedHost, loadedWindow) = try hostedComparisonPane(model: model, side: .left, pane: pane)
        let loadedSlider = try XCTUnwrap(Self.sliders(in: loadedHost).first)
        XCTAssertTrue(loadedSlider.isEnabled, "precondition: a loaded pane's chip is live")

        Self.dragAcross(loadedSlider, in: loadedWindow)

        XCTAssertTrue(
            model.zoom(for: .left).isZoomed,
            "control: the same synthesized drag on an enabled slider must reach the model"
        )
    }

    // MARK: - The overlay layout

    /// Both clips get the *same* zoom, and the alignment translation survives
    /// it. Per-side zoom cannot work here: the translation is expressed in
    /// normalised frame widths and both clips are masked to the region they
    /// share, so two independent scales would invalidate the registration and
    /// the mask together.
    ///
    /// The brief's version of this called `setZoomScale(_:side:)`; there is no
    /// such method — every zoom mutator on `ComparisonModel` takes the pane it
    /// is clamped against — so the pane is passed here.
    func testTheOverlayStackZoomsBothClipsTogether() throws {
        let model = ComparisonModel()
        defer { model.close() }
        model.layout = .overlay
        let stack = CGSize(width: 800, height: 450)
        model.setZoomScale(2, in: stack, side: .left)
        model.setZoomScale(4, in: stack, side: .right)

        let host = NSHostingView(
            rootView: ComparisonVideos(model: model, translation: CGVector(dx: 0.1, dy: 0))
                .frame(width: stack.width, height: stack.height)
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

        // ...and the alignment still holds, in the shipped view rather than in
        // the arithmetic `testTheAlignmentOffsetScalesWithTheZoomSoTheClipsStayRegistered`
        // pins. The body has to hand the zoom to `offset` as well as to the two
        // players; passing it to the players alone compiles, renders, and takes
        // the pair apart by 80pt here.
        //
        // The two frames are compared to *each other* rather than to the host's
        // origin: this `NSHostingView` was made with no frame and never put in a
        // window, so SwiftUI centres the 800 × 450 root in a zero-sized host and
        // both views sit at −400. The gap between them is the whole assertion,
        // and it is the quantity the alignment actually is.
        let bottom = try XCTUnwrap(hosts.first { $0.attachedPlayer === model.leftPlayer })
        let top = try XCTUnwrap(hosts.first { $0.attachedPlayer === model.rightPlayer })
        let gap = top.convert(top.bounds, to: host).minX - bottom.convert(bottom.bounds, to: host).minX
        XCTAssertEqual(
            gap, 160, accuracy: 0.5,
            "the floating clip must be offset by 0.1 × 800 × 2; 80 means the offset ignored the zoom"
        )
    }

    /// **The registration has to survive the zoom, and it does not for free.**
    ///
    /// The brief said to leave `offset` untouched, on the grounds that "the
    /// translation stays normalised". The translation does; its *conversion to
    /// points* does not. A normalised frame width is `renderedVideoWidth` points
    /// on screen at 1× and `renderedVideoWidth × scale` at any other scale,
    /// because `VideoZoom.layerFrame` scales the fitted picture rect. An offset
    /// that ignores the scale therefore under-moves the top clip by
    /// `(scale − 1) × dx × renderedVideoWidth` — 80pt of an 800pt frame at 2×
    /// and 0.1, 240pt at 4× — on the one screen whose entire job is alignment.
    ///
    /// Asserted as the invariant rather than as the formula: a feature at
    /// normalised `u` in the left clip corresponds to `u − dx` in the right, and
    /// the two must land on the same point of the stack. Mutation-checked by
    /// dropping the `× zoom.scale` from `offset`, which fails this at 480
    /// against 560 — an 80pt gap at 2×, 240pt at 4×.
    func testTheAlignmentOffsetScalesWithTheZoomSoTheClipsStayRegistered() {
        let container = CGSize(width: 800, height: 450)
        let video = CGSize(width: 1600, height: 900)
        let dx = 0.1
        var zoom = VideoZoom()
        zoom.setScale(2, in: container, videoSize: video)

        let picture = zoom.layerFrame(in: container, videoSize: video)
        let shift = OverlayPlayerStack.offset(
            for: CGVector(dx: dx, dy: 0), in: container, videoSize: video, zoom: zoom
        )

        // The same physical feature, in each clip's own normalised coordinates.
        let u = 0.6
        let bottom = picture.minX + picture.width * u
        let top = picture.minX + picture.width * (u - dx) + shift.width

        XCTAssertEqual(
            top, bottom, accuracy: 0.5,
            "the aligned pair came apart under zoom: the offset did not scale with the picture"
        )
        XCTAssertEqual(shift.width, 160, accuracy: 0.5, "0.1 × 800 × 2, not 0.1 × 800")
    }

    /// The mask has to follow the same picture the offset does.
    ///
    /// At 1× the shared region is the aspect-fit video rect intersected with its
    /// own shifted copy, which is what it has always been. Zoomed, the picture
    /// over-covers the stack, so the region both clips have picture in is the
    /// stack itself inset by the *scaled* shift — and the inset is scaled
    /// because that is where the top clip's picture actually stops: the layer is
    /// clipped to its host's bounds (`PlayerLayerHostView.configure`, pinned by
    /// `testTheHostViewClipsItsLayer`) *before* SwiftUI's `.offset` moves the
    /// host, so the strip the shift opens up at the leading edge has no top-clip
    /// picture in it at any scale.
    ///
    /// Leaving `sharedRect` on the unzoomed numbers would under-mask by exactly
    /// the difference — 80pt of single-clip picture at 2×, which in difference
    /// mode is a clip differenced against black and is the artefact the mask
    /// exists to remove.
    func testTheSharedRegionIsTakenFromTheZoomedPicture() {
        let container = CGSize(width: 800, height: 450)
        var zoom = VideoZoom()
        zoom.setScale(2, in: container, videoSize: .zero)
        let translation = CGVector(dx: 0.1, dy: 0)

        let zoomed = OverlayPlayerStack.sharedRect(
            for: translation, in: container, videoSize: .zero, zoom: zoom
        )

        XCTAssertEqual(
            zoomed, CGRect(x: 160, y: 0, width: 640, height: 450),
            "the shared region must be inset by the scaled shift, 0.1 × 800 × 2"
        )
        XCTAssertNotEqual(
            zoomed,
            OverlayPlayerStack.sharedRect(for: translation, in: container, videoSize: .zero),
            "the unzoomed answer insets by 80pt and would leave 80pt of one clip alone on screen"
        )
    }

    /// The chip in the overlay's chooser row drives the **left** side, which is
    /// the zoom the stack follows, and leaves the right side's own framing
    /// alone — the operator's side-by-side pan on the right clip is not the
    /// overlay's to overwrite.
    ///
    /// The slider position is written in normalised units for the reason
    /// `testDraggingTheZoomSliderReachesTheViewerModel` measured: SwiftUI keeps
    /// the `1...4` range in its own binding and hands AppKit a 0–1 control.
    func testTheOverlayZoomChipDrivesTheLeftSide() throws {
        let model = try Self.makeComparisonModel()
        defer { model.close() }
        model.layout = .overlay
        let stack = CGSize(width: 800, height: 450)

        let host = NSHostingView(
            rootView: ComparisonVideos(model: model)
                .frame(width: stack.width, height: stack.height)
        )
        host.layoutSubtreeIfNeeded()

        let sliders = Self.sliders(in: host)
        XCTAssertEqual(sliders.count, 1, "precondition: the overlay carries exactly one slider, the zoom chip's")
        let target = 3.0
        let span = VideoZoom.range.upperBound - VideoZoom.range.lowerBound
        sliders[0].doubleValue = (target - VideoZoom.range.lowerBound) / span
        sliders[0].sendAction(sliders[0].action, to: sliders[0].target)

        XCTAssertEqual(
            model.zoom(for: .left).scale, target, accuracy: 0.0001,
            "the overlay's chip must move the zoom the stack follows"
        )
        XCTAssertEqual(
            model.zoom(for: .right).scale, 1, accuracy: 0.0001,
            "and must not touch the right side's own framing, which side-by-side still uses"
        )
    }

    /// **A drag over the overlay pans both clips, because there is only one
    /// picture to pan.** Zooming to 4× with no way to pan leaves the operator
    /// looking at the middle of the frame with no route to the edges, which is
    /// the same dead end the viewer and the panes both have a drag for.
    ///
    /// It moves the left side's zoom — the one the stack renders both clips
    /// with — so the two move together by construction rather than by two
    /// mutations staying in step. The assertion checks both halves: the value
    /// the model holds, and that the two hosted layers still sit on exactly the
    /// same rect afterwards.
    func testDraggingTheOverlayPansBothClipsTogether() throws {
        let model = try Self.makeComparisonModel()
        defer { model.close() }
        model.layout = .overlay
        let stack = CGSize(width: 400, height: 300)
        model.setZoomScale(4, in: stack, side: .left)
        let (host, window) = try hostedComparisonVideos(model: model, stack: stack)

        Self.drag(in: window, from: CGPoint(x: 200, y: 250), by: -60, releasing: true)

        XCTAssertEqual(
            model.zoom(for: .left).center.x, 0.5375, accuracy: 0.002,
            "a 60pt drag at 4x in a 400pt stack must move the centre by 60/(400*4)"
        )
        XCTAssertEqual(
            model.zoom(for: .right).center, CGPoint(x: 0.5, y: 0.5),
            "the right side's own framing is not the overlay's to move"
        )

        host.layoutSubtreeIfNeeded()
        let hosts = Self.playerHosts(in: host)
        XCTAssertEqual(hosts.count, 2, "precondition: two players")
        XCTAssertEqual(
            hosts[0].playerLayerFrame, hosts[1].playerLayerFrame,
            "both clips must be panned by the same amount, or the pair comes apart"
        )
        // Equal frames alone are satisfied by *neither* clip moving: with the
        // zoom stripped from both `SinglePlayerView`s the two are the unzoomed
        // pane rect and identical. The width says they are the zoomed one.
        XCTAssertEqual(
            hosts[0].playerLayerFrame.width, 1600, accuracy: 0.5,
            "the shared frame must be the 4× one, not two matching unzoomed rects"
        )
    }

    // MARK: - The overlay's zoom cap

    /// **A shift large enough to eat the frame caps how far the overlay may be
    /// zoomed**, so the shared region can never collapse to nothing rather than
    /// merely being documented as able to. `OverlayPlayerStack.sharedRect`
    /// carries the geometry; the number here is
    /// `(1 − 0.1) / 0.35 = 2.571`.
    ///
    /// Driven through the real hosted `NSSlider` rather than by calling
    /// `maximumScale`, because the cap being right and the chip applying it are
    /// different failures in different files — and this is the one that decides
    /// what the operator can reach. The position is written in normalised units
    /// for the reason `testDraggingTheZoomSliderReachesTheViewerModel` measured.
    ///
    /// Mutation-checked by deleting the `min($0, overlayZoomCap)` clamp from
    /// `overlayChoosers`, which lands on 4.0 — where the shared region is
    /// `800 − 0.35 × 800 × 4 = −320`, i.e. nothing at all.
    func testALargeAlignmentShiftCapsHowFarTheOverlayZooms() throws {
        let model = try Self.makeComparisonModel()
        defer { model.close() }
        model.layout = .overlay
        let stack = CGSize(width: 800, height: 450)
        let (host, _) = try hostedComparisonVideos(
            model: model, stack: stack, translation: CGVector(dx: 0.35, dy: 0)
        )

        try driveZoomSlider(in: host, to: VideoZoom.range.upperBound)

        XCTAssertEqual(
            model.zoom(for: .left).scale, 2.571, accuracy: 0.01,
            "the chip must not hand the model a scale that blacks the overlay out"
        )
    }

    /// The other side of it, and the reason the cap is acceptable at all: a pair
    /// aligned well enough to be worth overlaying never feels it. `dx 0.05`
    /// caps at 18×, far outside `VideoZoom.range`, so the operator still reaches
    /// 4× — as they do for everything out to `dx 0.225`.
    func testASmallAlignmentShiftDoesNotCapTheOverlayAtAll() throws {
        let model = try Self.makeComparisonModel()
        defer { model.close() }
        model.layout = .overlay
        let stack = CGSize(width: 800, height: 450)
        let (host, _) = try hostedComparisonVideos(
            model: model, stack: stack, translation: CGVector(dx: 0.05, dy: 0)
        )

        try driveZoomSlider(in: host, to: VideoZoom.range.upperBound)

        XCTAssertEqual(
            model.zoom(for: .left).scale, 4, accuracy: 0.0001,
            "a well-aligned pair must still reach the full 4×"
        )
    }

    /// And with no alignment in force there is nothing to cap: `sharedRect`
    /// returns the whole container at every scale, so the bound is the range's
    /// own. This is most of a run, and it is also the state the overlay is in
    /// whenever Align is off or no track has been computed.
    func testAnIdentityTranslationLiftsTheOverlaysZoomCapEntirely() throws {
        let model = try Self.makeComparisonModel()
        defer { model.close() }
        model.layout = .overlay
        let stack = CGSize(width: 800, height: 450)
        let (host, _) = try hostedComparisonVideos(model: model, stack: stack)

        try driveZoomSlider(in: host, to: VideoZoom.range.upperBound)

        XCTAssertEqual(model.zoom(for: .left).scale, 4, accuracy: 0.0001)
        XCTAssertEqual(
            OverlayPlayerStack.maximumScale(for: .zero, in: stack, videoSize: .zero),
            VideoZoom.range.upperBound,
            "an identity translation must not bound the zoom at all"
        )
    }

    /// **The property the cap exists for: at the capped maximum there is still
    /// picture on screen.** Asserted across the shifts that matter rather than
    /// at one point, because the round numbers are exactly where the naive
    /// bound — the scale at which the region reaches zero — lands *on* zero:
    /// `dx 0.25` at 4.0× and `dx 0.5` at 2.0× both give a region 0pt wide, and
    /// both would put a black screen at the top of the slider. Every row below
    /// fails at exactly 0 with `1 / max(a, b)` in place of
    /// `0.9 / max(a, b)`.
    ///
    /// The vertical rows are not decoration: `dy` is scaled by the rendered
    /// *width* and inset from the container's *height*, so an axis mix-up in
    /// `maximumScale` survives every horizontal case.
    func testTheSharedRegionIsNeverEmptyAtTheCappedMaximum() {
        let square = CGSize(width: 800, height: 450)
        let wide = CGSize(width: 1000, height: 500)
        let cases: [(CGVector, CGSize, CGSize)] = [
            (CGVector(dx: 0.05, dy: 0), square, .zero),
            (CGVector(dx: 0.25, dy: 0), square, .zero),
            (CGVector(dx: 0.35, dy: 0), square, .zero),
            (CGVector(dx: 0.5, dy: 0), square, .zero),
            (CGVector(dx: 0.9, dy: 0), square, .zero),
            (CGVector(dx: 0, dy: 0.2), square, .zero),
            (CGVector(dx: 0, dy: -0.4), square, .zero),
            (CGVector(dx: 0.2, dy: 0.2), square, .zero),
            // A pillarboxed clip: 16:9 in the Compare window's 2:1 video area
            // draws 888.9pt wide inside 1000, so its shift eats 11.1% less of
            // the stack and the cap comes out 12.5% higher — 2.89× where the
            // container's own width would have said 2.57×. The looser one is
            // also the accurate one: it leaves exactly the 10% floor, 100pt of
            // 1000, where the shorthand overshoots to 200pt.
            (CGVector(dx: 0.35, dy: 0), wide, CGSize(width: 1920, height: 1080)),
        ]

        for (translation, container, videoSize) in cases {
            let cap = OverlayPlayerStack.maximumScale(
                for: translation, in: container, videoSize: videoSize
            )
            var zoom = VideoZoom()
            zoom.setScale(cap, in: container, videoSize: videoSize)
            let shared = OverlayPlayerStack.sharedRect(
                for: translation, in: container, videoSize: videoSize, zoom: zoom
            )

            XCTAssertGreaterThan(
                shared.width, 0,
                "\(translation) at its cap of \(cap)× leaves no picture across"
            )
            XCTAssertGreaterThan(
                shared.height, 0,
                "\(translation) at its cap of \(cap)× leaves no picture down"
            )
        }
    }

    /// **The cap bounds what is asked for; it never moves what is already
    /// set.** The gate engages and disengages during a run, so `translation` —
    /// and with it the cap — changes under a zoom the operator set earlier.
    /// Re-clamping the stored value would take their framing away mid-run at a
    /// moment they did nothing to cause; this leaves it, and the lifted cap
    /// simply lets them ask for more.
    func testLiftingTheCapLeavesTheZoomTheOperatorAlreadySet() throws {
        let model = try Self.makeComparisonModel()
        defer { model.close() }
        model.layout = .overlay
        let stack = CGSize(width: 800, height: 450)
        let (aligned, _) = try hostedComparisonVideos(
            model: model, stack: stack, translation: CGVector(dx: 0.35, dy: 0)
        )
        try driveZoomSlider(in: aligned, to: VideoZoom.range.upperBound)
        XCTAssertEqual(model.zoom(for: .left).scale, 2.571, accuracy: 0.01, "precondition: capped")

        // The gate disengages: the same model, now drawn with no translation.
        let (identity, _) = try hostedComparisonVideos(model: model, stack: stack)

        XCTAssertEqual(
            model.zoom(for: .left).scale, 2.571, accuracy: 0.01,
            "the cap lifting must not move the picture the operator is looking at"
        )

        try driveZoomSlider(in: identity, to: VideoZoom.range.upperBound)

        XCTAssertEqual(
            model.zoom(for: .left).scale, 4, accuracy: 0.0001,
            "...but it must let them ask for the rest of the range"
        )
    }

    /// **The chip's cap is not enough on its own, and this is the run that gets
    /// past it.**
    ///
    /// The cap is computed from the translation in force when the operator moved
    /// the slider, and `ComparisonView.alignmentTranslation` is resampled per
    /// playhead. `AlignmentGate.translation` returns the **raw measured**
    /// translation inside an engaged run — verified in its source: "Only the
    /// overlap used for the decision is filtered. The translation returned is
    /// always the measured one" — and the gate's own doc records this project's
    /// two measured tracks flipping between *adjacent* samples from `dy ≈ −0.04`
    /// (overlap 0.79) to `dy ≈ −0.42` (overlap 0.23), with the median filter
    /// there precisely to hold "engaged" across the flip.
    ///
    /// So: 4× is legal at the quiet sample (its cap is the full 4×), the next
    /// sample arrives at `dy −0.42`, and without a render-time bound the stack
    /// draws a shared region of nothing — black frames, mid-run, on the
    /// fixtures this feature was built against.
    ///
    /// Asserted on the hosted AppKit tree rather than on the arithmetic, because
    /// the arithmetic is already pinned by
    /// `testTheSharedRegionIsNeverEmptyAtTheCappedMaximum` and what is in
    /// question here is whether `body` *applies* it.
    ///
    /// **Mutation-checked by drawing with `zoom` instead of `drawn`, and the
    /// result is worse than "a smaller picture".** The hosted tree comes back
    /// with **zero** `PlayerLayerHostView`s: masked to an empty rect, SwiftUI
    /// does not instantiate the representables at all. So the unclamped stack is
    /// not a clip drawn too large behind a thin mask — it is two clips that are
    /// not on screen in any sense, which is as complete a black frame as this
    /// project can measure without a renderer that draws video.
    func testAZoomThatWasLegalWhenSetIsClampedWhenTheAlignmentGrowsUnderIt() throws {
        let container = CGSize(width: 800, height: 450)
        let quiet = CGVector(dx: 0, dy: -0.04)
        let flicker = CGVector(dx: 0, dy: -0.42)
        XCTAssertEqual(
            OverlayPlayerStack.maximumScale(for: quiet, in: container, videoSize: .zero),
            4, accuracy: 0.0001,
            "precondition: 4× is legal at the neighbouring sample, so the operator could set it"
        )

        var zoom = VideoZoom()
        zoom.setScale(4, in: container, videoSize: .zero)
        let model = try Self.makeComparisonModel()
        defer { model.close() }

        let host = NSHostingView(
            rootView: OverlayPlayerStack(
                bottomPlayer: model.leftPlayer,
                topPlayer: model.rightPlayer,
                topOpacity: model.topLayerOpacity,
                blend: model.blend,
                translation: flicker,
                zoom: zoom
            )
            .frame(width: container.width, height: container.height)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: container),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let hosts = Self.playerHosts(in: host)
        XCTAssertEqual(
            hosts.count, 2,
            """
            expected two players; zero is the failure this test exists for — \
            masked to an empty shared region SwiftUI drops both representables \
            outright, which is the black frame
            """
        )
        for player in hosts {
            XCTAssertEqual(
                player.playerLayerFrame.height, 542.4, accuracy: 1,
                "the picture must be drawn at the capped 1.205×, not the 4× that is no longer legal"
            )
        }

        // What is actually left on screen. The mask becomes a real clipping
        // `NSView` around each hosted player — the probe
        // `OverlayAlignmentWiringTests.testBothPlayersAreMaskedToTheSameSharedRegion`
        // rests on — so its frame is the shared region.
        for player in hosts {
            let clip = try XCTUnwrap(Self.clipRect(of: player, in: host), "no clipping ancestor")
            XCTAssertEqual(
                clip.height, 45, accuracy: 1,
                "the shared region must be the 10% floor — 45pt of 450 — and not the 0 a 4× draw leaves"
            )
            XCTAssertGreaterThan(clip.width, 0)
        }
    }

    /// **What the draw-time clamp does to a picture that is not centred**, which
    /// is the half of `drawnZoom` the other two tests cannot see: both of them
    /// start from a centred `VideoZoom()`, where the centre has nowhere to move
    /// and only the scale changes.
    ///
    /// `drawnZoom` reaches the lower scale through `setScale`, deliberately — a
    /// bare scale swap would leave the centre in the *wider* interval the higher
    /// scale allowed and hang the picture off an edge. The consequence, which is
    /// a real cost rather than a free correction: at 4× the legal interval is
    /// `[0.125, 0.875]` and at the capped 1.205× it is `[0.415, 0.585]`, so an
    /// operator panned into the corner does not merely see the picture shrink on
    /// a flicker sample — they see it slide most of the way back to the middle
    /// and out again when the translation settles.
    ///
    /// Measured, 800×450, no clip size yet, the `dy −0.42` flicker sample the
    /// test above uses:
    ///
    /// | translation | scale drawn | centre drawn |
    /// | ------------------- | ----------- | ---------------- |
    /// | quiet, `dy −0.04`   | 4.0×        | 0.875 (as set)   |
    /// | flicker, `dy −0.42` | 1.205×      | 0.585            |
    ///
    /// The picture still covers the stack at the clamped scale — that is the
    /// invariant `setScale` is re-establishing — and the stored zoom is
    /// untouched, so the next quiet sample restores the framing exactly.
    /// `OverlayPlayerStack.drawnZoom`'s doc records the ruling: if this proves
    /// distracting in the running app, the bound gets smoothed over time rather
    /// than removed.
    func testTheDrawTimeClampPullsAnOffCentrePanBackTowardTheMiddle() {
        let container = CGSize(width: 800, height: 450)
        var zoom = VideoZoom()
        zoom.setScale(4, in: container, videoSize: .zero)
        zoom.pan(by: CGSize(width: -10_000, height: -10_000), in: container, videoSize: .zero)
        XCTAssertEqual(
            zoom.center.y, 0.875, accuracy: 0.0001,
            "precondition: panned to 4×'s own bound, 1 − 1/(2·4)"
        )

        let drawn = OverlayPlayerStack.drawnZoom(
            zoom, for: CGVector(dx: 0, dy: -0.42), in: container, videoSize: .zero
        )

        XCTAssertEqual(drawn.scale, 1.2054, accuracy: 0.001, "0.9 / (0.42 · 800/450)")
        XCTAssertEqual(
            drawn.center.y, 0.5852, accuracy: 0.001,
            "the clamp re-clamps the centre too: 1 − 1/(2·1.2054), not the 0.875 that was legal at 4×"
        )
        XCTAssertEqual(drawn.center.x, 0.5852, accuracy: 0.001, "and on both axes, from the same corner pan")

        // The point of doing it: the smaller picture still covers the stack.
        // Leaving the centre at 0.875 would have put the layer's trailing edge
        // at 400 − 0.875 × 964.3 + 964.3 = 520.6pt of an 800pt stack.
        let frame = drawn.layerFrame(in: container, videoSize: .zero)
        XCTAssertLessThanOrEqual(frame.minX, 0.01)
        XCTAssertLessThanOrEqual(frame.minY, 0.01)
        XCTAssertGreaterThanOrEqual(frame.maxX, container.width - 0.01)
        XCTAssertGreaterThanOrEqual(frame.maxY, container.height - 0.01)

        // And it is a *drawing* decision, not a mutation: the next quiet sample
        // gets the operator's framing back untouched, which is what makes the
        // jump transient rather than a lost pan.
        let quiet = OverlayPlayerStack.drawnZoom(
            zoom, for: CGVector(dx: 0, dy: -0.04), in: container, videoSize: .zero
        )
        XCTAssertEqual(quiet, zoom, "a translation inside the cap must return the zoom exactly as set")
    }

    // MARK: - Switching between the two comparison layouts

    /// **`leftZoom` is one value with two different meanings, and switching
    /// layout is where that shows.** The overlay draws it against the whole
    /// video area; the left side-by-side pane draws it against a half-width
    /// pane. Nothing re-computes it at the switch, so a zoom framed in one
    /// layout is not the picture the operator gets back in the other. This test
    /// pins what actually happens rather than arguing it should be otherwise —
    /// making the two agree means a second stored zoom, or re-clamping the
    /// operator's framing under them at a layout change, and neither is
    /// obviously better than the jump.
    ///
    /// Measured, an 800×450 video area, a 16:9 clip in both sides, the overlay
    /// zoomed to 2.5× and panned to its bottom bound (`centre.y` 0.8):
    ///
    /// | | left pane | right pane |
    /// | ---------------- | ---------------- | ---------------- |
    /// | pane bounds      | 398.5 × 450      | 398.5 × 450      |
    /// | fitted picture   | 398.5 × 224.2    | 398.5 × 224.2    |
    /// | layer drawn      | 996.3 × 560.4    | 398.5 × 224.2    |
    ///
    /// **Two consequences, both asserted below.** The panes come back at
    /// *different* magnifications — 2.5× against 1× — because only the left
    /// side's zoom was ever touched. And `centre.y` 0.8 is legal in the overlay,
    /// where the clip fills the 16:9 area and the interval is `[0.2, 0.8]`, but
    /// illegal in the pane, where the same clip is letterboxed to 224.2pt of a
    /// 450pt pane and the interval narrows to `[0.402, 0.598]`.
    ///
    /// **No black band comes of it**: `layerFrame` re-clamps its render copy, so
    /// the pane draws at 0.598 and stays covered. Left unclamped it would have
    /// put the picture's bottom edge at 337.1pt and left a 112.9pt black band
    /// down the pane. The stored value keeps the 0.8 — the operator's framing is
    /// not silently rewritten — which is exactly why the two can disagree.
    ///
    /// A real clip rather than the zero-byte fixture the rest of this file uses:
    /// with no `presentationSize` the fitted rect *is* the pane on both
    /// screens, the two intervals coincide, and the case under test disappears.
    func testSwitchingBackFromTheOverlayLeavesTheTwoPanesFramedDifferently() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = ComparisonModel()
        defer { model.close() }
        for side in [ComparisonSide.left, .right] {
            let url = try makeRealVideoFile(
                in: root, name: "\(side == .left ? "left" : "right").mov",
                seconds: 1, width: 320, height: 180
            )
            model.load(url, side: side)
        }
        // The size arrives asynchronously, as everywhere else in this project.
        let deadline = Date().addingTimeInterval(10)
        while model.leftPlayer.currentItem?.presentationSize == CGSize.zero
            || model.rightPlayer.currentItem?.presentationSize == CGSize.zero,
            Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(
            model.leftPlayer.currentItem?.presentationSize, CGSize(width: 320, height: 180),
            "precondition: the clip's aspect is what makes the two intervals differ"
        )

        model.layout = .overlay
        let area = CGSize(width: 800, height: 450)
        let (host, _) = try hostedComparisonVideos(model: model, stack: area)
        model.setZoomScale(2.5, in: area, side: .left)
        model.panZoom(by: CGSize(width: 0, height: -10_000), in: area, side: .left)
        XCTAssertEqual(
            model.zoom(for: .left).center.y, 0.8, accuracy: 0.0001,
            "precondition: the overlay's own bound, 1 − 1/(2·2.5), with the clip filling the 16:9 area"
        )

        model.layout = .sideBySide
        settle(host)

        let hosts = Self.playerHosts(in: host)
        XCTAssertEqual(hosts.count, 2, "precondition: two panes")
        let left = try XCTUnwrap(
            hosts.first { $0.attachedPlayer === model.leftPlayer }, "no pane drawing the left clip"
        )
        let right = try XCTUnwrap(
            hosts.first { $0.attachedPlayer === model.rightPlayer }, "no pane drawing the right clip"
        )

        XCTAssertEqual(left.playerLayerFrame.height, 560.4, accuracy: 1)
        XCTAssertEqual(
            right.playerLayerFrame.height, 224.2, accuracy: 1,
            "the pair comes back at different magnifications: the overlay only ever moved the left side's zoom"
        )
        XCTAssertEqual(
            model.zoom(for: .left).center.y, 0.8, accuracy: 0.0001,
            "and the stored centre is not rewritten by the switch, legal in the new pane or not"
        )

        // What is drawn, against what is stored. `layerFrame`'s defensive clamp
        // is the only thing standing between the two, and it is what keeps the
        // pane covered.
        let fitted = right.playerLayerFrame.height
        let drawnCentre = (left.bounds.height * 0.5 - left.playerLayerFrame.minY) / (fitted * 2.5)
        XCTAssertEqual(
            drawnCentre, 0.598, accuracy: 0.005,
            "the pane draws at its own bound, 1 − 450/(2 × 224.2 × 2.5), not at the 0.8 the model holds"
        )
        XCTAssertLessThanOrEqual(left.playerLayerFrame.minY, 0.01)
        XCTAssertGreaterThanOrEqual(
            left.playerLayerFrame.maxY, left.bounds.height - 0.01,
            "no black band: the re-clamp is what stops 0.8 leaving 112.9pt of black down the pane"
        )
    }

    /// Lets SwiftUI apply a model change to an already-hosted tree. A published
    /// change is delivered on the next main-loop turn, so `layoutSubtreeIfNeeded`
    /// alone sees the old body.
    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
    }

    /// The frame of the nearest clipping ancestor of `view`, in `root`'s
    /// coordinates: the rect SwiftUI's `.mask` is enforcing around it.
    private static func clipRect(of view: NSView, in root: NSView) -> CGRect? {
        var ancestor = view.superview
        while let current = ancestor {
            if current.clipsToBounds { return current.convert(current.bounds, to: root) }
            ancestor = current.superview
        }
        return nil
    }

    /// Drives the overlay chip's real `NSSlider` to `scale`. The hosted slider
    /// is normalised whatever range SwiftUI was given — measured, see
    /// `testDraggingTheZoomSliderReachesTheViewerModel` — so the target is
    /// converted here.
    private func driveZoomSlider(in host: NSView, to scale: Double) throws {
        let sliders = Self.sliders(in: host)
        XCTAssertEqual(sliders.count, 1, "precondition: the overlay carries exactly one slider, the zoom chip's")
        let slider = try XCTUnwrap(sliders.first)
        let span = VideoZoom.range.upperBound - VideoZoom.range.lowerBound
        slider.doubleValue = (scale - VideoZoom.range.lowerBound) / span
        slider.sendAction(slider.action, to: slider.target)
    }

    /// The control for the regression below, and the overlay's version of
    /// `testTwoCleanDragsOnAComparisonPaneAreExactlyAdditive`: two clean drags
    /// total exactly their two distances, so the running total is cleared *back
    /// to rest* between gestures rather than left holding anything.
    func testTwoCleanDragsOnTheOverlayAreExactlyAdditive() throws {
        let model = try Self.makeComparisonModel()
        defer { model.close() }
        model.layout = .overlay
        let stack = CGSize(width: 400, height: 300)
        model.setZoomScale(4, in: stack, side: .left)
        let (_, window) = try hostedComparisonVideos(model: model, stack: stack)

        Self.drag(in: window, from: CGPoint(x: 200, y: 250), by: -20, releasing: true)
        XCTAssertEqual(
            model.zoom(for: .left).center.x, 0.5125, accuracy: 0.002,
            "precondition: the first drag lands where one drag should"
        )

        Self.drag(in: window, from: CGPoint(x: 200, y: 250), by: -20, releasing: true)

        XCTAssertEqual(
            model.zoom(for: .left).center.x, 0.525, accuracy: 0.002,
            "two clean 20pt drags must total 40pt of pan, not more and not less"
        )
    }

    /// **The paired regression.** The overlay's pan gesture is installed only
    /// while the left zoom `isZoomed`, so dropping to 1× removes the recognizer
    /// out from under a live drag and `DragGesture.onEnded` never runs —
    /// reachable from the chip's own `−` and level buttons, and from any system
    /// drag cancellation. `@GestureState` reverts on cancel as well as on end;
    /// a `@State` running total reset in `onEnded` goes stale and sends the next
    /// drag the wrong way. That defect was invisible to five hundred tests
    /// because none of them exercised a *second* gesture after an interruption,
    /// and the control above passes under both implementations.
    ///
    /// Mutation-checked on this harness, the stack at 4× in 400×300: a 60pt
    /// leftward drag torn down mid-flight, then a fresh 20pt leftward drag.
    ///
    /// | | second drag's `center.x` |
    /// | ------------------------------ | ------ |
    /// | `@GestureState` (shipping)     | 0.5125 |
    /// | `@State` + `onEnded` reset     | 0.475  |
    ///
    /// 0.475 is a leftward drag moving the picture 40pt to the *right* on its
    /// first frame — the dead drag's 60pt subtracted from the new 20pt. Under
    /// that mutation this test failed at exactly 0.475 and
    /// `testTwoCleanDragsOnTheOverlayAreExactlyAdditive` still passed.
    func testASecondDragOnTheOverlayAfterTheGestureIsTornDownStartsFromRest() throws {
        let model = try Self.makeComparisonModel()
        defer { model.close() }
        model.layout = .overlay
        let stack = CGSize(width: 400, height: 300)
        model.setZoomScale(4, in: stack, side: .left)
        let (host, window) = try hostedComparisonVideos(model: model, stack: stack)

        // A 60pt drag with no mouse-up: the gesture is torn down underneath it
        // instead, which is what `onEnded` cannot see.
        Self.drag(in: window, from: CGPoint(x: 200, y: 250), by: -60, releasing: false)
        XCTAssertEqual(model.zoom(for: .left).center.x, 0.5375, accuracy: 0.002, "precondition: the first drag panned")

        model.resetZoom(side: .left)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(model.zoom(for: .left).isZoomed, "precondition: 1x, so the pan gesture is no longer installed")

        model.setZoomScale(4, in: stack, side: .left)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(model.zoom(for: .left).center.x, 0.5, accuracy: 0.0001, "precondition: the reset recentred")

        Self.drag(in: window, from: CGPoint(x: 200, y: 250), by: -20, releasing: true)

        XCTAssertEqual(
            model.zoom(for: .left).center.x, 0.5125, accuracy: 0.002,
            """
            the second drag must move by its own 20pt only; 0.475 means the \
            torn-down drag's 60pt was still being subtracted, sending a leftward \
            drag 40pt to the right
            """
        )
    }

    /// The overlay's video area in a real off-screen `NSWindow`, for the same
    /// reason `hostedComparisonPane` builds one: synthetic mouse events do not
    /// reach SwiftUI's gesture recognition without one.
    private func hostedComparisonVideos(
        model: ComparisonModel, stack: CGSize, translation: CGVector = .zero
    ) throws -> (NSHostingView<some View>, NSWindow) {
        let host = NSHostingView(
            rootView: ComparisonVideos(model: model, translation: translation)
                .frame(width: stack.width, height: stack.height)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: stack),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        return (host, window)
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

    /// A `ComparisonPane` in a real off-screen `NSWindow`, for the same reason
    /// `hostedPane` builds one for the viewer: synthetic mouse events do not
    /// reach SwiftUI's gesture recognition without one.
    private func hostedComparisonPane(
        model: ComparisonModel, side: ComparisonSide, pane: CGSize
    ) throws -> (NSHostingView<some View>, NSWindow) {
        let host = NSHostingView(
            rootView: ComparisonPane(model: model, side: side)
                .frame(width: pane.width, height: pane.height)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: pane),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    /// A real mouse drag from a slider's middle to its trailing edge, in window
    /// coordinates. This is how a user moves a slider, and unlike
    /// `sendAction(_:to:)` it observes `isEnabled`.
    private static func dragAcross(_ slider: NSSlider, in window: NSWindow) {
        let rect = slider.convert(slider.bounds, to: nil)
        let y = rect.midY
        window.sendEvent(mouseEvent(.leftMouseDown, at: CGPoint(x: rect.midX, y: y), windowNumber: window.windowNumber))
        for step in 1...4 {
            let x = rect.midX + (rect.maxX - rect.midX) * CGFloat(step) / 4
            window.sendEvent(mouseEvent(.leftMouseDragged, at: CGPoint(x: x, y: y), windowNumber: window.windowNumber))
        }
        window.sendEvent(mouseEvent(.leftMouseUp, at: CGPoint(x: rect.maxX, y: y), windowNumber: window.windowNumber))
    }

    /// A comparison model with clips in the named panes. The zero-byte fixture
    /// is enough for everything here for the same reason it is in
    /// `ComparisonModelTests`: `AVPlayerItem` accepts any URL and reports
    /// failure asynchronously, so the player has a `currentItem` — which is all
    /// `ClipSourceMenu.isLoaded` asks — and reports no `presentationSize`,
    /// which is the pre-load case `VideoZoom` falls back to the pane's rect for.
    private static func makeComparisonModel(load sides: [ComparisonSide] = [.left, .right]) throws -> ComparisonModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = ComparisonModel()
        for side in sides {
            let url = root.appendingPathComponent("\(side == .left ? "left" : "right").mov")
            FileManager.default.createFile(atPath: url.path, contents: Data())
            model.load(url, side: side)
        }
        return model
    }

    /// A `ViewerPane` in a real off-screen `NSWindow`, which is what synthetic
    /// mouse events need to reach SwiftUI's gesture recognition — see
    /// `ViewerControlsWiringTests.testTappingTheViewerPaneTogglesPlaybackOnMacOS`
    /// for why `view.mouseDown(with:)` alone does not.
    private func hostedPane(model: ViewerModel, pane: CGSize) throws -> (NSHostingView<some View>, NSWindow) {
        let host = NSHostingView(
            rootView: ViewerPane(model: model, athleteName: "Idun")
                .frame(width: pane.width, height: pane.height)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: pane),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    /// A horizontal drag in three equal steps. `releasing: false` leaves the
    /// gesture live with no mouse-up, which is the cancellation case.
    ///
    /// Three steps rather than one because `DragGesture`'s default
    /// `minimumDistance` is 10pt: a single event of less than that would never
    /// start the gesture, and the per-change delta this file measures needs
    /// more than one change to be distinguishable from the whole translation.
    private static func drag(in window: NSWindow, from start: CGPoint, by dx: CGFloat, releasing: Bool) {
        window.sendEvent(mouseEvent(.leftMouseDown, at: start, windowNumber: window.windowNumber))
        for step in 1...3 {
            let point = CGPoint(x: start.x + dx * CGFloat(step) / 3, y: start.y)
            window.sendEvent(mouseEvent(.leftMouseDragged, at: point, windowNumber: window.windowNumber))
        }
        if releasing {
            window.sendEvent(
                mouseEvent(.leftMouseUp, at: CGPoint(x: start.x + dx, y: start.y), windowNumber: window.windowNumber)
            )
        }
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

    /// A press and release at one point. `clickCount` is what makes two of
    /// these a *double*-click rather than two clicks: AppKit numbers the clicks
    /// of a run itself, and a second event still claiming `clickCount: 1` is
    /// what a slow, deliberate pair of separate clicks looks like.
    private static func click(in window: NSWindow, at point: CGPoint, clickCount: Int) {
        window.sendEvent(
            mouseEvent(.leftMouseDown, at: point, windowNumber: window.windowNumber, clickCount: clickCount)
        )
        window.sendEvent(
            mouseEvent(.leftMouseUp, at: point, windowNumber: window.windowNumber, clickCount: clickCount)
        )
    }

    private static func mouseEvent(
        _ type: NSEvent.EventType, at point: CGPoint, windowNumber: Int, clickCount: Int = 1
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        )!
    }

    /// A one-clip library in a temporary directory, following
    /// `ViewerControlsWiringTests`' pattern. `VideoLibrary.scan` inspects file
    /// extensions only and nothing here decodes anything, so a zero-byte
    /// `run1.mp4` is enough; it reports no `presentationSize`, which is the
    /// pre-load case `VideoZoom` falls back to the pane's rect for.
    ///
    /// `StubOAuthPresenter` is the target-wide stub from
    /// `AppKitOAuthPresenterTests`, reused here as `AppKitInputToModelTests`
    /// reuses it, rather than writing a second one.
    private static func makeViewerModel() throws -> ViewerModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let athlete = root.appendingPathComponent("Idun", isDirectory: true)
        try FileManager.default.createDirectory(at: athlete, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: athlete.appendingPathComponent("run1.mp4").path, contents: Data())

        let model = ViewerModel(
            input: AppKitInputSource(),
            folderPicker: AppKitFolderPicker(),
            oauthPresenter: StubOAuthPresenter()
        )
        model.openDirectory(root)
        return model
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

    // MARK: - Reading the screen

    private func capture(_ window: NSWindow) -> CGImage? {
        CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        )
    }

    /// Mean luminance of the capture's top third and bottom third.
    private func bands(of image: CGImage) throws -> (top: Double, bottom: Double) {
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func mean(rows: Range<Int>) -> Double {
            var sum = 0.0
            for y in rows {
                for x in 0..<width { sum += Double(buffer[(y * width + x) * 4]) }
            }
            return sum / Double(rows.count * width)
        }
        return (mean(rows: 0..<(height / 3)), mean(rows: (height * 2 / 3)..<height))
    }

    // MARK: - Finding the host

    private func playerLayerHost(in view: NSView) -> PlayerLayerHostView? {
        if let host = view as? PlayerLayerHostView { return host }
        for sub in view.subviews {
            if let found = playerLayerHost(in: sub) { return found }
        }
        return nil
    }

    // MARK: - Fixture

    /// A real H.264 clip of a known size. Duplicated from
    /// `SkiVideoCoreTests/RealVideoFixture.swift` for the same cross-target
    /// reason `SharedControlsWiringTests` duplicates it: that helper is an
    /// `XCTestCase` extension scoped to a target this one does not depend on.
    /// An empty file will not do here — it never reports a `presentationSize`
    /// at all, which is exactly the value under test.
    /// `whiteTopQuarter` swaps the frame-varying grey for a fixed white band
    /// across the picture's top quarter, which is what makes "which end of the
    /// clip is on screen" a number rather than a judgement.
    private func makeRealVideoFile(
        in directory: URL,
        name: String,
        seconds: Double,
        width: Int,
        height: Int,
        fps: Int32 = 10,
        whiteTopQuarter: Bool = false
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        XCTAssertTrue(writer.startWriting(), "could not start writing the fixture: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)

        let frames = Int(seconds * Double(fps))
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
            let pool = try XCTUnwrap(adaptor.pixelBufferPool, "the writer gave no pixel buffer pool")
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer), kCVReturnSuccess)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            if let base = CVPixelBufferGetBaseAddress(pixels) {
                let stride = CVPixelBufferGetBytesPerRow(pixels)
                if whiteTopQuarter {
                    // Row 0 of a CVPixelBuffer is the top of the picture, so
                    // this band is unambiguous about which end is which.
                    let bytes = base.assumingMemoryBound(to: UInt8.self)
                    for y in 0..<height {
                        memset(bytes + y * stride, y < height / 4 ? 255 : 0, stride)
                    }
                } else {
                    memset(base, Int32(frame % 251), stride * CVPixelBufferGetHeight(pixels))
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: fps))

        let written = expectation(description: "fixture written")
        writer.finishWriting { written.fulfill() }
        wait(for: [written], timeout: 60)
        XCTAssertEqual(writer.status, .completed, "fixture encode failed: \(String(describing: writer.error))")
        return url
    }
}
