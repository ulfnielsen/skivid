import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import SkiVideoCore
@testable import SkiVideoViewer

/// Proves the shared controls are actually wired to their closures, not
/// merely compiling against them.
///
/// `TransportControls` and `TimelineScrubber` are pure view types — values
/// and closures, no model — so nothing forces a caller's closure to run when
/// the AppKit control underneath actually fires. `ComparisonControlBarLayoutTests`
/// proves the bar occupies the right frame; it says nothing about whether
/// tapping a button does anything. Every other test that touches
/// `TransportAction` or `ComparisonScrubber` drives `ComparisonModel`
/// directly and never renders the view at all.
///
/// These tests synthesize a real click on the actual `NSControl` SwiftUI
/// renders, found by walking the `NSHostingView`'s subviews exactly as
/// `ComparisonControlBarLayoutTests` walks it for frames — headless, no app
/// launched, nothing on screen. Two things were checked empirically before
/// writing this, by dumping the hosted view tree and trying both:
/// `NSButton.performClick(nil)` reaches the SwiftUI action closure;
/// `sendAction(_:to:)` does not, because SwiftUI leaves the classic
/// `target`/`action` pair nil here and wires the click some other way.
@MainActor
final class SharedControlsWiringTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // NSHostingView needs the shared application to exist before it will
        // lay anything out. `.prohibited` keeps it out of the Dock and off
        // the screen — nothing is presented — matching the technique
        // `ComparisonControlBarLayoutTests` already uses.
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    /// Kills the mutation of replacing `perform(action)` with `{}` inside
    /// `TransportControls.button`. That mutation compiles cleanly and passes
    /// every other test in the repo: the model-level tests call
    /// `ComparisonModel.applyTransport` directly, bypassing the view
    /// entirely, and the iPad UI tests only ever see the transport disabled
    /// (no route loads real clips there), so they assert `isEnabled == false`
    /// and never click. This performs a real click on each of the six
    /// buttons in turn and checks the closure fired with the matching
    /// action — in `TransportAction.allCases` order, which is the order the
    /// `ForEach` renders them left to right.
    func testClickingEachTransportButtonInvokesPerformWithItsAction() {
        var received: [TransportAction] = []
        let host = NSHostingView(
            rootView: TransportControls(isEnabled: true) { received.append($0) }
                .frame(width: 400, height: 60)
        )
        host.layoutSubtreeIfNeeded()

        for button in transportButtons(in: host) {
            button.performClick(nil)
        }

        XCTAssertEqual(
            received,
            TransportAction.allCases,
            "every button must invoke perform with its own action, in declaration order"
        )
    }

    /// The other half of the same wiring: a disabled transport must not fire
    /// at all, or a control that reads as disabled — to a user, and to the
    /// iPad UI test that asserts `isEnabled == false` before any clip is
    /// loaded — could still act on a click that reaches it.
    func testADisabledTransportDoesNotInvokePerform() {
        var received: [TransportAction] = []
        let host = NSHostingView(
            rootView: TransportControls(isEnabled: false) { received.append($0) }
                .frame(width: 400, height: 60)
        )
        host.layoutSubtreeIfNeeded()

        for button in transportButtons(in: host) {
            button.performClick(nil)
        }

        XCTAssertTrue(received.isEmpty, "a disabled transport must not invoke perform")
    }

    /// Kills the mutation of replacing `ComparisonScrubber`'s `duration:`
    /// argument with a constant `0`. That mutation also compiles cleanly and
    /// passes every other test: `ComparisonModelTests` and
    /// `ComparisonScrubbedSideTests` drive `ComparisonModel.scrub` directly,
    /// bypassing the view, and every fixture they load is a zero-byte file
    /// whose `AVPlayerItem.duration` reports NaN — which
    /// `ComparisonModel.observeDuration` never publishes, since it guards on
    /// `isFinite`. `leftDuration` would read 0 there with or without the
    /// mutation, so nothing could tell them apart.
    ///
    /// Only a real, decodable clip gives `leftDuration` a genuine nonzero
    /// value, which is what distinguishes a correctly wired scrubber from a
    /// mutated one: `TimelineScrubber` disables its slider exactly when
    /// `duration <= 0`. `makeRealVideoFile` below is duplicated from
    /// `SkiVideoCoreTests/RealVideoFixture.swift` because that helper is an
    /// `XCTestCase` extension scoped to the `SkiVideoCoreTests` target, which
    /// `SkiVideoViewerTests` does not depend on.
    func testComparisonScrubberEnablesOnceTheRealDurationIsKnown() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = try makeRealVideoFile(in: root, name: "left.mov", seconds: 1)

        let model = ComparisonModel()
        model.load(url, side: .left)

        // The duration observer is asynchronous KVO on the AVPlayerItem, so
        // this polls a bounded run loop rather than asserting immediately —
        // the same pattern `ComparisonStatusChipTests.chipFrame` uses to wait
        // on a SwiftUI preference.
        let deadline = Date().addingTimeInterval(10)
        while model.leftDuration <= 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThan(
            model.leftDuration, 0,
            "precondition: the fixture's duration must actually be known"
        )

        let host = NSHostingView(rootView: ComparisonScrubber(model: model).frame(width: 400, height: 60))
        host.layoutSubtreeIfNeeded()

        let slider = try XCTUnwrap(scrubberSlider(in: host), "expected to find the scrubber's NSControl")
        XCTAssertTrue(slider.isEnabled, "the scrubber must be enabled once a real duration is known")
    }

    // MARK: - View-tree walking

    /// The six transport buttons render as `SwiftUIAppKitButton`, a real
    /// `NSButton` subclass — confirmed by dumping the hosted view tree
    /// before writing this test. Walking `subviews` rather than using
    /// accessibility identifiers: this is the AppKit tree `NSHostingView`
    /// builds, not the accessibility tree the iPad UI tests read.
    private func transportButtons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        if let button = view as? NSButton { found.append(button) }
        for sub in view.subviews { found.append(contentsOf: transportButtons(in: sub)) }
        return found
    }

    /// The slider renders several layers deep as `CustomMarkedSlider`, a
    /// private AppKit class whose `isEnabled` mirrors SwiftUI's
    /// `.disabled(...)` — also confirmed empirically. Matched by class name
    /// rather than by type, since the class itself is not public API.
    private func scrubberSlider(in view: NSView) -> NSControl? {
        if String(describing: type(of: view)) == "CustomMarkedSlider" {
            return view as? NSControl
        }
        for sub in view.subviews {
            if let found = scrubberSlider(in: sub) { return found }
        }
        return nil
    }

    // MARK: - Fixture

    /// A real H.264 clip of a known length, generated rather than checked
    /// in. Duplicated from `SkiVideoCoreTests/RealVideoFixture.swift` — see
    /// that file's doc comment for why a zero-byte fixture cannot stand in
    /// for this: `AVPlayerItem.duration` on an empty file is NaN, and
    /// `ComparisonModel` never publishes a non-finite duration.
    private func makeRealVideoFile(
        in directory: URL,
        name: String,
        seconds: Double,
        fps: Int32 = 10
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 90,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: 160,
                kCVPixelBufferHeightKey as String: 90,
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
