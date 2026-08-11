import AppKit
import AVFoundation
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

    /// The default keeps the call sites that predate zoom honest about not
    /// passing one, rather than making them pass `VideoZoom()` by hand.
    func testAViewBuiltWithoutAZoomIsUnzoomed() throws {
        let host = NSHostingView(
            rootView: SinglePlayerView(player: AVPlayer()).frame(width: 800, height: 450)
        )
        host.layoutSubtreeIfNeeded()

        let layerHost = try XCTUnwrap(playerLayerHost(in: host))
        XCTAssertFalse(layerHost.appliedZoom.isZoomed)
        XCTAssertEqual(layerHost.playerLayerFrame.width, 800, accuracy: 0.5)
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
    private func makeRealVideoFile(
        in directory: URL,
        name: String,
        seconds: Double,
        width: Int,
        height: Int,
        fps: Int32 = 10
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
                memset(base, Int32(frame % 251), CVPixelBufferGetBytesPerRow(pixels) * CVPixelBufferGetHeight(pixels))
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
