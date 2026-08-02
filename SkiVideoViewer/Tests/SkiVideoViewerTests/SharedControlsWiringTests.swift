import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import SkiVideoCore
@testable import SkiVideoViewer

/// Proves the shared controls — and their callers — are actually wired to
/// their closures and to the model, not merely compiling against them.
///
/// `TransportControls` and `TimelineScrubber` are pure view types — values
/// and closures, no model — so nothing forces a caller's closure to run when
/// the AppKit control underneath actually fires. `ComparisonControlBarLayoutTests`
/// proves the bar occupies the right frame; it says nothing about whether
/// tapping a button does anything. Every other test that touches
/// `TransportAction` or `ComparisonScrubber` drives `ComparisonModel`
/// directly and never renders the view at all.
///
/// The wiring is two links, not one, and each is tested at the layer that
/// can break it: `TransportControls`/`TimelineScrubber` proves the shared
/// control invokes the closure it is given; `ComparisonControlBar`/
/// `ComparisonScrubber` proves the closure that caller *hands in* actually
/// reaches `ComparisonModel`. A control nothing calls and a caller that
/// never reaches its model are two distinct failures, and a test that only
/// covers the first link cannot see the second — confirmed directly:
/// `model.applyTransport(action)` replaced with `_ = action` in
/// `ComparisonControlBar`, and `ComparisonScrubber`'s `onScrub` replaced with
/// `{ _ in }`, both survived the full suite before the tests below existed.
///
/// These tests synthesize real interaction with the actual `NSControl`
/// SwiftUI renders, found by walking the `NSHostingView`'s subviews exactly
/// as `ComparisonControlBarLayoutTests` walks it for frames — headless, no
/// app launched, nothing on screen. Confirmed empirically before writing
/// this, by dumping the hosted view tree: the six transport buttons and the
/// anchor render as `NSButton`, but with `target`/`action` nil —
/// `performClick(nil)` reaches the SwiftUI action closure regardless, and
/// `sendAction(_:to:)` does not. The slider is the opposite: it carries a
/// real, non-nil `target`/`action` (a SwiftUI `Coordinator`), so
/// `sendAction(_:to:)` is what reaches it, and its `doubleValue` is always
/// normalized to `0...1` regardless of the real `duration` passed to
/// `Slider`'s `in:` range.
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

    /// A separate concern from the test above, and it does not kill the same
    /// mutant: with `perform` stubbed to `{}`, `received` is empty whether or
    /// not the transport is enabled, so this test alone proves nothing about
    /// that mutation. What it does prove is the other half of disabling —
    /// that a control which *reads* as disabled (to a user, and to the iPad
    /// UI test that asserts `isEnabled == false` before any clip is loaded)
    /// cannot still act on a click that reaches it — and, with the button
    /// count assertion below, that `ForEach` actually renders all six.
    func testADisabledTransportDoesNotInvokePerform() {
        var received: [TransportAction] = []
        let host = NSHostingView(
            rootView: TransportControls(isEnabled: false) { received.append($0) }
                .frame(width: 400, height: 60)
        )
        host.layoutSubtreeIfNeeded()

        let buttons = transportButtons(in: host)
        XCTAssertEqual(buttons.count, 6, "TransportControls alone must render exactly its six buttons")
        for button in buttons {
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

    /// Kills the mutation of stubbing either `onScrub(newValue)` (the live
    /// `set`) or `onScrub(scrubTime)` (the `onEditingChanged` release) inside
    /// `TimelineScrubber` itself. Neither the M9 test above nor
    /// `ComparisonControlBarLayoutTests` renders a drag on the slider — the
    /// first only checks `isEnabled`, and the second never touches the
    /// scrubber at all.
    ///
    /// This drives the real `NSSlider` SwiftUI renders directly, rather than
    /// through `ComparisonScrubber`, so it isolates `TimelineScrubber`'s own
    /// wiring from whatever a given caller does with the value —
    /// `testDraggingTheComparisonScrubberMovesTheRealModel` below is what
    /// proves that second link for `ComparisonScrubber` specifically. Two
    /// things were confirmed empirically before writing this: the slider (a
    /// real `NSSlider`, unlike the buttons above) carries a genuine
    /// `target`/`action`, so `sendAction(_:to:)` reaches it; and
    /// `NSSlider.doubleValue` here is always normalized to `0...1`
    /// regardless of the `in:` range passed to `Slider` — SwiftUI's
    /// coordinator maps that fraction onto the real range when it calls the
    /// binding, which is why `0.7` below is read back as `7` against a `10`
    /// second duration, not `0.7` itself.
    func testDraggingTheTimelineScrubberInvokesOnScrubWithTheDraggedValue() throws {
        var received: [Double] = []
        let host = NSHostingView(
            rootView: TimelineScrubber(time: 0, duration: 10, onScrub: { received.append($0) })
                .frame(width: 400, height: 60)
        )
        host.layoutSubtreeIfNeeded()

        let slider = try XCTUnwrap(nsSlider(in: host), "expected to find the scrubber's NSSlider")
        slider.doubleValue = 0.7
        _ = slider.sendAction(slider.action, to: slider.target)

        XCTAssertFalse(received.isEmpty, "dragging the slider must invoke onScrub")
        XCTAssertEqual(
            received.last ?? -1, 7, accuracy: 0.5,
            "dragging to 70% of a 10s duration must report ~7s, not the mutant's untouched value"
        )
    }

    /// Kills the mutation of replacing `ComparisonScrubber`'s
    /// `onScrub: { model.scrub(side, to: $0) }` with `{ _ in }`. The test
    /// above proves `TimelineScrubber` invokes whatever closure it is given;
    /// this proves `ComparisonScrubber` gives it one that actually reaches
    /// the model — the second link the refactor split off the first, which
    /// nothing else in the suite drives end to end (`ComparisonModelTests`
    /// and `ComparisonScrubbedSideTests` call `model.scrub` directly,
    /// bypassing both views).
    ///
    /// Requires the same real, decodable fixture as the M9 test — an empty
    /// one leaves the slider disabled, and a disabled control is not what a
    /// user's drag reaches. Reads `leftPlayer.currentTime()` on a poll rather
    /// than immediately: unlike the zero-byte fixtures every other test in
    /// the repo seeks against (which resolve synchronously, with nothing to
    /// actually decode), a seek on a real, decodable item is genuinely
    /// asynchronous, and reading `currentTime()` right after `sendAction`
    /// returned NaN-adjacent 0 instead of the drag target on the first
    /// attempt — confirmed empirically before adding the poll.
    func testDraggingTheComparisonScrubberMovesTheRealModel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = try makeRealVideoFile(in: root, name: "left.mov", seconds: 4)

        let model = ComparisonModel()
        model.load(url, side: .left)

        let durationDeadline = Date().addingTimeInterval(10)
        while model.leftDuration <= 0, Date() < durationDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThan(model.leftDuration, 0, "precondition: the fixture's duration must actually be known")

        let host = NSHostingView(rootView: ComparisonScrubber(model: model).frame(width: 400, height: 60))
        host.layoutSubtreeIfNeeded()

        let slider = try XCTUnwrap(nsSlider(in: host), "expected to find the scrubber's NSSlider")
        XCTAssertTrue(slider.isEnabled, "precondition: a real duration must enable the slider")
        slider.doubleValue = 0.5
        _ = slider.sendAction(slider.action, to: slider.target)

        let expected = model.leftDuration * 0.5
        let seekDeadline = Date().addingTimeInterval(5)
        while model.leftPlayer.currentTime().seconds < expected - 0.5, Date() < seekDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(
            model.leftPlayer.currentTime().seconds, expected, accuracy: 0.5,
            "dragging the scrubber to the midpoint must seek the model's player there"
        )
    }

    /// Kills the mutation of replacing `model.applyTransport(action)` with
    /// `_ = action` inside `ComparisonControlBar.transport`. Everything else
    /// that touches `TransportAction` either calls `applyTransport` on the
    /// model directly (bypassing the view) or renders `TransportControls`
    /// alone (bypassing `ComparisonControlBar`'s own closure) — the two
    /// tests at the top of this file kill the mutation inside
    /// `TransportControls.button`, but a caller that never reaches its
    /// model is a second, distinct failure `TransportControls`'s own tests
    /// cannot see.
    ///
    /// Loading two empty fixtures is enough here — `hasTwoVideos` only needs
    /// a non-nil `currentItem` on each player, and `applyTransport(.playPause)`
    /// sets `AVPlayer.rate` directly, which does not require a decodable item
    /// to observe.
    ///
    /// The button index is not assumed: confirmed empirically that
    /// `ComparisonControlBar` renders exactly seven `NSButton`s — the six
    /// transport buttons in `TransportAction.allCases` order, then the
    /// anchor — by loading two clips, clicking the button at
    /// `TransportAction.allCases.firstIndex(of: .playPause)` and observing
    /// `leftPlayer.rate` actually become `1`.
    func testClickingPlayPauseInComparisonControlBarMovesTheModel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let model = ComparisonModel()
        model.load(try makeEmptyVideoFile(in: root, name: "left.mp4"), side: .left)
        model.load(try makeEmptyVideoFile(in: root, name: "right.mp4"), side: .right)
        model.target = .left
        XCTAssertTrue(model.hasTwoVideos, "precondition: two loaded clips must enable the transport")
        XCTAssertEqual(model.leftPlayer.rate, 0, "precondition: nothing is playing yet")

        // Wide enough that `ViewThatFits` picks the single-row branch — see
        // `ComparisonControlBarLayoutTests`, which pins 881pt as one row. The
        // dedicated `transport` property is shared by both branches, so
        // either would do; this just avoids depending on which one renders.
        let host = NSHostingView(rootView: ComparisonControlBar(model: model).frame(width: 1000, height: 200))
        host.layoutSubtreeIfNeeded()

        let buttons = transportButtons(in: host)
        XCTAssertEqual(buttons.count, 7, "precondition: the six transport buttons plus the anchor")

        let playPauseIndex = try XCTUnwrap(TransportAction.allCases.firstIndex(of: .playPause))
        buttons[playPauseIndex].performClick(nil)

        XCTAssertEqual(
            model.leftPlayer.rate, 1,
            "clicking Play/Pause through the real control bar must reach the model"
        )
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

    /// The same control as `scrubberSlider` above, typed as `NSSlider`
    /// rather than matched by class name: dragging needs `doubleValue` and
    /// `sendAction(_:to:)`, both declared on `NSSlider`/`NSControl`, and a
    /// plain `as? NSSlider` downcast on `CustomMarkedSlider` succeeds — it
    /// really is one, confirmed empirically. `scrubberSlider` is left as it
    /// was reviewed: matching by name there is only ever used for
    /// `isEnabled`, which `NSControl` already provides.
    private func nsSlider(in view: NSView) -> NSSlider? {
        if let slider = view as? NSSlider { return slider }
        for sub in view.subviews {
            if let found = nsSlider(in: sub) { return found }
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

    /// `AVPlayerItem` accepts any URL and reports failure asynchronously, so
    /// an empty file is enough to give a player a `currentItem` — all
    /// `hasTwoVideos` requires, and enough for `AVPlayer.rate` to change on
    /// `playImmediately(atRate:)`, which does not need a decodable item.
    /// Matches `ComparisonModelTests.makeVideoFile`; duplicated for the same
    /// cross-target reason as `makeRealVideoFile` above.
    private func makeEmptyVideoFile(in directory: URL, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }
}
