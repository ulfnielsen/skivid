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
        XCTAssertEqual(buttons.count, 8, "precondition: six transport buttons plus Previous/Next clip")

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
    /// the `Next` button's offset from a correct one. `transportButtons`
    /// walks the tree in declaration order — the six transport buttons
    /// first, then `clipStepping`'s Previous (index 6) and Next (index 7) —
    /// confirmed the same way `SharedControlsWiringTests` confirms
    /// `ComparisonControlBar`'s seven-button order.
    func testClickingNextClipInViewerControlBarMovesTheModel() throws {
        let model = try makeModel(videoNames: ["run1.mp4", "run2.mp4", "run3.mp4"])
        XCTAssertEqual(model.currentVideo?.lastPathComponent, "run1.mp4", "precondition")

        let host = NSHostingView(rootView: ViewerControlBar(model: model).frame(width: 600, height: 200))
        host.layoutSubtreeIfNeeded()

        let buttons = transportButtons(in: host)
        XCTAssertEqual(buttons.count, 8, "precondition: six transport buttons plus Previous/Next clip")

        buttons[7].performClick(nil)

        XCTAssertEqual(
            model.currentVideo?.lastPathComponent, "run2.mp4",
            "clicking Next clip through the real control bar must advance the model"
        )
    }

    /// The other direction of the test above, killing the same class of
    /// mutation on the `by: -1` literal specifically — see that test's
    /// comment for why two clips cannot distinguish the two buttons from
    /// each other.
    func testClickingPreviousClipInViewerControlBarMovesTheModel() throws {
        let model = try makeModel(videoNames: ["run1.mp4", "run2.mp4", "run3.mp4"])
        XCTAssertEqual(model.currentVideo?.lastPathComponent, "run1.mp4", "precondition")

        let host = NSHostingView(rootView: ViewerControlBar(model: model).frame(width: 600, height: 200))
        host.layoutSubtreeIfNeeded()

        let buttons = transportButtons(in: host)
        XCTAssertEqual(buttons.count, 8, "precondition: six transport buttons plus Previous/Next clip")

        buttons[6].performClick(nil)

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
    func testADisabledViewerControlBarDoesNotInvokeAnyCallback() throws {
        let model = ViewerModel(
            input: AppKitInputSource(),
            folderPicker: AppKitFolderPicker(),
            oauthPresenter: StubOAuthPresenter()
        )
        XCTAssertNil(model.currentPlaybackURL, "precondition: nothing is loaded")

        let host = NSHostingView(rootView: ViewerControlBar(model: model).frame(width: 600, height: 200))
        host.layoutSubtreeIfNeeded()

        let buttons = transportButtons(in: host)
        XCTAssertEqual(buttons.count, 8, "precondition: six transport buttons plus Previous/Next clip")
        for button in buttons {
            button.performClick(nil)
        }

        XCTAssertEqual(model.player.rate, 0, "a disabled transport must not invoke perform")
        XCTAssertNil(model.currentVideo, "a disabled clip-stepping control must not invoke changeVideo")
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

        let slider = try XCTUnwrap(
            nsSlider(in: host),
            "expected to find the viewer timeline's real NSSlider in the hosted ContentView"
        )
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

    /// Duplicated from `SharedControlsWiringTests`: the slider renders
    /// several layers deep as a private AppKit class, but a plain
    /// `as? NSSlider` downcast on it succeeds, confirmed empirically there.
    private func nsSlider(in view: NSView) -> NSSlider? {
        if let slider = view as? NSSlider { return slider }
        for sub in view.subviews {
            if let found = nsSlider(in: sub) { return found }
        }
        return nil
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

    func presentComparison(
        initialLeftVideo: URL?,
        openLibrary: [ComparisonAthleteChoice],
        onClose: @escaping () -> Void
    ) {
        XCTFail("presentComparison must not be called by this test")
    }

    func presentSorting(
        openResizedLibrary: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    ) {
        XCTFail("presentSorting must not be called by this test")
    }
}
