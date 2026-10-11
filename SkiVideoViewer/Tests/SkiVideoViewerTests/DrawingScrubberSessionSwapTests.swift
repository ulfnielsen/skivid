import AppKit
import SwiftUI
import XCTest
@testable import SkiVideoCore
@testable import SkiVideoViewer

/// The viewer's timeline must follow the drawings session across a clip
/// change, not just the first one it rendered.
///
/// `DrawingAwareScrubber` observes the optional session through `onReceive`
/// on an erased publisher, because an optional cannot be an
/// `@ObservedObject`. Whether that subscription moves to the new session when
/// the clip changes was unproven. This hosts the scrubber over two real clips,
/// draws on each, and counts orange span-bar pixels.
///
/// Adopted from the final review's regression check.
///
/// Mutation-checked (2026-10-11): with `onReceive` removed, both "a new mark
/// shows a bar" assertions fail (0 orange pixels); with the subscription and
/// spans pinned to the first session the scrubber saw, "clip 2 starts with no
/// bars" fails (60 orange pixels — clip 1's bar left on clip 2's timeline).
@MainActor
final class DrawingScrubberSessionSwapTests: XCTestCase {
    func testBarsFollowANewSessionAfterAClipChange() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SkiVideoViewerUITests/Fixtures/supported-420-8bit.mp4")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let athlete = root.appendingPathComponent("Idun", isDirectory: true)
        try FileManager.default.createDirectory(at: athlete, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: athlete.appendingPathComponent("run1.mp4"))
        try FileManager.default.copyItem(at: fixture, to: athlete.appendingPathComponent("run2.mp4"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suite = "DrawingScrubberSessionSwapTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = ViewerModel(input: AppKitInputSource(), folderPicker: AppKitFolderPicker(),
                                oauthPresenter: StubOAuthPresenter(),
                                drawing: DrawingController(defaults: defaults, saveDelay: 60))
        model.openDirectory(root)
        func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        func waitLoaded() {
            let deadline = Date().addingTimeInterval(20)
            while (model.pictureSize == .zero || model.duration == 0), Date() < deadline { pump(0.02) }
        }
        waitLoaded()

        let host = NSHostingView(rootView: DrawingAwareScrubber(model: model).frame(width: 600, height: 44))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 44),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        addTeardownBlock { @MainActor in window.orderOut(nil) }

        func orangePixels() -> Int {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return -1 }
            host.cacheDisplay(in: host.bounds, to: rep)
            var n = 0
            for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent > 0.9, c.greenComponent > 0.5, c.greenComponent < 0.75,
                   c.blueComponent > 0.2, c.blueComponent < 0.45 { n += 1 }
            } }
            return n
        }
        let g = DrawingGeometry(pictureFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                                videoSize: model.pictureSize)
        func drawLine() {
            let s = model.drawing.session!
            s.tool = .line
            s.dragBegan(at: CGPoint(x: 100, y: 500), geometry: g, time: 0, frameDuration: model.frameDuration)
            s.dragEnded(at: CGPoint(x: 900, y: 500), geometry: g)
        }

        pump(0.3)
        XCTAssertEqual(orangePixels(), 0, "clip 1 starts with no bars")
        drawLine()
        pump(0.3)
        let first = orangePixels()
        XCTAssertGreaterThan(first, 0, "clip 1: a new mark shows a bar (orange pixels: \(first))")

        XCTAssertTrue(model.changeVideo(by: 1))
        waitLoaded()
        pump(0.5)
        XCTAssertEqual(orangePixels(), 0, "clip 2 starts with no bars")
        drawLine()
        pump(0.5)
        let second = orangePixels()
        XCTAssertGreaterThan(second, 0,
                             "clip 2: after the session swap a new mark must still show a bar (orange pixels: \(second))")
    }
}
