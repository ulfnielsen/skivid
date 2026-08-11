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
