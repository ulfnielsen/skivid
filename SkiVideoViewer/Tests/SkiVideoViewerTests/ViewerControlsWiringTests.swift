import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import SkiVideoCore
@testable import SkiVideoViewer

/// Proves `ViewerControlBar` and the scrubber wired into `ContentView.detail`
/// actually reach `ViewerModel`, not merely compile against it.
///
/// `SharedControlsWiringTests` established why this file has to exist:
/// `TransportControls` and `TimelineScrubber` are pure views — values and
/// closures, no model — so nothing forces a *caller's* closure to run when
/// the real AppKit control underneath actually fires. That file is the first
/// caller of the seam (the comparison screen); `ViewerControlBar` and the
/// inline `onScrub` in `ContentView.detail` are the second. Confirmed
/// directly, the same way that file confirms its own claim: stubbing
/// `model.applyTransport(action)` with `_ = action` in
/// `ViewerControlBar.transport`, `model.changeVideo(by: offset)` with
/// `_ = offset` in `ViewerControlBar.stepButton`, and
/// `model.scrub(to: $0)` with `{ _ in }` in `ContentView.detail` each
/// compile cleanly and survive the rest of the suite: every other test that
/// touches `TransportAction`, `changeVideo` or `scrub` either drives
/// `ViewerModel` directly (`ViewerTransportTests`, `ViewerModelIntentTests`)
/// or renders `TransportControls`/`TimelineScrubber` alone
/// (`SharedControlsWiringTests`), bypassing these two callers entirely.
@MainActor
final class ViewerControlsWiringTests: XCTestCase {
    private var temporaryDirectory: URL?

    override func setUp() {
        super.setUp()
        // Matches `SharedControlsWiringTests`: `NSHostingView` needs the
        // shared application to exist before it lays anything out.
        // `.prohibited` keeps it out of the Dock and off the screen.
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    override func tearDown() {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        super.tearDown()
    }

    // MARK: - ViewerControlBar

    /// The bar's buttons, in the order `transportButtons` walks them: the six
    /// `TransportControls` buttons, then `clipStepping`'s Previous and Next.
    /// Named rather than spelled `8` and `TransportAction.allCases.count` at
    /// each use site — the lookup below is positional, so what each index
    /// *means* is the thing worth writing down.
    ///
    /// Task 4 briefly had three `ZoomControl` buttons sitting between the two
    /// groups, which broke every index here. The zoom control now lives on the
    /// video instead of in the bar, so the counts are back to what they were —
    /// but the naming survived that round and is kept.
    ///
    /// Draw and Show drawings sit between the transport and clip stepping, so
    /// they add two buttons and push Previous/Next clip two places along.
    private static let barButtonCount = TransportAction.allCases.count + 4
    private static let drawIndex = TransportAction.allCases.count
    private static let showDrawingsIndex = TransportAction.allCases.count + 1
    private static let previousClipIndex = TransportAction.allCases.count + 2

    /// Kills the mutation of replacing `model.applyTransport(action)` with
    /// `_ = action` inside `ViewerControlBar.transport`. An empty fixture is
    /// enough: `applyTransport(.playPause)` sets `AVPlayer.rate` directly,
    /// which does not require a decodable item to observe — the same
    /// reasoning `SharedControlsWiringTests` uses for its own play/pause
    /// test.
    func testClickingPlayPauseInViewerControlBarMovesTheModel() throws {
        let model = try makeModel(videoNames: ["run1.mp4"])
        XCTAssertEqual(model.player.rate, 0, "precondition: nothing is playing yet")

        let host = NSHostingView(rootView: ViewerControlBar(model: model).frame(width: 600, height: 200))
        host.layoutSubtreeIfNeeded()

        let buttons = transportButtons(in: host)
        XCTAssertEqual(
            buttons.count, Self.barButtonCount,
            "precondition: six transport buttons, Draw, Show drawings and Previous/Next clip"
        )

        let playPauseIndex = try XCTUnwrap(TransportAction.allCases.firstIndex(of: .playPause))
        buttons[playPauseIndex].performClick(nil)

        XCTAssertEqual(
            model.player.rate, 1,
            "clicking Play/Pause through the real control bar must reach the model"
        )
    }

    /// Kills the mutation of replacing `model.changeVideo(by: offset)` with
    /// `_ = offset`, or of the `by: 1` literal itself, inside
    /// `ViewerControlBar.stepButton`. Three clips, not two: with only two,
    /// stepping `+1` and `-1` from index 0 land on the same clip, so a test
    /// that only checked "the clip changed" could not tell a sign flip on
    /// the `Next` button's offset from a correct one.
    ///
    /// **Buttons are located by the named offsets above, not a bare literal
    /// `7`, but this is still positional, not label-based.** Review
    /// asked for lookup by `accessibilityLabel`/title, matching how
    /// `SharedControlsWiringTests` locates `playPauseIndex` — and how
    /// `ComparisonControlBar`'s anchor button is found by trailing position
    /// after the transport. I tried the AppKit-equivalent technique
    /// extensively before falling back to position, and it does not work in
    /// this harness: after a real (non-`.prohibited`-only) `NSWindow`,
    /// `layoutSubtreeIfNeeded()`, `displayIfNeeded()` and a run-loop spin,
    /// every one of `NSButton.toolTip`, `.accessibilityLabel()`, the legacy
    /// `.accessibilityAttributeValue(.description/.title/.help)`, and
    /// `host.accessibilityChildren()` come back nil or empty on every
    /// button — confirmed by walking the entire AppKit subview tree and
    /// finding nothing non-empty anywhere. Cross-process introspection
    /// through the real `AXUIElement` API (`AXUIElementCreateApplication`
    /// against this process's own pid) returns `kAXErrorNotImplemented`
    /// (-25208): `AXIsProcessTrusted()` is `true` here, but the `swift test`
    /// host process itself never registers as an accessible application, so
    /// there is no accessibility tree to query — a different failure mode
    /// than the tap gesture's (that one was fixed by adding a real
    /// `NSWindow`; this one needs the process itself to be a real app, which
    /// `swift test` cannot provide). Reading `NSButton.isEnabled` directly
    /// (below) works because that is a plain AppKit property, not routed
    /// through Accessibility. Pinning "Previous clip"/"Next clip" text to
    /// its button is Task 4's job, on the iPad XCUITest runner, whose
    /// `XCUIElement` queries read a UIKit accessibility tree that is
    /// actually populated.
    ///
    /// `transportButtons` walks the AppKit tree in declaration order — the
    /// six transport buttons first, then `clipStepping`'s Previous, then
    /// Next — confirmed the same way `SharedControlsWiringTests` confirms
    /// `ComparisonControlBar`'s seven-button order.
    func testClickingNextClipInViewerControlBarMovesTheModel() throws {
        let model = try makeModel(videoNames: ["run1.mp4", "run2.mp4", "run3.mp4"])
        XCTAssertEqual(model.currentVideo?.lastPathComponent, "run1.mp4", "precondition")

        let host = NSHostingView(rootView: ViewerControlBar(model: model).frame(width: 600, height: 200))
        host.layoutSubtreeIfNeeded()

        let buttons = transportButtons(in: host)
        XCTAssertEqual(
            buttons.count, Self.barButtonCount,
            "precondition: six transport buttons, Draw, Show drawings and Previous/Next clip"
        )

        buttons[Self.previousClipIndex + 1].performClick(nil)

        XCTAssertEqual(
            model.currentVideo?.lastPathComponent, "run2.mp4",
            "clicking Next clip through the real control bar must advance the model"
        )
    }

    /// The other direction of the test above, killing the same class of
    /// mutation on the `by: -1` literal specifically — see that test's
    /// comment for why two clips cannot distinguish the two buttons from
    /// each other, and for why lookup here is positional rather than by
    /// label.
    func testClickingPreviousClipInViewerControlBarMovesTheModel() throws {
        let model = try makeModel(videoNames: ["run1.mp4", "run2.mp4", "run3.mp4"])
        XCTAssertEqual(model.currentVideo?.lastPathComponent, "run1.mp4", "precondition")

        let host = NSHostingView(rootView: ViewerControlBar(model: model).frame(width: 600, height: 200))
        host.layoutSubtreeIfNeeded()

        let buttons = transportButtons(in: host)
        XCTAssertEqual(
            buttons.count, Self.barButtonCount,
            "precondition: six transport buttons, Draw, Show drawings and Previous/Next clip"
        )

        buttons[Self.previousClipIndex].performClick(nil)

        XCTAssertEqual(
            model.currentVideo?.lastPathComponent, "run3.mp4",
            "clicking Previous clip through the real control bar must retreat the model"
        )
    }

    /// A disabled bar reads that way to a user, and to the iPad UI tests
    /// asserting `isEnabled == false` before any clip loads — matches
    /// `SharedControlsWiringTests.testADisabledTransportDoesNotInvokePerform`,
    /// extended to the clip-stepping buttons `TransportControls` does not
    /// own.
    ///
    /// Asserts the real `NSButton.isEnabled`, not a model-side effect.
    /// Review caught that the model-side version of this test — clicking all
    /// eight buttons and asserting `player.rate == 0` /
    /// `currentVideo == nil` — cannot fail: `ViewerModel.togglePlayback`
    /// already guards on `currentVideo != nil` and `changeVideo(by:)` already
    /// guards on `currentAthlete`, so those two assertions hold whether or
    /// not `ViewerControlBar` disables anything at all. Confirmed by
    /// review's own measurement: removing both `isEnabled`/`.disabled` gates
    /// left the whole suite green. `NSButton.isEnabled` is a plain AppKit
    /// property (unlike the accessibility properties above, it does not
    /// depend on this process having a working Accessibility tree), and it
    /// is also the property Task 4's iPad tests read.
    func testADisabledViewerControlBarDoesNotEnableAnyButton() throws {
        let model = ViewerModel(
            input: AppKitInputSource(),
            folderPicker: AppKitFolderPicker(),
            oauthPresenter: StubOAuthPresenter()
        )
        XCTAssertNil(model.currentPlaybackURL, "precondition: nothing is loaded")

        let host = NSHostingView(rootView: ViewerControlBar(model: model).frame(width: 600, height: 200))
        host.layoutSubtreeIfNeeded()

        let buttons = transportButtons(in: host)
        XCTAssertEqual(
            buttons.count, Self.barButtonCount,
            "precondition: six transport buttons, Draw, Show drawings and Previous/Next clip"
        )

        XCTAssertFalse(buttons[Self.drawIndex].isEnabled, "Draw needs a clip, so it is disabled with none loaded")
        for (index, button) in buttons.enumerated() {
            // Show drawings is a preference, not an action on a clip, so it
            // stays enabled; Draw needs a clip and must be disabled.
            if index == Self.showDrawingsIndex { continue }
            XCTAssertFalse(button.isEnabled, "button at index \(index) must read as disabled with nothing loaded")
        }

        // Belt and suspenders: also confirm a click through a disabled
        // button genuinely does nothing, now that `isEnabled` itself is
        // pinned above.
        // Not Show drawings: it is enabled, and clicking it would flip the
        // real `ShowDrawings` default for whoever runs the tests.
        for (index, button) in buttons.enumerated() where index != Self.showDrawingsIndex {
            button.performClick(nil)
        }
        XCTAssertEqual(model.player.rate, 0, "a disabled transport must not invoke perform")
        XCTAssertNil(model.currentVideo, "a disabled clip-stepping control must not invoke changeVideo")
    }

    /// Kills the mutation of replacing `ViewerPane`'s
    /// `.onTapGesture { model.applyTransport(.playPause) }` with
    /// `.onTapGesture { }`. This is the gap disclosed as untestable in the
    /// first pass of this file: `.onTapGesture` installs no discoverable
    /// `NSGestureRecognizer` on any view in the hosted tree (confirmed by
    /// dumping `gestureRecognizers` on every subview — always empty), which
    /// is what made `performClick`/`sendAction`, the technique the rest of
    /// this file uses, inapplicable here.
    ///
    /// The missing ingredient was a real `NSWindow`, not the event. Calling
    /// `view.mouseDown(with:)` directly on the hosted view — what a first
    /// attempt reaches for — leaves `rate` at 0: SwiftUI's tap-gesture
    /// recognition lives in the window's event-dispatch path, not in the
    /// view's own `mouseDown`/`mouseUp` overrides. Routing the same
    /// synthetic events through `window.sendEvent(_:)` against a real
    /// (still off-screen, `.prohibited`-policy) `NSWindow` reaches it.
    ///
    /// **macOS only**, and it stays that way now for a different reason than
    /// when it was written. The pane used to render through an AVKit player
    /// view whose UIKit gesture arbitration this AppKit-event technique said
    /// nothing about; both platforms now share `SinglePlayerView`, so the
    /// *view* is no longer the difference. The technique still is: sending
    /// synthetic `NSEvent`s through an `NSWindow` is an AppKit route with no
    /// UIKit equivalent here, and UIKit's own hit-testing has already been
    /// measured to behave differently from AppKit's on this very pane — see
    /// `testTappingWhereTheStatusChipSitsStillTogglesPlayback` below. Tapping
    /// the video on iPad therefore stays an XCUITest step.
    func testTappingTheViewerPaneTogglesPlaybackOnMacOS() throws {
        let model = try makeModel(videoNames: ["run1.mp4"])
        XCTAssertEqual(model.player.rate, 0, "precondition: nothing is playing yet")

        let host = NSHostingView(
            rootView: ViewerPane(model: model, athleteName: "Idun").frame(width: 400, height: 300)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        // `.orderFront`, not `.makeKeyAndOrderFront`: the click technique
        // below only needs the window in the window server, not key/focused
        // — matching `ComparisonLayoutMeasurementTests.chipFrame`'s window,
        // which never becomes key either.
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()

        let point = CGPoint(x: 200, y: 150)
        window.sendEvent(mouseEvent(.leftMouseDown, at: point, windowNumber: window.windowNumber))
        window.sendEvent(mouseEvent(.leftMouseUp, at: point, windowNumber: window.windowNumber))

        XCTAssertEqual(
            model.player.rate, 1,
            "tapping the viewer pane through a real window must toggle playback"
        )
    }

    /// Kills the mutation of deleting `.allowsHitTesting(false)` from
    /// `ViewerPane`'s status chip. The chip floats over the video in the
    /// top-trailing corner; hit-testable, it eats the play/pause tap meant for
    /// the video underneath it, and nothing else in the repo notices — the
    /// screenshot is identical either way and the test above taps the *centre*
    /// of the pane, well clear of the chip.
    ///
    /// **This has to live on macOS, which was not obvious.** Task 4 first put
    /// it in the iPad UI suite, tapping the chip's own accessibility frame with
    /// XCUITest, and it passed with the modifier deleted: measured on an iPad
    /// Pro 11-inch (M5), UIKit routes the tap straight past the overlay to the
    /// gesture below whether or not the chip claims hits, so on iPadOS the
    /// modifier has no observable effect at all. AppKit does not — measured
    /// here, the tap leaves `rate` at 0 without it and sets it to 1 with it.
    /// The iPad test is still worth having (it is the only coverage of
    /// tap-to-play on iPadOS at all), but it is this one that kills the
    /// mutation.
    ///
    /// Same real-`NSWindow` technique as the test above; see its comment for
    /// why `view.mouseDown(with:)` does not work.
    func testTappingWhereTheStatusChipSitsStillTogglesPlayback() throws {
        let model = try makeModel(videoNames: ["run1.mp4"])
        XCTAssertEqual(model.player.rate, 0, "precondition: nothing is playing yet")

        let width: CGFloat = 800
        let height: CGFloat = 400
        let host = NSHostingView(
            rootView: ViewerPane(model: model, athleteName: "Idun").frame(width: width, height: height)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()

        // Inside the pill: the chip is top-trailing with 12pt of outer padding,
        // and its `Text` is capped at 320pt with 10pt of horizontal and 5pt of
        // vertical padding around it, so this lands roughly in the middle of a
        // 340×24 capsule. AppKit's origin is bottom-left, hence the subtraction
        // from `height`.
        let point = CGPoint(x: width - 12 - 170, y: height - 12 - 15)
        window.sendEvent(mouseEvent(.leftMouseDown, at: point, windowNumber: window.windowNumber))
        window.sendEvent(mouseEvent(.leftMouseUp, at: point, windowNumber: window.windowNumber))

        XCTAssertEqual(
            model.player.rate, 1,
            """
            the status chip must not swallow the play/pause tap: a click at \
            \(point), inside the chip's capsule, left the player stopped
            """
        )
    }

    // MARK: - The scrubber wired into ContentView.detail

    /// Kills the mutation of replacing `ContentView.detail`'s
    /// `onScrub: { model.scrub(to: $0) }` with `{ _ in }`. Unlike the
    /// comparison screen, the viewer never wraps this in a dedicated caller
    /// view like `ComparisonScrubber` — the closure is inline in
    /// `ContentView.detail` — so proving it reaches the model means
    /// rendering `ContentView` itself, not a stand-in. `initialDirectory:
    /// nil` keeps `ContentView`'s own `.onAppear { model.start(...) }` from
    /// re-driving the directory this test already opened: `start` only acts
    /// when `directory == nil`, which is false by the time `ContentView` is
    /// constructed here.
    ///
    /// Requires a real, decodable clip: `TimelineScrubber` disables its
    /// slider whenever `duration <= 0`, and a zero-byte fixture never
    /// publishes a duration at all (`ViewerModel.observeDuration` guards on
    /// `isFinite`).
    func testDraggingTheViewerTimelineInContentViewMovesTheRealModel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        temporaryDirectory = root
        let athlete = root.appendingPathComponent("Idun", isDirectory: true)
        _ = try makeRealVideoFile(in: athlete, name: "run1.mov", seconds: 4)

        let model = ViewerModel(
            input: AppKitInputSource(),
            folderPicker: AppKitFolderPicker(),
            oauthPresenter: StubOAuthPresenter()
        )
        model.openDirectory(root)
        // Compared by last path component, not full `URL` equality: the
        // fixture is built from `FileManager.default.temporaryDirectory`
        // (`/var/...`), but `VideoLibrary.scan`'s enumerator returns the
        // `/private/var/...` form of the same path — confirmed empirically
        // when a strict `URL` equality assertion failed here.
        XCTAssertEqual(
            model.currentPlaybackURL?.lastPathComponent, "run1.mov",
            "precondition: the clip must actually be loaded"
        )

        let durationDeadline = Date().addingTimeInterval(10)
        while model.duration <= 0, Date() < durationDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThan(model.duration, 0, "precondition: the fixture's duration must actually be known")

        let host = NSHostingView(
            rootView: ContentView(
                model: model,
                initialDirectory: nil,
                secondaryScreens: NoSecondaryScreens()
            )
            .frame(width: 1400, height: 900)
        )
        host.layoutSubtreeIfNeeded()

        let slider = try viewerTimelineSlider(in: host)
        XCTAssertTrue(slider.isEnabled, "precondition: a real duration must enable the scrubber")
        slider.doubleValue = 0.5
        _ = slider.sendAction(slider.action, to: slider.target)

        let expected = model.duration * 0.5
        let seekDeadline = Date().addingTimeInterval(5)
        while model.player.currentTime().seconds < expected - 0.5, Date() < seekDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(
            model.player.currentTime().seconds, expected, accuracy: 0.5,
            "dragging the viewer timeline to the midpoint must seek the model's player there"
        )
    }

    // MARK: - View-tree walking

    /// Duplicated from `SharedControlsWiringTests`: the six transport
    /// buttons and the viewer's two clip-stepping buttons all render as a
    /// real `NSButton` subclass, walked by AppKit subview identity rather
    /// than by accessibility identifier — this is the tree `NSHostingView`
    /// builds, not the accessibility tree the iPad UI tests read.
    private func transportButtons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        if let button = view as? NSButton { found.append(button) }
        for sub in view.subviews { found.append(contentsOf: transportButtons(in: sub)) }
        return found
    }

    /// **A hosted `ContentView` contains two sliders, and the first one the
    /// tree walk reaches is the wrong one.** `ViewerPane`'s zoom chip is
    /// declared before `TimelineScrubber` in `detail`'s `VStack`, so a
    /// first-match walk returns the zoom slider — measured, and it is what
    /// broke `testDraggingTheViewerTimelineInContentViewMovesTheRealModel`
    /// when the chip landed: the seek assertion failed at 0.0 because the
    /// drag had gone to the zoom instead.
    ///
    /// Width is the discriminator, because the obvious ones do not work here.
    /// Measured in a 1400pt host: the zoom slider is **80.0pt** wide (it is
    /// capped inside a 220pt chip over the video) and the viewer timeline is
    /// **1108.0pt** (it spans the detail column). Both report `minValue 0.0,
    /// maxValue 1.0`, so value range cannot tell them apart, and
    /// `accessibilityIdentifier()` comes back **empty on both** despite
    /// `ContentView` setting one on the scrubber — the same dead
    /// Accessibility tree this file documents at length above.
    ///
    /// Asserting the count first is what keeps this honest: a third slider
    /// appearing anywhere in the viewer should stop this test rather than
    /// silently re-point it.
    private func viewerTimelineSlider(in view: NSView) throws -> NSSlider {
        let sliders = allSliders(in: view)
        XCTAssertEqual(
            sliders.count, 2,
            "expected exactly two sliders in a hosted ContentView: the zoom chip's and the viewer timeline's"
        )
        return try XCTUnwrap(
            sliders.max(by: { $0.bounds.width < $1.bounds.width }),
            "expected to find the viewer timeline's real NSSlider in the hosted ContentView"
        )
    }

    /// Duplicated from `SharedControlsWiringTests`: the slider renders
    /// several layers deep as a private AppKit class, but a plain
    /// `as? NSSlider` downcast on it succeeds, confirmed empirically there.
    private func allSliders(in view: NSView) -> [NSSlider] {
        var found: [NSSlider] = []
        if let slider = view as? NSSlider { found.append(slider) }
        for sub in view.subviews { found.append(contentsOf: allSliders(in: sub)) }
        return found
    }

    /// A synthetic left-click event at a point in window coordinates,
    /// dispatched through `window.sendEvent(_:)` rather than called on a
    /// view directly — see `testTappingTheViewerPaneTogglesPlaybackOnMacOS`
    /// for why the window is the load-bearing part.
    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, windowNumber: Int) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    // MARK: - Fixtures

    /// Empty files are enough for the transport and clip-stepping tests:
    /// `VideoLibrary.scan` only inspects extensions, `changeVideo` only
    /// needs `athlete.videos` populated, and `applyTransport(.playPause)`
    /// sets `AVPlayer.rate` directly on a player that merely has a
    /// `currentItem`, which `AVPlayerItem(url:)` gives it regardless of
    /// whether the file decodes.
    private func makeModel(videoNames: [String]) throws -> ViewerModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        temporaryDirectory = root
        let athlete = root.appendingPathComponent("Idun", isDirectory: true)
        try FileManager.default.createDirectory(at: athlete, withIntermediateDirectories: true)
        for name in videoNames {
            FileManager.default.createFile(
                atPath: athlete.appendingPathComponent(name).path,
                contents: Data()
            )
        }

        let model = ViewerModel(
            input: AppKitInputSource(),
            folderPicker: AppKitFolderPicker(),
            oauthPresenter: StubOAuthPresenter()
        )
        model.openDirectory(root)
        return model
    }

    /// A real H.264 clip of a known length, generated rather than checked
    /// in. Duplicated from `SkiVideoCoreTests/RealVideoFixture.swift` for
    /// the same cross-target reason `SharedControlsWiringTests` duplicates
    /// it: that helper is an `XCTestCase` extension scoped to the
    /// `SkiVideoCoreTests` target, which `SkiVideoViewerTests` does not
    /// depend on.
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

/// A `SecondaryScreenPresenter` that offers neither screen and is never
/// expected to be called: this file only renders `ContentView` to reach the
/// real scrubber wired into `detail`, never taps the toolbar's Compare or
/// Sort buttons.
@MainActor
private final class NoSecondaryScreens: SecondaryScreenPresenter {
    let canPresentComparison = false
    let canPresentSorting = false
    let screensCoverTheViewer = false
    let hasOpenWindow = false

    func presentComparison(
        initialLeftVideo: URL?,
        openLibrary: [ComparisonAthleteChoice],
        prepare: ClipPreparer,
        onClose: @escaping () -> Void
    ) {
        XCTFail("presentComparison must not be called by this test")
    }

    func presentSorting(
        destination: UploadLibraryChoice,
        openResizedLibrary: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    ) {
        XCTFail("presentSorting must not be called by this test")
    }
}
