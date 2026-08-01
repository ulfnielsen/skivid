# Viewer Screen Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the viewer screen a timeline and a real transport, making a clip seekable on iPad for the first time, in one control band instead of three-to-four rows.

**Architecture:** `ViewerModel` gains published time and duration from a periodic time observer, plus one `applyTransport(_:)` entry point — the same shape `ComparisonModel` already has. The six transport buttons and the scrubber are extracted from the comparison screen into shared views taking plain values and closures, so both screens drive one implementation. The viewer's transport calls the model directly and never touches `PlaybackIntent`, so the iOS `InertInputSource` is not modified and the unexecuted phase 4 input work is not a prerequisite.

**Tech Stack:** Swift 5, SwiftUI, AVFoundation, SwiftPM multi-target (`SkiVideoCore` portable library + `SkiVideoViewer` app targets), XcodeGen, XCTest, XCUITest.

## Global Constraints

- **Every `swift`, `xcodebuild` and `xcrun` command requires `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.** Without it: `no such module 'XCTest'`, and no `simctl`. The Command Line Tools have neither.
- **No file in `Sources/SkiVideoViewer/Shared/` may import AppKit or UIKit.** `SinglePlayerView.swift` is the sole permitted exception and must remain the only one. Test targets are exempt.
- **No file in `Sources/SkiVideoCore/` may import AppKit, UIKit, SwiftUI or Process.**
- Baseline to preserve at every task boundary: **122 macOS tests, 83 iOS, 7 iPad UI on both `iPad Pro 11-inch (M5)` and `iPad mini (A17 Pro)`, 0 failures.** `cd SkiVideoViewer && swift test` runs the macOS suite.
- Both app targets must build: `SkiVideoViewer-macOS` (`platform=macOS`) and `SkiVideoViewer-iPad` (`platform=iOS Simulator`).
- **The `.xcodeproj` is generated and gitignored.** Run `xcodegen generate` in `SkiVideoViewer/` after creating, moving or deleting any source file, and never commit it. A green `swift test` does not mean the app builds — SwiftPM globs sources, Xcode carries a fixed file list.
- **44pt targets for controls this project builds; system controls at platform-standard size.** A segmented `Picker` is 32pt on iPadOS and that is the size to want. Do not add `contentShape(Rectangle())` to a `Picker` or a `Slider` — measured three times with dispatched `NSEvent` clicks, it cannot route hits into a child control's segments and its only effect is swallowing clicks meant for what sits behind.
- **Slow motion is a one-shot action, not a toggle and not a hold.** It starts playback at 0.25×; the way back to full rate is play/pause. The rate lives on `AVPlayer`, which publishes nothing, so a toggle drawn from it would show stale state exactly while paused.
- **Tests touching duration or seek bounds must use real generated media.** The zero-byte fixtures give NaN durations, which is why the comparison screen's clamping defect survived four task reviews.
- **Do not modify `Sources/SkiVideoViewer/iOS/InertInputSource.swift`.** It stays inert. The viewer's transport reaches the model directly, exactly as the comparison bar does, so iPad seeking does not need `PlaybackIntent` and the unexecuted phase 4 input work is not a prerequisite. Implementing it here would be scope this plan does not carry.
- **Do not modify `Sources/SkiVideoViewer/macOS/AppKitInputSource.swift`.** macOS keeps ←/→ tap, double-tap and hold-to-shuttle unchanged.
- **Two input routes to one action is correct here and must not be "simplified".** On macOS the arrow keys and the new transport buttons both reach the same seek. That is not the comparison screen's ⌘Return defect, which was two *different* actions (`setSyncPoints()` and `returnToSyncPoints()`) claiming one shortcut with no defined winner. A reviewer seeing this duplication should leave it alone.
- Commit as you go, small commits, conventional messages.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/SkiVideoCore/Timecode.swift` | **create** — `Timecode.string(_:)`, moved out of `ComparisonModel` so both screens format identically |
| `Sources/SkiVideoCore/ViewerModel.swift` | **modify** — published `currentTime`/`duration`, `applyTransport(_:)`, `scrub(to:)` |
| `Sources/SkiVideoViewer/Shared/TransportControls.swift` | **create** — the six transport buttons; values and closures only |
| `Sources/SkiVideoViewer/Shared/TimelineScrubber.swift` | **create** — position/duration slider; values and closures only |
| `Sources/SkiVideoViewer/Shared/ComparisonControlBar.swift` | **modify** — migrate onto `TransportControls` |
| `Sources/SkiVideoViewer/Shared/ComparisonScrubber.swift` | **modify** — migrate onto `TimelineScrubber` |
| `Sources/SkiVideoViewer/Shared/ViewerPane.swift` | **create** — video, athlete/clip caption, tap-to-play |
| `Sources/SkiVideoViewer/Shared/ViewerControlBar.swift` | **create** — transport, time, clip stepping |
| `Sources/SkiVideoViewer/Shared/ContentView.swift` | **modify** — `detail` recomposed; sidebar untouched |
| `Tests/SkiVideoCoreTests/RealVideoFixture.swift` | **create** — `makeRealVideoFile`, extracted from `ComparisonModelTests` |
| `Tests/SkiVideoCoreTests/ViewerTransportTests.swift` | **create** |
| `Tests/SkiVideoViewerTests/ViewerLayoutMeasurementTests.swift` | **create** |
| `Tests/SkiVideoViewerUITests/ViewerOnIPadUITests.swift` | **create** |

---

### Task 1: ViewerModel gains time, duration, transport and scrub

**Files:**
- Create: `Sources/SkiVideoCore/Timecode.swift`
- Create: `Tests/SkiVideoCoreTests/RealVideoFixture.swift`
- Create: `Tests/SkiVideoCoreTests/ViewerTransportTests.swift`
- Modify: `Sources/SkiVideoCore/ViewerModel.swift`
- Modify: `Sources/SkiVideoCore/ComparisonModel.swift:450,542-547`
- Modify: `Sources/SkiVideoViewer/Shared/ComparisonControlBar.swift:153`
- Modify: `Sources/SkiVideoViewer/Shared/ComparisonScrubber.swift:93`
- Modify: `Tests/SkiVideoCoreTests/ComparisonModelTests.swift:1042-1092` (remove the moved helper)

**Interfaces:**
- Produces, for Tasks 2–4:
  - `public enum Timecode { public static func string(_ seconds: Double) -> String }`
  - `@Published public private(set) var currentTime: Double` on `ViewerModel`
  - `@Published public private(set) var duration: Double` on `ViewerModel`
  - `public func applyTransport(_ action: TransportAction)` on `ViewerModel`
  - `public func scrub(to seconds: Double)` on `ViewerModel`
  - `func makeRealVideoFile(in directory: URL, name: String, seconds: Double, fps: Int32 = 30) throws -> URL` on `XCTestCase`
- Consumes: `TransportAction` (already `public` in `Sources/SkiVideoCore/ComparisonModel.swift`, cases in left-to-right button order: `back5, back1, playPause, forward1, forward5, slow`).

- [ ] **Step 1: Move the timecode formatter into its own type**

Create `Sources/SkiVideoCore/Timecode.swift`:

```swift
import Foundation

/// One clip-position formatter for both screens.
///
/// Lived on `ComparisonModel` while the comparison screen was its only caller.
/// The viewer's control bar reads out the same way, and a viewer that formatted
/// `9.05` as `00:09.1` while the comparison screen wrote `00:09.0` would be a
/// difference nobody chose.
public enum Timecode {
    public static func string(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00.0" }
        let minutes = Int(seconds) / 60
        let remainder = seconds - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, remainder)
    }
}
```

- [ ] **Step 2: Delete the old formatter and update its three callers**

In `Sources/SkiVideoCore/ComparisonModel.swift`, delete the whole `public static func timecode(_:)` (lines 542–547) and change line 450 from `Self.timecode(` to `Timecode.string(` (twice on that line).

In `Sources/SkiVideoViewer/Shared/ComparisonControlBar.swift:153`, replace with:

```swift
        return Text(Timecode.string(time) + " / " + Timecode.string(duration))
```

In `Sources/SkiVideoViewer/Shared/ComparisonScrubber.swift:93`, replace with:

```swift
        .accessibilityValue(Timecode.string(displayedTime))
```

Do not keep `ComparisonModel.timecode` as a delegating alias. Two public names for one formatter is the drift this move exists to prevent.

- [ ] **Step 3: Run the suite to confirm the move changed nothing**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test
```

Expected: 122 tests, 0 failures. This is a rename; a failure here means a caller was missed.

- [ ] **Step 4: Commit**

```bash
git add SkiVideoViewer/Sources SkiVideoViewer/Tests
git commit -m "Move the timecode formatter out of ComparisonModel"
```

- [ ] **Step 5: Extract the real-media test fixture so both suites can use it**

Create `Tests/SkiVideoCoreTests/RealVideoFixture.swift` containing the helper currently private in `ComparisonModelTests.swift:1042-1092`, as an extension on `XCTestCase` so any test case can call it:

```swift
import AVFoundation
import XCTest

/// A real H.264 clip of a known length, generated rather than checked in.
///
/// Zero-byte fixtures give `AVPlayerItem.duration` a NaN, so every bounds and
/// duration branch silently never executes. That is exactly how the comparison
/// screen's sync-point clamping defect survived four task reviews and a task
/// that recorded it as "reasoned to, never observed". Any test that touches
/// duration, seek bounds or the scrubber must use this.
///
/// 160×90 at 30fps keeps a 20s clip to 600 tiny frames, which encodes in a
/// fraction of a second; the per-frame grey level changes so the encoder cannot
/// collapse the clip into something with a different duration than asked for.
extension XCTestCase {
    func makeRealVideoFile(
        in directory: URL,
        name: String,
        seconds: Double,
        fps: Int32 = 30
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
```

Then delete `makeRealVideoFile` from `ComparisonModelTests.swift` and change its call sites to pass the directory explicitly. The existing tests hold their temp directory in a `temporaryDirectory` property; pass that. Run `swift test` — still 122, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add SkiVideoViewer/Tests
git commit -m "Extract the real-media fixture so both suites can use it"
```

- [ ] **Step 7: Write the failing tests for the viewer's transport and scrub**

Create `Tests/SkiVideoCoreTests/ViewerTransportTests.swift`:

```swift
import AVFoundation
import XCTest
@testable import SkiVideoCore

/// The viewer's transport, against real media.
///
/// Every assertion here is about a bound or a duration, so a zero-byte fixture
/// would make the whole file vacuous — see `RealVideoFixture`.
@MainActor
final class ViewerTransportTests: XCTestCase {
    private var temporaryDirectory: URL?

    override func tearDown() {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        super.tearDown()
    }

    func testDurationIsPublishedOnceTheClipLoads() throws {
        let model = try makeLoadedModel(seconds: 6)
        waitUntil("the duration must be published") { model.duration > 0 }
        XCTAssertEqual(model.duration, 6, accuracy: 0.2)
    }

    func testCurrentTimeFollowsThePlayhead() throws {
        let model = try makeLoadedModel(seconds: 6)
        waitUntil("the duration must be published") { model.duration > 0 }
        model.scrub(to: 3)
        settle(model)
        waitUntil("currentTime must follow the playhead") { model.currentTime > 2.5 }
        XCTAssertEqual(model.currentTime, 3, accuracy: 0.3)
    }

    func testForward5MovesFiveSeconds() throws {
        let model = try makeLoadedModel(seconds: 20)
        waitUntil("the duration must be published") { model.duration > 0 }
        model.applyTransport(.forward5)
        settle(model)
        XCTAssertEqual(model.player.currentTime().seconds, 5, accuracy: 0.2)
    }

    func testBack1DoesNotGoNegative() throws {
        let model = try makeLoadedModel(seconds: 20)
        waitUntil("the duration must be published") { model.duration > 0 }
        model.applyTransport(.back1)
        settle(model)
        XCTAssertEqual(model.player.currentTime().seconds, 0, accuracy: 0.05,
                       "seeking back from 0 must clamp at 0, not go negative")
    }

    func testForward5StopsAtTheEndOfTheClip() throws {
        let model = try makeLoadedModel(seconds: 6)
        waitUntil("the duration must be published") { model.duration > 0 }
        for _ in 0..<3 { model.applyTransport(.forward5); settle(model) }
        XCTAssertLessThanOrEqual(model.player.currentTime().seconds, 6.05,
                                 "seeking past the end must clamp to the duration")
    }

    func testSlowPlaysAtQuarterRate() throws {
        let model = try makeLoadedModel(seconds: 20)
        waitUntil("the duration must be published") { model.duration > 0 }
        model.applyTransport(.slow)
        XCTAssertEqual(model.player.rate, 0.25, accuracy: 0.01)
    }

    func testPlayPauseTogglesTheRate() throws {
        let model = try makeLoadedModel(seconds: 20)
        waitUntil("the duration must be published") { model.duration > 0 }
        model.applyTransport(.playPause)
        XCTAssertGreaterThan(model.player.rate, 0, "the first press must start playback")
        model.applyTransport(.playPause)
        XCTAssertEqual(model.player.rate, 0, "the second press must pause")
    }

    /// A transport press while an arrow hold is in flight must cancel the hold.
    /// Without this the hold's state survives the press: `heldDirection` stays
    /// set, so `beginArrow` refuses the next hold entirely — the same class of
    /// stranded-state defect that the `heldDirection == nil` guard exists for.
    func testATransportPressCancelsAnArrowHold() throws {
        let model = try makeLoadedModel(seconds: 20)
        waitUntil("the duration must be published") { model.duration > 0 }
        model.beginArrow(.forward)
        model.applyTransport(.forward5)
        settle(model)

        // Assert on an effect the *second* hold produces, not on
        // `lastSeekOffset`: `applyTransport(.forward5)` already sets that, so an
        // assertion on it would pass whether or not the hold was cancelled.
        // A hold that starts drives the rate to 0.35 after `holdThreshold`.
        model.beginArrow(.forward)
        waitUntil("a hold after a transport press must be accepted and start") {
            abs(model.player.rate - 0.35) < 0.01
        }
    }

    func testScrubClampsAboveTheDuration() throws {
        let model = try makeLoadedModel(seconds: 6)
        waitUntil("the duration must be published") { model.duration > 0 }
        model.scrub(to: 999)
        settle(model)
        XCTAssertLessThanOrEqual(model.player.currentTime().seconds, 6.05,
                                 "scrubbing beyond the clip must clamp to its duration")
    }

    /// `scrub` has its own lower clamp, separate from `seek`'s. A test that only
    /// covered `applyTransport(.back1)` would leave this one unpinned, because
    /// the two take different paths to the player.
    func testScrubClampsBelowZero() throws {
        let model = try makeLoadedModel(seconds: 6)
        waitUntil("the duration must be published") { model.duration > 0 }
        model.scrub(to: -20)
        settle(model)
        XCTAssertEqual(model.player.currentTime().seconds, 0, accuracy: 0.05,
                       "scrubbing before the start must clamp at 0, not go negative")
    }

    // MARK: - helpers

    private func makeLoadedModel(seconds: Double) throws -> ViewerModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        temporaryDirectory = root
        let athlete = root.appendingPathComponent("Athlete", isDirectory: true)
        _ = try makeRealVideoFile(in: athlete, name: "run1.mov", seconds: seconds)

        let model = ViewerModel(
            input: InertTestInputSource(),
            folderPicker: UnusedTestFolderPicker(),
            oauthPresenter: UnusedTestOAuthPresenter()
        )
        model.openDirectory(root)
        return model
    }

    /// Stability, not an expected value: a wait for the value the test wants
    /// would pass by construction. Seeks on a real item are asynchronous.
    private func settle(_ model: ViewerModel, timeout: TimeInterval = 5) {
        var previous = Double.nan
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let now = model.player.currentTime().seconds
            if now == previous { return }
            previous = now
        }
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 20, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), message)
    }
}
```

Reuse whatever test doubles `ViewerModelTests` already declares for
`PlaybackInputSource`, `FolderPicker` and `OAuthPresenter` rather than adding
`InertTestInputSource` / `UnusedTestFolderPicker` / `UnusedTestOAuthPresenter`:
open `Tests/SkiVideoCoreTests/` and use the existing names. If none exist,
declare these three as minimal conforming stubs whose methods do nothing and
whose pickers return `nil`.

- [ ] **Step 8: Run the tests to verify they fail**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test --filter ViewerTransportTests
```

Expected: compile failure — `value of type 'ViewerModel' has no member 'duration'` / `'applyTransport'` / `'scrub'`.

- [ ] **Step 9: Add the published time and duration to ViewerModel**

In `Sources/SkiVideoCore/ViewerModel.swift`, add after the `status` property (line 24):

```swift
    /// Position and length of the current clip, for the scrubber and the time
    /// readout. Published for the same reason `ComparisonModel` publishes its
    /// pair: `AVPlayer` reports neither, so a view that wants them has to be
    /// told.
    @Published public private(set) var currentTime = 0.0
    @Published public private(set) var duration = 0.0
```

Add the observer storage alongside the other private state (near line 40):

```swift
    private var timeObserver: Any?
    private var durationObserver: NSKeyValueObservation?
```

Add the observer setup, called once from `init` after the `onIntent` assignment:

```swift
        startObservingTime()
```

and the method itself:

```swift
    /// 0.1s matches the comparison screen's interval: fast enough that the
    /// scrubber thumb tracks playback without visible stepping, slow enough not
    /// to publish on every frame.
    private func startObservingTime() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
            }
        }
    }

    /// The periodic observer cannot carry duration: it does not fire while
    /// paused, and a freshly loaded clip is paused. `ComparisonModel` learned
    /// the same thing — the duration arrives asynchronously, after the item
    /// does.
    private func observeDuration(of item: AVPlayerItem) {
        durationObserver = item.observe(\.duration, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item else { return }
                let seconds = item.duration.seconds
                guard seconds.isFinite, seconds > 0 else { return }
                self.duration = seconds
            }
        }
    }
```

In `loadCurrentVideo()` (line 337), replace the body so the new item is observed and the published values reset:

```swift
    private func loadCurrentVideo() {
        guard let currentVideo else { return }
        let item: AVPlayerItem
        if let media = driveMediaByURL[currentVideo] {
            item = AVPlayerItem(url: media.streamingURL)
        } else {
            item = AVPlayerItem(url: currentVideo)
        }
        player.replaceCurrentItem(with: item)
        // Reset before observing: the previous clip's figures would otherwise
        // drive the scrubber until the new duration arrives, which for a remote
        // Drive item can be a visible moment.
        currentTime = 0
        duration = 0
        observeDuration(of: item)
        player.pause()
        status = "Paused"
    }
```

Note the status string changes from `"Paused · Space to play"` to `"Paused"`. Space is not a key on a touch device, and the status is now shown on both platforms.

- [ ] **Step 10: Add the transport and scrub entry points**

Add to `ViewerModel`, after `togglePlayback()`:

```swift
    /// The viewer's six transport actions, in one entry point mirroring
    /// `ComparisonModel.applyTransport`. One shape across both screens means
    /// one shared `TransportControls` view can drive either.
    public func applyTransport(_ action: TransportAction) {
        // Any in-flight arrow hold ends first. Without this the hold's state
        // survives the press — `heldDirection` stays set, and `beginArrow`
        // refuses every later hold.
        endArrow(performTap: false)
        switch action {
        case .back5: seek(seconds: -5)
        case .back1: seek(seconds: -1)
        case .forward1: seek(seconds: 1)
        case .forward5: seek(seconds: 5)
        case .playPause: togglePlayback()
        case .slow:
            guard currentVideo != nil else { return }
            player.playImmediately(atRate: 0.25)
            status = "Quarter speed"
        }
    }

    /// Absolute seek, for the scrubber. `cancelPendingSeeks` first so a drag
    /// coalesces instead of queueing one seek per pixel.
    public func scrub(to seconds: Double) {
        guard player.currentItem != nil else { return }
        endArrow(performTap: false)
        player.cancelPendingSeeks()
        var target = max(0, seconds)
        if duration > 0 { target = min(target, duration) }
        currentTime = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }
```

`seek(seconds:)` stays `private` — `applyTransport` and `scrub` are the only public routes, exactly as `ComparisonModel` keeps its per-side methods behind `applyTransport`.

- [ ] **Step 11: Run the tests to verify they pass**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test
```

Expected: 122 + 10 = 132 tests, 0 failures.

- [ ] **Step 12: Mutation-test the new assertions**

Run a clean unmutated `swift test` first and record the count — a new test failing on unmutated code makes every mutant look killed, which invalidated a whole battery earlier in this project. Then apply each mutant, run, restore, and record which test killed it:

| # | Mutation | Must be killed by |
|---|---|---|
| M1 | `case .forward5: seek(seconds: 5)` → `seek(seconds: 1)` | `testForward5MovesFiveSeconds` |
| M2 | in `scrub`, `var target = max(0, seconds)` → `var target = seconds` | `testScrubClampsBelowZero`. Note `testBack1DoesNotGoNegative` cannot kill this — it goes through `seek(seconds:)`, a different path to the player |
| M3 | delete `if duration > 0 { target = min(target, duration) }` in `scrub` | `testScrubClampsAboveTheDuration` |
| M4 | `playImmediately(atRate: 0.25)` → `atRate: 1` | `testSlowPlaysAtQuarterRate` |
| M5 | delete `endArrow(performTap: false)` from `applyTransport` | `testATransportPressCancelsAnArrowHold` |
| M6 | delete `observeDuration(of: item)` from `loadCurrentVideo` | `testDurationIsPublishedOnceTheClipLoads` |
| M7 | delete `currentTime = 0` / `duration = 0` reset | expect survival; record it, do not invent a test to chase it |

Report every mutant and its killer, including survivors.

- [ ] **Step 13: Commit**

```bash
git add SkiVideoViewer/Sources SkiVideoViewer/Tests
git commit -m "Publish viewer time and duration, and add its transport"
```

---

### Task 2: Extract the shared transport and scrubber

**Files:**
- Create: `Sources/SkiVideoViewer/Shared/TransportControls.swift`
- Create: `Sources/SkiVideoViewer/Shared/TimelineScrubber.swift`
- Modify: `Sources/SkiVideoViewer/Shared/ComparisonControlBar.swift:101-145`
- Modify: `Sources/SkiVideoViewer/Shared/ComparisonScrubber.swift:24-95`

**Interfaces:**
- Consumes from Task 1: `Timecode.string(_:)`.
- Produces, for Task 3:
  - `TransportControls(isEnabled: Bool, perform: @escaping (TransportAction) -> Void)`
  - `TimelineScrubber(time: Double, duration: Double, onScrub: @escaping (Double) -> Void)`

This task is a pure refactor: it must change no pixel and no behaviour. The
comparison screen's layout is pinned by `ComparisonLayoutMeasurementTests`
(880.5pt wrap threshold, 60pt and 112pt heights) and by 7 iPad UI tests, which
is what makes the migration safe to do rather than duplicate.

- [ ] **Step 1: Create the shared transport**

```swift
import SkiVideoCore
import SwiftUI

/// The six transport buttons, shared by the comparison screen and the viewer.
///
/// Values and a closure, no model: the two screens have different models and
/// nothing here needs to know which one it is driving.
///
/// A `ForEach` over `allCases` rather than a restatement of the list —
/// `TransportAction`'s declaration order *is* left-to-right button order, and
/// the exhaustive `switch` in `appearance(of:)` means a case added to the model
/// cannot silently fail to appear here.
struct TransportControls: View {
    let isEnabled: Bool
    let perform: (TransportAction) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(TransportAction.allCases) { button($0) }
        }
    }

    private func button(_ action: TransportAction) -> some View {
        let appearance = Self.appearance(of: action)
        return Button {
            perform(action)
        } label: {
            Image(systemName: appearance.symbol)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(appearance.label)
        .accessibilityLabel(appearance.label)
        .disabled(!isEnabled)
    }

    /// `contentShape` above is deliberate and load-bearing: these are plain
    /// `Button`s, so it genuinely enlarges the hit region to 44×44. Do not copy
    /// it onto a `Picker` or a `Slider` — measured three times with dispatched
    /// `NSEvent` clicks, a parent's content shape cannot route hits into a child
    /// control's segments, and its only effect there is swallowing clicks meant
    /// for what sits behind.
    private static func appearance(of action: TransportAction) -> (symbol: String, label: String) {
        switch action {
        case .back5: return ("gobackward.5", "Back 5 seconds")
        case .back1: return ("gobackward.minus", "Back 1 second")
        case .playPause: return ("playpause.fill", "Play or pause")
        case .forward1: return ("goforward.plus", "Forward 1 second")
        case .forward5: return ("goforward.5", "Forward 5 seconds")
        // A one-shot action, not a toggle. The rate it sets lives on `AVPlayer`,
        // which publishes nothing — a toggle rendered from it would show stale
        // state whenever the periodic time observer is idle, which is precisely
        // while paused. The way back to 1× is play/pause. Labelled as the action
        // it is.
        case .slow: return ("tortoise.fill", "Play at quarter speed")
        }
    }
}
```

- [ ] **Step 2: Create the shared scrubber**

```swift
import SkiVideoCore
import SwiftUI

/// A clip timeline, shared by the comparison screen and the viewer.
///
/// Owns the mid-drag state both callers need: the model's playhead stops being
/// the truth while dragging, because the periodic time observer lags the thumb
/// and following it makes the thumb fight the finger.
struct TimelineScrubber: View {
    let time: Double
    let duration: Double
    let onScrub: (Double) -> Void

    @State private var scrubTime = 0.0
    @State private var isScrubbing = false

    private var displayedTime: Double {
        isScrubbing ? scrubTime : time
    }

    var body: some View {
        Slider(
            value: Binding(
                get: { min(max(displayedTime, 0), max(duration, 0.0001)) },
                set: { newValue in
                    scrubTime = newValue
                    // Seek live rather than on release. Finding a frame means
                    // watching the frames go by; the callers' scrub methods call
                    // `cancelPendingSeeks` first, so a drag coalesces instead of
                    // queueing a seek per pixel.
                    onScrub(newValue)
                }
            ),
            in: 0...max(duration, 0.0001),
            onEditingChanged: { editing in
                // Seed from the playhead *before* `isScrubbing` flips: the flag
                // changes on drag-start, ahead of the first `set`, and an
                // unseeded `scrubTime` would snap the thumb back to wherever the
                // previous drag ended for that one frame.
                if editing { scrubTime = time }
                isScrubbing = editing
                // The last `set` already seeked here; repeating it on release
                // makes the final position durable even if that setter was
                // coalesced away.
                if !editing { onScrub(scrubTime) }
            }
        )
        .disabled(duration <= 0)
        // Reserves a 44pt row, matching the control bars'. It does not make the
        // slider 44pt: measured, a `Slider` draws over 16pt on macOS whether
        // framed at `height: 44` or left unframed — the frame centres it rather
        // than growing it — and it hit-tests over its own extent.
        //
        // `contentShape(Rectangle())` was tried here and removed: a parent's
        // content shape cannot route hits into a child control, and its only
        // measurable effect was swallowing clicks meant for what sits behind.
        // Do not re-add it.
        .frame(height: 44)
        .accessibilityLabel("Timeline")
        .accessibilityValue(Timecode.string(displayedTime))
    }
}
```

- [ ] **Step 3: Migrate the comparison control bar**

In `ComparisonControlBar.swift`, delete `transport`, `transportButton(_:)` and
`appearance(of:)` (lines 101–145) and replace the `transport` reference in both
`ViewThatFits` branches with:

```swift
                TransportControls(isEnabled: model.hasTwoVideos) { action in
                    // Always through `applyTransport`, never the per-side model
                    // methods it wraps: `lastTouchedSide` is written only there
                    // and in `load`, so a control that bypasses it leaves that
                    // state stale and the demotion off `.both` lands on the
                    // wrong side.
                    model.applyTransport(action)
                }
```

Keep the doc comment at the top of the file, but delete its now-stale claim that
"The six transport buttons and the anchor are plain `Button`s" — the anchor
still is, the six now live in `TransportControls`. Reword to point there.

- [ ] **Step 4: Migrate the comparison scrubber**

Replace the body of `ComparisonScrubber` so it becomes the thin observing
wrapper that resolves the target and hands values down, keeping the
`scrubbedSide` extension and both doc comments:

```swift
struct ComparisonScrubber: View {
    @ObservedObject var model: ComparisonModel

    private var side: ComparisonSide { model.target.scrubbedSide }

    var body: some View {
        TimelineScrubber(
            time: side == .left ? model.leftTime : model.rightTime,
            duration: side == .left ? model.leftDuration : model.rightDuration,
            onScrub: { model.scrub(side, to: $0) }
        )
    }
}
```

- [ ] **Step 5: Regenerate the project and run every gate**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer
xcodegen generate
swift test
xcodebuild -scheme SkiVideoViewer-macOS -destination 'platform=macOS' build
xcodebuild -scheme SkiVideoViewer-iPad -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' test
xcodebuild -scheme SkiVideoViewer-iPad -destination 'platform=iOS Simulator,name=iPad mini (A17 Pro)' test
```

Expected: 132 macOS tests and 7 iPad UI tests on each simulator, 0 failures, both builds succeeding. **`ComparisonLayoutMeasurementTests` passing unchanged is the whole point of this task** — it pins the 880.5pt threshold and the 60pt/112pt heights, so an identical result is the evidence the refactor changed nothing.

- [ ] **Step 6: Prove the migration is wired up, not merely compiling**

Apply and restore each mutation, running the iPad UI suite:

| # | Mutation | Must be killed by |
|---|---|---|
| M8 | in `TransportControls.button`, replace `perform(action)` with `{}` | the comparison UI test that exercises the transport |
| M9 | in `ComparisonScrubber`, pass `duration: 0` | the layout or UI test asserting the scrubber is enabled |

If M8 survives, the comparison suite never exercised the transport's action and
this task must add a test that does — a shared control nothing calls is worse
than the duplication it replaced.

- [ ] **Step 7: Commit**

```bash
git add SkiVideoViewer/Sources
git commit -m "Extract the shared transport controls and timeline scrubber"
```

---

### Task 3: The viewer pane and control bar

**Files:**
- Create: `Sources/SkiVideoViewer/Shared/ViewerPane.swift`
- Create: `Sources/SkiVideoViewer/Shared/ViewerControlBar.swift`
- Modify: `Sources/SkiVideoViewer/Shared/ContentView.swift:183-243`

**Interfaces:**
- Consumes from Tasks 1–2: `ViewerModel.currentTime`, `.duration`,
  `.applyTransport(_:)`, `.scrub(to:)`, `Timecode.string(_:)`,
  `TransportControls`, `TimelineScrubber`.
- Produces, for Task 4: accessibility identifiers `Viewer timeline`,
  `Previous clip`, `Next clip`, and the status chip label prefix `Status: `.

- [ ] **Step 1: Create the viewer pane**

```swift
import SkiVideoCore
import SwiftUI

/// The video, its caption and the one touch gesture.
///
/// The athlete name and clip description used to be two rows of the control
/// band. Over the letterbox they cost nothing: the comparison screen's
/// equivalent caption measured 29.0pt minimum height, identical to a plain
/// `Text`, because the letterbox area already exists.
struct ViewerPane: View {
    @ObservedObject var model: ViewerModel
    let athleteName: String

    var body: some View {
        NativePlayerView(player: model.player)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Tap to play/pause: the one universal video gesture, and without it
            // the video is inert to touch. Deliberately the *only* gesture here
            // — swipe-for-clip and edge-hold-to-shuttle would duplicate controls
            // the bar already carries.
            .contentShape(Rectangle())
            .onTapGesture { model.applyTransport(.playPause) }
            .overlay(alignment: .bottomLeading) { caption }
            .overlay(alignment: .topTrailing) { statusChip }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(athleteName)
                .font(.headline)
            Text(model.clipDescription)
                .font(.caption)
        }
        .foregroundStyle(.white.opacity(0.85))
        .shadow(radius: 2)
        .padding(12)
        .allowsHitTesting(false)
    }

    /// Capped and non-hit-testable for the same two reasons the comparison
    /// screen's chip is: unbounded it runs past the video's edge, and
    /// hit-testable it eats taps meant for the video underneath — which here is
    /// the play/pause gesture.
    private var statusChip: some View {
        Text(model.status)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.45), in: Capsule())
            .frame(maxWidth: 320)
            .padding(12)
            .allowsHitTesting(false)
            .accessibilityLabel("Status: \(model.status)")
    }
}
```

- [ ] **Step 2: Create the viewer control bar**

```swift
import SkiVideoCore
import SwiftUI

/// Transport, time and clip stepping — the one row that replaces three text
/// buttons and a hint line.
///
/// No layout or target picker, unlike the comparison screen's bar, so this is
/// roughly 230pt narrower and expected to fit one row at every iPad width.
/// `ViewThatFits` still carries a wrapped fallback: an expectation is not a
/// measurement, and Task 4 measures it.
struct ViewerControlBar: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                transport
                Spacer(minLength: 8)
                timeLabel
                clipStepping
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    transport
                    Spacer(minLength: 0)
                }
                HStack(spacing: 16) {
                    Spacer(minLength: 8)
                    timeLabel
                    clipStepping
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var transport: some View {
        TransportControls(isEnabled: model.currentPlaybackURL != nil) { action in
            model.applyTransport(action)
        }
    }

    private var timeLabel: some View {
        Text(Timecode.string(model.currentTime) + " / " + Timecode.string(model.duration))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    /// Navigation *between* clips, not transport *within* one, so it sits apart
    /// from the transport rather than joining it.
    private var clipStepping: some View {
        HStack(spacing: 4) {
            stepButton("backward.end.fill", "Previous clip", by: -1)
            stepButton("forward.end.fill", "Next clip", by: 1)
        }
    }

    private func stepButton(_ symbol: String, _ label: String, by offset: Int) -> some View {
        Button {
            model.changeVideo(by: offset)
        } label: {
            Image(systemName: symbol)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
        .disabled(model.currentPlaybackURL == nil)
    }
}
```

- [ ] **Step 3: Recompose `ContentView.detail`**

Replace lines 183–243's `detail` body. Delete the whole
`VStack(alignment: .leading, spacing: 10) { … }` block containing the name/clip
rows, the three text buttons and the hint line:

```swift
    private var detail: some View {
        VStack(spacing: 0) {
            if let athlete = model.currentAthlete {
                ViewerPane(model: model, athleteName: athlete.name)

                VStack(spacing: 0) {
                    TimelineScrubber(
                        time: model.currentTime,
                        duration: model.duration,
                        onScrub: { model.scrub(to: $0) }
                    )
                    .accessibilityIdentifier("Viewer timeline")
                    .padding(.horizontal, 12)

                    ViewerControlBar(model: model)
                }
                .background(.bar)
            } else {
                emptyState(
                    title: "Choose a Video Folder",
                    systemImage: "play.rectangle",
                    description: "Athletes will appear in the sidebar."
                )
            }
        }
        .navigationTitle(model.directory?.lastPathComponent ?? (model.isUsingGoogleDrive ? "Google Drive" : "Ski Video Viewer"))
        #if os(iOS)
        .toolbar { toolbarContent }
        #endif
    }
```

The hint line is deleted outright. macOS restores those words as the `help(_:)`
tooltips already on every button; iPadOS needs none now the controls are visible
rather than described.

- [ ] **Step 4: Regenerate, build and run every gate**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer
xcodegen generate
swift test
xcodebuild -scheme SkiVideoViewer-macOS -destination 'platform=macOS' build
xcodebuild -scheme SkiVideoViewer-iPad -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build
```

Expected: 132 tests, 0 failures, both builds succeeding.

- [ ] **Step 5: Confirm no AppKit or UIKit leaked into Shared/**

```bash
grep -rln "^import AppKit\|^import UIKit" Sources/SkiVideoViewer/Shared/
```

Expected: exactly `Sources/SkiVideoViewer/Shared/SinglePlayerView.swift`.

- [ ] **Step 6: Commit**

```bash
git add SkiVideoViewer/Sources
git commit -m "Recompose the viewer around one control band"
```

---

### Task 4: Prove it at both widths

**Files:**
- Create: `Tests/SkiVideoViewerTests/ViewerLayoutMeasurementTests.swift`
- Create: `Tests/SkiVideoViewerUITests/ViewerOnIPadUITests.swift`

**Interfaces:**
- Consumes from Task 3: `ViewerControlBar`, the identifiers `Viewer timeline`,
  `Previous clip`, `Next clip`, and the `Status: ` accessibility prefix.

**This task's deliverable is a number, not a pass.** The spec claims the bar
fits one row at 834pt and 744pt, and labels that an expectation rather than a
measurement. Measure it and report the real figure. If it wraps, say so plainly
with the actual height — a screenshot that quietly disagrees with the spec is
the most valuable thing this task can produce, and reporting it is success.

- [ ] **Step 1: Measure the bar's ideal width and wrapped heights**

Create `Tests/SkiVideoViewerTests/ViewerLayoutMeasurementTests.swift`, following
the `NSHostingView`/`sizeThatFits` harness in the existing
`ComparisonLayoutMeasurementTests.swift` — open that file and mirror its
approach rather than inventing a second one. Assert:

- the bar's ideal width, recorded as a constant in the test;
- the one-row height at ideal width + 1pt;
- the height at 834pt and at 744pt;
- that both figures are **identical at 834pt and 744pt**, so the band does not
  change height between iPad widths.

Write the measured numbers into the test as the expected values, with a comment
saying they are measured. Do not copy the comparison screen's 880.5/60/112 —
those are a different bar.

- [ ] **Step 2: Add the iPad UI tests**

Create `Tests/SkiVideoViewerUITests/ViewerOnIPadUITests.swift`. Every test must
dismiss the launch document picker first: the 11-inch presents it as a popover
whose `PopoverDismissRegion` swallows taps while being invisible to the
accessibility tree, and the mini presents it as a sheet with no such region at
all. **`CompareOnIPadUITests` has the working helper for both — reuse it, do not
write a second one, and do not weaken it.** A previous attempt used "the toolbar
is reachable" as the dismissal check; it passed while the picker was still up and
every later tap went nowhere.

Assert:

- the timeline exists and is enabled once a clip is loaded;
- `Previous clip` and `Next clip` exist and are hittable;
- the six transport buttons exist by their accessibility labels;
- the status chip is present, matching `label BEGINSWITH 'Status: '`;
- **no element's frame falls outside the window** at 834pt and 744pt — the
  clipping check.

If a rotation is involved, wait — bounded, 10s — for a control to land inside
the window before measuring. A frame captured mid-animation once read a control
at y 2343 in a 1210pt window. Do not replace that wait with a fixed sleep.

- [ ] **Step 3: Capture screenshots at both widths, both orientations**

Save PNGs inside the worktree and list every path in the report:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -scheme SkiVideoViewer-iPad -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' test
xcodebuild -scheme SkiVideoViewer-iPad -destination 'platform=iOS Simulator,name=iPad mini (A17 Pro)' test
```

The screenshots need a loaded clip to be worth looking at, and XCUITest cannot
load one — there is no in-app route, `initialDirectory` is nil on iOS and the
picker is out-of-process. Generate two synthetic clips with `ffmpeg` into a
scratch directory and copy them into the simulator's app container before
launching:

```bash
ffmpeg -y -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=8" \
  -c:v libx264 -pix_fmt yuv420p /tmp/viewer-fixture/Athlete/run1.mp4
DEV=<simulator udid>
C=$(xcrun simctl get_app_container "$DEV" ch.ski.video-viewer.ipad data)
cp -R /tmp/viewer-fixture/Athlete "$C/Documents/"
```

`-pix_fmt yuv420p` is not optional: without it ffmpeg negotiates up to 10-bit
4:4:4, which VideoToolbox on iPhone and iPad cannot decode at all
(`kVTVideoDecoderBadDataErr`, −8969).

- [ ] **Step 4: Count the chrome rows and state whether the spec's claim holds**

For each width and orientation, count the rows of chrome below the video and
compare against the spec's claim of a ~104pt two-part band. Report a table of
measured heights. State plainly whether the one-row claim holds, and at which
widths.

- [ ] **Step 5: Mutation-test the new assertions**

Run a clean unmutated baseline first, then:

| # | Mutation | Must be killed by |
|---|---|---|
| M10 | in `ViewerControlBar`, delete the wrapped `VStack` fallback from `ViewThatFits` | the height assertion at the narrower width, if it wraps there |
| M11 | in `ViewerPane`, delete `.frame(maxWidth: 320)` from the status chip | the containment assertion |
| M12 | in `ViewerPane`, delete `.allowsHitTesting(false)` from the chip | a test asserting a tap on the video toggles playback |
| M13 | in `ViewerControlBar`, swap `by: -1` and `by: 1` on the step buttons | a test asserting Next advances the clip |

M12 and M13 may require assertions not listed in Step 2; add them.

- [ ] **Step 6: Commit**

```bash
git add SkiVideoViewer/Tests
git commit -m "Cover the redesigned viewer end to end"
```

---

## Done when

- 132+ macOS tests, 83 iOS, and the iPad UI suite green on **both** `iPad Pro 11-inch (M5)` and `iPad mini (A17 Pro)`.
- Both app targets build.
- `Sources/SkiVideoViewer/Shared/` still has `SinglePlayerView.swift` as its only AppKit/UIKit importer.
- The measured band height is recorded, and the spec corrected if the one-row claim failed.
- Screenshots captured at 834pt and 744pt with a clip loaded.

## Carried forward — not this plan's work

- **The macOS viewer needs a human check.** Arrow-key seeking (tap, double-tap, hold), tooltips, ⌘F, clip stepping. macOS cannot be driven from the implementation environment, and this plan deliberately changes macOS.
- **The status chip has never been seen over bright footage** on either screen. Snow is high-key and low-contrast against a translucent capsule — the worst input for it.
- **Phase 4 input work** — hardware keyboard and touch gestures beyond tap-to-play on iPad — remains unexecuted and is no longer a prerequisite for anything.
- **Two open items on the comparison screen**, unchanged: the infeasible-offset case still misaligns silently, and the `returnToSyncPoints()` normalization call has no test (deleting it leaves the suite green).
