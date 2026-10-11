import AppKit
import SwiftUI
import XCTest
@testable import SkiVideoViewer

/// The comparison screen's chips over snow, in light appearance — the same
/// white-on-white the viewer's caption had (`ViewerCaptionLayoutTests`), and
/// the same capture: a briefly ordered-in window read back with
/// `CGWindowListCreateImage`, because the blur is composited by the window
/// server and `cacheDisplay` returns it as pure white.
@MainActor
final class ComparisonChipBackingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    /// The shipped status chip: 340pt wide, so a short status leaves its left
    /// end empty capsule to sample.
    func testTheStatusChipIsDarkInLightAppearanceOverASnowyBackdrop() throws {
        let luminance = try meanLuminance(
            of: ComparisonStatusChip(status: "Ready", alignmentNote: nil),
            size: CGSize(width: 400, height: 80),
            // The chip is centred: its capsule starts at x = 30. 15pt in is
            // clear of the rounded end and well short of the centred text.
            sampling: CGRect(x: 45, y: 36, width: 10, height: 8)
        )
        XCTAssertLessThan(luminance, 0.5, "status chip backing over snow: mean luminance \(luminance)")
    }

    /// A control that sets no colour of its own — `ZoomControl`, the close
    /// glyph — must turn light on the backing, or it is black on dark in light
    /// mode. Sampled on the glyph itself: a filled circle drawn in the primary
    /// colour inside the backing.
    func testContentWithoutItsOwnColourTurnsLightOnTheBacking() throws {
        let luminance = try meanLuminance(
            of: Circle().fill(.primary).frame(width: 30, height: 30)
                .padding(20)
                .darkFrostedBacking(in: Circle()),
            size: CGSize(width: 120, height: 120),
            sampling: CGRect(x: 55, y: 55, width: 10, height: 10)
        )
        XCTAssertGreaterThan(luminance, 0.8, "primary-coloured content on the backing: mean luminance \(luminance)")
    }

    private func meanLuminance(of content: some View, size: CGSize, sampling rect: CGRect) throws -> CGFloat {
        let view = ZStack { Color.white; content }.frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: 100, y: 100))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let shot = try XCTUnwrap(CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .nominalResolution]
        ))
        let rep = NSBitmapImageRep(cgImage: shot)
        var total: CGFloat = 0
        var count: CGFloat = 0
        for x in Int(rect.minX)..<Int(rect.maxX) {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                let color = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                total += 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                count += 1
            }
        }
        return total / count
    }
}
