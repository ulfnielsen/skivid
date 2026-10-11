import AppKit
import SwiftUI
import XCTest
@testable import SkiVideoCore
@testable import SkiVideoViewer

/// The tap-to-play arbitration with the drawing layer present, on a real clip.
///
/// `ZoomWiringTests` hosts `ViewerPane` over a zero-byte `run1.mp4`, so
/// `pictureSize` stays `.zero` and `DrawingOverlay` renders nothing there: its
/// play/pause tap tests pass without the overlay in the tree. In use the
/// overlay is always present (`showsDrawings` defaults to true), so these use
/// a decodable clip and wait for the picture size to arrive.
@MainActor
final class DrawingWiringTests: XCTestCase {
    override func setUp() {
        super.setUp()
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    private func makeLoadedModel() throws -> ViewerModel {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SkiVideoViewerUITests/Fixtures/supported-420-8bit.mp4")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let athlete = root.appendingPathComponent("Idun", isDirectory: true)
        try FileManager.default.createDirectory(at: athlete, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: athlete.appendingPathComponent("run1.mp4"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        // Its own suite: `ShowDrawings` must not come from, or leak into, the
        // real defaults.
        let suite = "DrawingWiringTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = ViewerModel(
            input: AppKitInputSource(), folderPicker: AppKitFolderPicker(),
            oauthPresenter: StubOAuthPresenter(),
            drawing: DrawingController(defaults: defaults, saveDelay: 60)
        )
        model.openDirectory(root)
        let deadline = Date().addingTimeInterval(20)
        while model.pictureSize == .zero, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertNotEqual(model.pictureSize, .zero, "precondition: the clip's picture size arrived")
        return model
    }

    private func host(_ model: ViewerModel) -> NSWindow {
        let pane = CGSize(width: 400, height: 300)
        let host = NSHostingView(rootView: ViewerPane(model: model, athleteName: "Idun")
            .frame(width: pane.width, height: pane.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: pane),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        // Let the overlay (which only appears once the session exists) render.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        return window
    }

    private func click(_ window: NSWindow, at point: CGPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
    }

    /// With the overlay showing saved marks but not drawing, the click must
    /// still reach play/pause: the overlay's Canvas and labels are not
    /// hit-testable, and no draw gesture is installed.
    func testTappingThePaneStillTogglesPlaybackWithTheDrawingOverlayShowing() throws {
        let model = try makeLoadedModel()
        XCTAssertTrue(model.drawing.showsDrawings, "precondition: drawings are shown")
        XCTAssertFalse(model.drawing.isDrawing, "precondition: not drawing")
        XCTAssertEqual(model.player.rate, 0, "precondition: paused")
        let window = host(model)

        click(window, at: CGPoint(x: 200, y: 150))

        XCTAssertEqual(model.player.rate, 1, "the drawing layer must not swallow the play/pause tap")
    }

    /// In drawing mode a tap places or selects a mark; it must not also start
    /// playback under the coach's pen.
    func testTappingTheDrawingPaneDoesNotTogglePlayback() throws {
        let model = try makeLoadedModel()
        model.setDrawing(true)
        XCTAssertTrue(model.drawing.isDrawing, "precondition: drawing mode is on")
        let window = host(model)

        click(window, at: CGPoint(x: 200, y: 150))

        XCTAssertEqual(model.player.rate, 0, "a tap while drawing must not play")
        XCTAssertTrue(model.drawing.isDrawing, "and must not leave drawing mode")
    }

    /// The span bars must sit below the slider's own extent. Overlapping it
    /// they swallowed presses meant for the slider (and their tap sought to
    /// the span start instead of the pointer).
    ///
    /// Measured rather than clicked: on this host the `Slider` is not an
    /// `NSSlider` at all (the tree is `KeyViewProxy` + `_FocusRingView`, each
    /// 16pt tall and centred in the 44pt row), so there is no control to drive
    /// or hit-test, and a hit test cannot tell a SwiftUI bar from the SwiftUI
    /// slider. The `KeyViewProxy` frame is the slider's extent; the bars are
    /// found as orange pixels (measured 0.96, 0.64, 0.33) in the rendered bitmap.
    func testSpanBarsAreDrawnBelowTheSlidersOwnExtent() throws {
        let width = 600.0, rowHeight = 44.0
        let host = NSHostingView(rootView: TimelineScrubber(
            time: 0, duration: 10, marks: [4...5], onScrub: { _ in }
        ).frame(width: width, height: rowHeight))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: rowHeight),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        func find(_ v: NSView) -> NSView? {
            if String(describing: type(of: v)) == "KeyViewProxy" { return v }
            return v.subviews.lazy.compactMap(find).first
        }
        let proxy = try XCTUnwrap(find(host), "precondition: the slider's KeyViewProxy")
        let slider = host.convert(proxy.bounds, from: proxy)   // host is flipped: y down
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        var rows = Set<Int>()
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent > 0.9, c.greenComponent > 0.5, c.greenComponent < 0.75, c.blueComponent > 0.2, c.blueComponent < 0.45 {
                    rows.insert(y)
                }
            }
        }
        let scale = Double(rep.pixelsHigh) / host.bounds.height
        XCTAssertFalse(rows.isEmpty, "precondition: the bar renders orange pixels")
        let top = Double(rows.min() ?? 0) / scale
        XCTAssertGreaterThanOrEqual(top, Double(slider.maxY),
                                    "the bar's top (\(top)) is inside the slider's extent \(slider)")
    }
}
