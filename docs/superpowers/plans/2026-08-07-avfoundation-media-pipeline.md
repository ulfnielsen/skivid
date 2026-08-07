# AVFoundation Media Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the ffmpeg-backed media pipeline with an in-process AVFoundation one, fixing a resize that is broken whenever the app is launched from Finder.

**Architecture:** `AVFoundationMediaPipeline` lands in `SkiVideoCore` behind the existing `MediaPipeline` seam, so it compiles for iOS as well as macOS. `resize` uses `AVAssetReader` + `AVAssetWriter` with explicitly pinned encode settings rather than an export preset, because the value of the step is bitrate reduction and a preset would decide that number for us. `writeMetadata` stays a passthrough remux.

**Tech Stack:** Swift 5, AVFoundation, VideoToolbox (via AVAssetWriter), SwiftPM multi-target, XcodeGen, XCTest.

## Global Constraints

- **Every `swift`, `xcodebuild` and `xcrun` command requires `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.** Without it: `no such module 'XCTest'`, and no `simctl`.
- **No file in `Sources/SkiVideoCore/` may import AppKit, UIKit, SwiftUI or Process.** `AVFoundation` is already imported there by `ViewerModel` and `ComparisonModel`, so it is fine.
- **No file in `Sources/SkiVideoViewer/Shared/` may import AppKit or UIKit.** `SinglePlayerView.swift` is the sole exception.
- Baseline to preserve: **386 macOS tests, 2 skipped, 0 failures — EXCLUDING `CorrectedStartEndToEndTests`, which is flaky on `main` and belongs to parallel work (see below)**, 14 iPad UI tests on each of `iPad Pro 11-inch (M5)` and `iPad mini (A17 Pro)`. `cd SkiVideoViewer && swift test` runs the macOS suite.
- Both app targets must build: `SkiVideoViewer-macOS` (`platform=macOS`) and `SkiVideoViewer-iPad` (`platform=iOS Simulator`).
- **The `.xcodeproj` is generated and gitignored.** Run `xcodegen generate` in `SkiVideoViewer/` after creating or deleting any source file, and never commit it. A green `swift test` does not mean the app builds — SwiftPM globs sources, Xcode carries a fixed file list.
- **Output bitrate is `round(width × height × 1.784)` bits/s**, computed from the **output** dimensions, not the source. That is 3,699,302 at 1920×1080, matching the 3.70 Mbps the current pipeline produces, and 1,644,134 at 1280×720.
- **Never upscale.** `s = min(1920 / displayWidth, 1080 / displayHeight, 1)`. Output dimensions are the source's dimensions multiplied by `s`, rounded to even numbers — H.264 4:2:0 requires even dimensions.
- **Audio is optional.** A source with no audio track produces an output with no audio track. Do not fail, and do not synthesise silence.
- **`preferredTransform` must survive.** Rotated footage that comes out sideways is the single most likely defect in this work, and it will not show up on generated fixtures, which have an identity transform.
- **Assert on properties, never on byte sizes or achieved bitrates.** VideoToolbox behaviour differs between hosts; those figures are flaky.
- **`canPresentSorting` stays `false` on iOS.** Enabling iPad sorting is explicitly out of scope for this plan.
- Commit as you go, small commits, conventional messages.

---

## A note on the code in this plan

The settings dictionaries, the geometry rule and the tests below are
**requirements** — use those values verbatim. The reader/writer pump loop is
given as a working shape, but it was written without a compiler. If an API call
does not compile or an `async` overload differs in this SDK, **the settings and
the geometry rule are what must be preserved**; the exact call sequence is
yours to correct. Say so in your report if you change it.

A concrete precedent: an earlier plan in this project specified
`player.cancelPendingSeeks()`, which does not exist on `AVPlayer`. The
implementer corrected it to `player.currentItem?.cancelPendingSeeks()` and
reported the correction. Do that.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/SkiVideoCore/AVFoundationMediaPipeline.swift` | **create** — both operations, portable |
| `Sources/SkiVideoCore/MediaPipelineError.swift` | **create** — the errors the pipeline can raise |
| `Sources/SkiVideoViewer/macOS/FFmpegMediaPipeline.swift` | **delete** |
| `Sources/SkiVideoViewer/macOS/SortingWindowController.swift:42` | **modify** — construct the new pipeline |
| `Sources/SkiVideoCore/SecondaryScreens.swift:9` | **modify** — stale doc comment naming ffmpeg |
| `Sources/SkiVideoViewer/iOS/IOSSecondaryScreenPresenter.swift:7` | **modify** — stale doc comment naming ffmpeg |
| `Sources/SkiVideoCore/VideoLibrary.swift:16-18` | **modify** — `supportedExtensions` |
| `Sources/SkiVideoCore/SortingLibrary.swift:90-98` | **modify** — a case for an unreadable source |
| `Tests/SkiVideoViewerTests/FFmpegMediaPipelineTests.swift` | **delete** |
| `Tests/SkiVideoCoreTests/AVFoundationMediaPipelineTests.swift` | **create** |

---

### Task 1: `resize`

**Files:**
- Create: `Sources/SkiVideoCore/MediaPipelineError.swift`
- Create: `Sources/SkiVideoCore/AVFoundationMediaPipeline.swift`
- Create: `Tests/SkiVideoCoreTests/AVFoundationMediaPipelineTests.swift`

**Interfaces:**
- Consumes: `MediaPipeline` (in `Sources/SkiVideoCore/Seams.swift`) —
  `func writeMetadata(athlete: String, to url: URL) async throws` and
  `func resize(source: URL, destination: URL, athlete: String) async throws`.
  Also `makeRealVideoFile(in:name:seconds:fps:)`, an `XCTestCase` extension in
  `Tests/SkiVideoCoreTests/RealVideoFixture.swift`.
- Produces, for Tasks 2–3:
  - `public struct AVFoundationMediaPipeline { public init() }` — **without**
    `MediaPipeline` conformance, which Task 2 adds together with
    `writeMetadata`. Declaring it here would not compile.
  - `public func resize(source: URL, destination: URL, athlete: String) async throws`
  - `static func outputSize(natural: CGSize, transform: CGAffineTransform) -> (Int, Int)`
  - `static func metadata(athlete: String) -> [AVMetadataItem]`
  - `public enum MediaPipelineError: LocalizedError, Equatable { case unreadableSource(String), noVideoTrack(String), exportFailed(String) }`
  - `makeRealVideoFile(in:name:seconds:fps:width:height:)` and
    `makeRotatedVideoFile(in:name:seconds:degrees:fps:)` on `XCTestCase`

- [ ] **Step 1: Write the error type**

Create `Sources/SkiVideoCore/MediaPipelineError.swift`:

```swift
import Foundation

/// What the media pipeline can fail with.
///
/// The ffmpeg pipeline this replaces surfaced whatever the binary wrote to
/// stderr. AVFoundation's own errors are often opaque ("Cannot Open"), so the
/// cases that a user can act on are named here and the file is always included
/// — a sort run touches many clips and "Cannot Open" alone does not say which.
public enum MediaPipelineError: LocalizedError, Equatable {
    /// The asset exists but AVFoundation cannot read it. Matroska, WebM and
    /// most AVI land here.
    case unreadableSource(String)
    case noVideoTrack(String)
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .unreadableSource(name):
            return "\(name) is not in a format this app can read. Convert it to MP4 or MOV first."
        case let .noVideoTrack(name):
            return "\(name) has no video track."
        case let .exportFailed(message):
            return message
        }
    }
}
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/SkiVideoCoreTests/AVFoundationMediaPipelineTests.swift`:

```swift
import AVFoundation
import XCTest
@testable import SkiVideoCore

/// The pipeline, against real generated media.
///
/// Every assertion is on a *property* of the output — dimensions, transform,
/// duration, track presence — never on byte size or achieved bitrate.
/// VideoToolbox behaviour differs between hosts and those figures are flaky.
final class AVFoundationMediaPipelineTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        super.tearDown()
    }

    func testResizeScalesAnOversizeSourceIntoTheBox() async throws {
        let source = try makeRealVideoFile(in: root, name: "big.mov", seconds: 1, fps: 30, width: 3840, height: 2160)
        let destination = root.appendingPathComponent("out/big.mov")
        try await AVFoundationMediaPipeline().resize(source: source, destination: destination, athlete: "Idun")

        let size = try await displaySize(of: destination)
        XCTAssertEqual(size.width, 1920, accuracy: 1)
        XCTAssertEqual(size.height, 1080, accuracy: 1)
    }

    /// The rule is never-upscale, which differs from the ffmpeg pipeline this
    /// replaces: `force_original_aspect_ratio=decrease` enlarges a small source
    /// to fill the box. A 640×360 clip must come back 640×360.
    func testResizeLeavesAnUndersizeSourceAlone() async throws {
        let source = try makeRealVideoFile(in: root, name: "small.mov", seconds: 1, fps: 30, width: 640, height: 360)
        let destination = root.appendingPathComponent("out/small.mov")
        try await AVFoundationMediaPipeline().resize(source: source, destination: destination, athlete: "Idun")

        let size = try await displaySize(of: destination)
        XCTAssertEqual(size.width, 640, accuracy: 1)
        XCTAssertEqual(size.height, 360, accuracy: 1)
    }

    /// Both output dimensions must be even; H.264 4:2:0 cannot encode odd ones.
    /// 1999×1119 scaled to fit gives a fractional height, so this pins the
    /// rounding rather than the scale.
    func testResizeRoundsBothDimensionsToEvenNumbers() async throws {
        let source = try makeRealVideoFile(in: root, name: "odd.mov", seconds: 1, fps: 30, width: 1999, height: 1119)
        let destination = root.appendingPathComponent("out/odd.mov")
        try await AVFoundationMediaPipeline().resize(source: source, destination: destination, athlete: "Idun")

        let size = try await displaySize(of: destination)
        XCTAssertEqual(Int(size.width.rounded()) % 2, 0, "width \(size.width) must be even")
        XCTAssertEqual(Int(size.height.rounded()) % 2, 0, "height \(size.height) must be even")
    }

    /// The riskiest property in this work. A rotated source that loses its
    /// transform comes out sideways, and no fixture with an identity transform
    /// can catch it.
    func testResizePreservesTheSourceRotation() async throws {
        let source = try makeRotatedVideoFile(in: root, name: "portrait.mov", seconds: 1, degrees: 90)
        let destination = root.appendingPathComponent("out/portrait.mov")
        try await AVFoundationMediaPipeline().resize(source: source, destination: destination, athlete: "Idun")

        let size = try await displaySize(of: destination)
        XCTAssertGreaterThan(size.height, size.width,
                             "a 90-degree-rotated source must stay portrait; got \(size)")
    }

    func testResizePreservesTheFrameRate() async throws {
        let source = try makeRealVideoFile(in: root, name: "fast.mov", seconds: 2, fps: 50, width: 1280, height: 720)
        let destination = root.appendingPathComponent("out/fast.mov")
        try await AVFoundationMediaPipeline().resize(source: source, destination: destination, athlete: "Idun")

        let track = try await XCTUnwrap(AVURLAsset(url: destination).loadTracks(withMediaType: .video).first)
        let rate = try await track.load(.nominalFrameRate)
        XCTAssertEqual(rate, 50, accuracy: 2, "forcing 30fps would silently drop half the frames")
    }

    func testResizePreservesTheDuration() async throws {
        let source = try makeRealVideoFile(in: root, name: "len.mov", seconds: 3, fps: 30, width: 1280, height: 720)
        let destination = root.appendingPathComponent("out/len.mov")
        try await AVFoundationMediaPipeline().resize(source: source, destination: destination, athlete: "Idun")

        let duration = try await AVURLAsset(url: destination).load(.duration).seconds
        XCTAssertEqual(duration, 3, accuracy: 0.2)
    }

    func testResizeCreatesIntermediateDirectories() async throws {
        let source = try makeRealVideoFile(in: root, name: "nested.mov", seconds: 1, fps: 30, width: 1280, height: 720)
        let destination = root.appendingPathComponent("a/b/c/nested.mov")
        try await AVFoundationMediaPipeline().resize(source: source, destination: destination, athlete: "Idun")

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testResizeWritesTheAthleteMetadata() async throws {
        let source = try makeRealVideoFile(in: root, name: "meta.mov", seconds: 1, fps: 30, width: 1280, height: 720)
        let destination = root.appendingPathComponent("out/meta.mov")
        try await AVFoundationMediaPipeline().resize(source: source, destination: destination, athlete: "Idun")

        let items = try await AVURLAsset(url: destination).load(.metadata)
        let values = items.compactMap { $0.stringValue }
        XCTAssertTrue(values.contains("Idun"), "expected the athlete in the metadata; got \(values)")
    }

    /// A source with no audio must produce an output with no audio, not a
    /// failure and not a silent track. Screen-recording trims and some drone
    /// footage arrive this way, and `makeRealVideoFile` writes video only —
    /// so every other test in this file is already exercising that path.
    func testResizeOfASilentSourceProducesNoAudioTrack() async throws {
        let source = try makeRealVideoFile(in: root, name: "silent.mov", seconds: 1, fps: 30, width: 1280, height: 720)
        let destination = root.appendingPathComponent("out/silent.mov")
        try await AVFoundationMediaPipeline().resize(source: source, destination: destination, athlete: "Idun")

        let audio = try await AVURLAsset(url: destination).loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty)
    }

    func testResizeOfAnUnreadableSourceReportsTheFilename() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("broken.mkv")
        try Data("not a video".utf8).write(to: source)
        let destination = root.appendingPathComponent("out/broken.mov")

        do {
            try await AVFoundationMediaPipeline().resize(source: source, destination: destination, athlete: "Idun")
            XCTFail("an unreadable source must throw")
        } catch let error as MediaPipelineError {
            XCTAssertEqual(error, .unreadableSource("broken.mkv"))
        }
    }

    // MARK: - helpers

    /// The size the viewer sees: natural size with the preferred transform
    /// applied. Reading `naturalSize` alone would pass a rotated output.
    private func displaySize(of url: URL) async throws -> CGSize {
        let track = try await XCTUnwrap(AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformed = natural.applying(transform)
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }
}
```

- [ ] **Step 3: Extend the fixture helper to take dimensions and a rotation**

`makeRealVideoFile` in `Tests/SkiVideoCoreTests/RealVideoFixture.swift` currently
hard-codes 160×90. Its new signature must be exactly:

```swift
    func makeRealVideoFile(
        in directory: URL,
        name: String,
        seconds: Double,
        fps: Int32 = 30,
        width: Int = 160,
        height: Int = 90
    ) throws -> URL
```

The defaults keep every existing call site compiling unchanged. Then add a
sibling that applies a rotation transform:

```swift
    /// A fixture with a rotation transform, for the one property that generated
    /// media otherwise cannot exercise: every clip written by
    /// `makeRealVideoFile` has an identity transform, so a pipeline that drops
    /// `preferredTransform` passes every other test in the suite.
    func makeRotatedVideoFile(
        in directory: URL,
        name: String,
        seconds: Double,
        degrees: Double,
        fps: Int32 = 30
    ) throws -> URL {
        // Same body as `makeRealVideoFile`, with one addition before
        // `startWriting()`:
        //     input.transform = CGAffineTransform(rotationAngle: degrees * .pi / 180)
        // Extract the shared body rather than copying it a fourth time — this
        // helper is already duplicated across two test targets.
    }
```

Extract the common body into one private function taking a `transform`
parameter; do not add a fourth copy.

- [ ] **Step 4: Run the tests to verify they fail**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test --filter AVFoundationMediaPipelineTests
```

Expected: compile failure — `cannot find 'AVFoundationMediaPipeline' in scope`.

- [ ] **Step 5: Implement `resize`**

Create `Sources/SkiVideoCore/AVFoundationMediaPipeline.swift`. The settings and
the geometry are requirements; the pump loop is a shape.

```swift
import AVFoundation
import Foundation

/// The in-process media pipeline.
///
/// Replaces an ffmpeg-backed one that ran `/usr/bin/env ffmpeg` and so depended
/// on `PATH` — which a Finder-launched app does not have `/opt/homebrew/bin` on,
/// making resize fail for everyone who did not start the app from a terminal.
/// Being in-process also means this compiles for iOS, where `Process` does not
/// exist at all.
///
/// `AVAssetReader`/`AVAssetWriter` rather than `AVAssetExportSession`: the value
/// of the resize step is bitrate reduction — measured on real footage, the
/// sampled source was already 1080p and the step halved the bitrate from 7.41 to
/// 3.70 Mbps — and an export preset would decide that number for us.
// Deliberately does NOT declare `: MediaPipeline` yet — the protocol also
// requires `writeMetadata(athlete:to:)`, which Task 2 adds. Declaring
// conformance here would not compile. Task 2 adds both the method and the
// conformance in one step.
public struct AVFoundationMediaPipeline {
    public init() {}

    /// Bits per second per output pixel. 1920 × 1080 × 1.784 ≈ 3.70 Mbps, which
    /// is what the ffmpeg pipeline produced at 1080p.
    private static let bitsPerPixel = 1.784

    public func resize(source: URL, destination: URL, athlete: String) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let asset = AVURLAsset(url: source)
        guard try await asset.load(.isPlayable) else {
            throw MediaPipelineError.unreadableSource(source.lastPathComponent)
        }
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaPipelineError.noVideoTrack(source.lastPathComponent)
        }

        let natural = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let (outWidth, outHeight) = Self.outputSize(natural: natural, transform: transform)

        // Destination must not exist — AVAssetWriter refuses otherwise.
        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        writer.metadata = Self.metadata(athlete: athlete)

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: outWidth,
                AVVideoHeightKey: outHeight,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int((Double(outWidth * outHeight) * Self.bitsPerPixel).rounded()),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ]
        )
        videoInput.expectsMediaDataInRealTime = false
        // Carried, not baked in. Without this a rotated clip comes out sideways,
        // and every generated fixture has an identity transform, so nothing else
        // would notice.
        videoInput.transform = transform
        writer.add(videoInput)

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            ]
        )
        reader.add(videoOutput)

        // Audio is optional: `-map 0:a?` in the pipeline this replaces. A source
        // without audio must produce an output without audio.
        var audioInput: AVAssetWriterInput?
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128_000,
                ]
            )
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            reader.add(output)
            audioInput = input
            audioOutput = output
        }

        guard reader.startReading() else {
            throw MediaPipelineError.exportFailed(reader.error?.localizedDescription ?? "could not read \(source.lastPathComponent)")
        }
        guard writer.startWriting() else {
            throw MediaPipelineError.exportFailed(writer.error?.localizedDescription ?? "could not write \(destination.lastPathComponent)")
        }
        writer.startSession(atSourceTime: .zero)

        await Self.pump(input: videoInput, from: videoOutput)
        if let audioInput, let audioOutput {
            await Self.pump(input: audioInput, from: audioOutput)
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw MediaPipelineError.exportFailed(writer.error?.localizedDescription ?? "the resize did not complete")
        }
    }

    /// Never upscale: `s = min(1920/displayW, 1080/displayH, 1)`, applied to the
    /// *natural* size because the transform rotates the encoded buffer at
    /// playback. Both results are rounded to even numbers — H.264 4:2:0 cannot
    /// encode odd dimensions.
    static func outputSize(natural: CGSize, transform: CGAffineTransform) -> (Int, Int) {
        let display = natural.applying(transform)
        let displayWidth = abs(display.width)
        let displayHeight = abs(display.height)
        guard displayWidth > 0, displayHeight > 0 else { return (0, 0) }
        let scale = min(1920 / displayWidth, 1080 / displayHeight, 1)
        func even(_ value: Double) -> Int {
            let rounded = Int(value.rounded())
            return rounded % 2 == 0 ? rounded : rounded - 1
        }
        return (even(natural.width * scale), even(natural.height * scale))
    }

    static func metadata(athlete: String) -> [AVMetadataItem] {
        [
            (AVMetadataIdentifier.commonIdentifierTitle, athlete),
            (AVMetadataIdentifier.commonIdentifierArtist, athlete),
            (AVMetadataIdentifier.commonIdentifierDescription, "Athlete: \(athlete)"),
        ].map { identifier, value in
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            return item
        }
    }

    private static func pump(input: AVAssetWriterInput, from output: AVAssetReaderTrackOutput) async {
        let queue = DispatchQueue(label: "media-pipeline.\(input.mediaType.rawValue)")
        await withCheckedContinuation { continuation in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let buffer = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    input.append(buffer)
                }
            }
        }
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && xcodegen generate && swift test
```

Expected: 10 new tests passing; the suite total is 386 + 10 = 396.

- [ ] **Step 7: Mutation-test the battery**

Run a clean unmutated `swift test` first and record the count — a new test
failing on unmutated code makes every mutant look killed, which has already
invalidated a battery in this project.

| # | Mutation | Must be killed by |
|---|---|---|
| M1 | delete `videoInput.transform = transform` | `testResizePreservesTheSourceRotation` |
| M2 | in `outputSize`, drop the `, 1` from the `min` (so it upscales) | `testResizeLeavesAnUndersizeSourceAlone` |
| M3 | in `even`, return `rounded` unchanged | `testResizeRoundsBothDimensionsToEvenNumbers` |
| M4 | `bitsPerPixel` 1.784 → 0.5 | expect **survival** — bitrate is deliberately unasserted; record it |
| M5 | delete the `isPlayable` guard | `testResizeOfAnUnreadableSourceReportsTheFilename` |
| M6 | always add the audio input, even with no audio track | `testResizeOfASilentSourceProducesNoAudioTrack` |
| M7 | in `outputSize`, use `natural` instead of `display` for the scale | `testResizePreservesTheSourceRotation` or the oversize test — if neither, add a rotated *oversize* fixture |

Report every mutant and its killer, including survivors.

- [ ] **Step 8: Commit**

```bash
git add SkiVideoViewer/Sources SkiVideoViewer/Tests
git commit -m "Add the AVFoundation resize"
```

---

### Task 2: `writeMetadata`, and retire ffmpeg

**Files:**
- Modify: `Sources/SkiVideoCore/AVFoundationMediaPipeline.swift`
- Modify: `Tests/SkiVideoCoreTests/AVFoundationMediaPipelineTests.swift`
- Delete: `Sources/SkiVideoViewer/macOS/FFmpegMediaPipeline.swift`
- Delete: `Tests/SkiVideoViewerTests/FFmpegMediaPipelineTests.swift`
- Modify: `Sources/SkiVideoViewer/macOS/SortingWindowController.swift:42`
- Modify: `Sources/SkiVideoCore/SecondaryScreens.swift:9`
- Modify: `Sources/SkiVideoViewer/iOS/IOSSecondaryScreenPresenter.swift:7`

**Interfaces:**
- Consumes from Task 1: `AVFoundationMediaPipeline`, `MediaPipelineError`,
  `AVFoundationMediaPipeline.metadata(athlete:)`.

- [ ] **Step 1: Write the failing tests**

Append to `AVFoundationMediaPipelineTests.swift`:

```swift
    func testWriteMetadataReplacesTheFileInPlace() async throws {
        let source = try makeRealVideoFile(in: root, name: "tag.mov", seconds: 1, fps: 30, width: 1280, height: 720)
        let before = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int

        try await AVFoundationMediaPipeline().writeMetadata(athlete: "Nora", to: source)

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let items = try await AVURLAsset(url: source).load(.metadata)
        XCTAssertTrue(items.compactMap { $0.stringValue }.contains("Nora"))
        XCTAssertNotNil(before)
    }

    /// A remux, not a re-encode: the video track must be carried through
    /// untouched, so the dimensions cannot change.
    func testWriteMetadataDoesNotReEncode() async throws {
        let source = try makeRealVideoFile(in: root, name: "keep.mov", seconds: 1, fps: 30, width: 1280, height: 720)
        try await AVFoundationMediaPipeline().writeMetadata(athlete: "Nora", to: source)

        let track = try await XCTUnwrap(AVURLAsset(url: source).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.width, 1280, accuracy: 1)
        XCTAssertEqual(size.height, 720, accuracy: 1)
    }

    func testWriteMetadataPreservesRotation() async throws {
        let source = try makeRotatedVideoFile(in: root, name: "rot.mov", seconds: 1, degrees: 90)
        try await AVFoundationMediaPipeline().writeMetadata(athlete: "Nora", to: source)

        let size = try await displaySize(of: source)
        XCTAssertGreaterThan(size.height, size.width)
    }

    func testWriteMetadataLeavesNoTemporaryFiles() async throws {
        let source = try makeRealVideoFile(in: root, name: "clean.mov", seconds: 1, fps: 30, width: 1280, height: 720)
        try await AVFoundationMediaPipeline().writeMetadata(athlete: "Nora", to: source)

        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(contents, ["clean.mov"], "temp files leaked: \(contents)")
    }
```

- [ ] **Step 2: Run to verify they fail**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test --filter AVFoundationMediaPipelineTests
```

Expected: failures — `writeMetadata` is unimplemented.

- [ ] **Step 3: Implement `writeMetadata`**

Add to `AVFoundationMediaPipeline`:

```swift
    /// A remux, not an encode — the equivalent of the `-c copy` this replaces —
    /// so there is no encode setting to control and a passthrough export is
    /// right. Passthrough also carries only the tracks AVFoundation recognises,
    /// which reproduces the effect of the old `-map 0:v:0 -map 0:a?`: proprietary
    /// camera telemetry tracks are dropped rather than failing the remux.
    // Task 1 deliberately left the struct without protocol conformance, because
    // the protocol needs both methods. Add it here:
    //     public struct AVFoundationMediaPipeline: MediaPipeline {
    public func writeMetadata(athlete: String, to url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else {
            throw MediaPipelineError.unreadableSource(url.lastPathComponent)
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw MediaPipelineError.exportFailed("could not tag \(url.lastPathComponent)")
        }

        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".metadata-\(UUID().uuidString).\(url.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }

        session.outputURL = temporary
        session.outputFileType = .mov
        session.metadata = Self.metadata(athlete: athlete)
        await session.export()
        guard session.status == .completed else {
            throw MediaPipelineError.exportFailed(session.error?.localizedDescription ?? "could not tag \(url.lastPathComponent)")
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
```

- [ ] **Step 4: Delete the ffmpeg pipeline and its tests**

```bash
git rm SkiVideoViewer/Sources/SkiVideoViewer/macOS/FFmpegMediaPipeline.swift
git rm SkiVideoViewer/Tests/SkiVideoViewerTests/FFmpegMediaPipelineTests.swift
```

- [ ] **Step 5: Switch the composition root and fix two stale doc comments**

`Sources/SkiVideoViewer/macOS/SortingWindowController.swift:42` — replace
`mediaPipeline: FFmpegMediaPipeline(),` with:

```swift
            mediaPipeline: AVFoundationMediaPipeline(),
```

`Sources/SkiVideoCore/SecondaryScreens.swift:9` and
`Sources/SkiVideoViewer/iOS/IOSSecondaryScreenPresenter.swift:7` both explain
that Sort is macOS-only *because* the pipeline shells out via `Process`. That
reason is now false — the pipeline is portable, and Sort stays macOS-only
because the iPad sorting UI has not been built. Reword both to say that, and do
not change `canPresentSorting`, which stays `false`.

- [ ] **Step 6: Regenerate, run every gate**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer
xcodegen generate
swift test
xcodebuild -scheme SkiVideoViewer-macOS -destination 'platform=macOS' build
xcodebuild -scheme SkiVideoViewer-iPad -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build
grep -rn "ffmpeg\|Process(" Sources/ --include="*.swift"
```

Expected: tests green, both builds succeeding, and the `grep` returning only the
`SortingSheet.swift` copy string mentioning ffmpeg — fix that copy too, since
it now describes something that no longer happens.

- [ ] **Step 7: Mutation-test**

Clean baseline first, then:

| # | Mutation | Must be killed by |
|---|---|---|
| M8 | delete `session.metadata = …` | `testWriteMetadataReplacesTheFileInPlace` |
| M9 | `AVAssetExportPresetPassthrough` → `AVAssetExportPreset640x480` | `testWriteMetadataDoesNotReEncode` |
| M10 | delete the `replaceItemAt` call | `testWriteMetadataReplacesTheFileInPlace` |
| M11 | delete the `defer { try? FileManager.default.removeItem(at: temporary) }` | `testWriteMetadataLeavesNoTemporaryFiles` |

- [ ] **Step 8: Commit**

```bash
git add -A SkiVideoViewer/Sources SkiVideoViewer/Tests
git commit -m "Replace the ffmpeg pipeline with the AVFoundation one"
```

---

### Task 3: Format policy

**Files:**
- Modify: `Sources/SkiVideoCore/VideoLibrary.swift:16-18`
- Modify: `Sources/SkiVideoCore/SortingLibrary.swift:90-98`
- Modify: `Sources/SkiVideoCore/SortingModel.swift`
- Test: `Tests/SkiVideoCoreTests/VideoLibraryTests.swift` (existing)

**Interfaces:**
- Consumes from Tasks 1–2: `MediaPipelineError.unreadableSource(String)`.

- [ ] **Step 1: Write the failing test**

Add to the existing `Tests/SkiVideoCoreTests/VideoLibraryTests.swift`:

```swift
    /// `.mkv` is not merely unsupported by the pipeline — `AVPlayer` cannot open
    /// it either. Listing it put files in the sidebar that fail on selection.
    /// Verified against a real Matroska file: `AVURLAsset.load(.isPlayable)`
    /// fails with "Cannot Open", where the same probe on an `.mp4` succeeds.
    func testTheLibraryDoesNotListFormatsAVFoundationCannotOpen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let athlete = root.appendingPathComponent("Idun", isDirectory: true)
        try FileManager.default.createDirectory(at: athlete, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["run.mp4", "run.mov", "run.m4v", "run.mkv", "run.webm", "run.avi"] {
            try Data("x".utf8).write(to: athlete.appendingPathComponent(name))
        }

        let groups = try VideoLibrary.scan(root)
        let listed = Set((groups.first?.videos ?? []).map { $0.lastPathComponent })
        XCTAssertEqual(listed, ["run.mp4", "run.mov", "run.m4v"])
    }
```

- [ ] **Step 2: Run to verify it fails**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test --filter testTheLibraryDoesNotListFormatsAVFoundationCannotOpen
```

Expected: FAIL — the set also contains `run.mkv`, `run.webm`, `run.avi`.

- [ ] **Step 3: Narrow `supportedExtensions`**

`Sources/SkiVideoCore/VideoLibrary.swift:16-18`:

```swift
    /// Only what AVFoundation can actually open.
    ///
    /// `mkv`, `webm` and `avi` were listed until 2026-08-07, which put files in
    /// the sidebar that `AVPlayer` then refused to play — measured against a
    /// real Matroska file from the library, `AVURLAsset.load(.isPlayable)`
    /// fails with "Cannot Open" where the same probe on an `.mp4` returns true.
    /// Removing them fixes that rather than dropping a capability.
    public static let supportedExtensions: Set<String> = [
        "mp4", "mov", "m4v",
    ]
```

- [ ] **Step 4: Reject an unreadable source in the sorting flow**

The pipeline already throws `MediaPipelineError.unreadableSource`, and
`SortingModel.enqueueResize` surfaces a thrown error, so no new plumbing is
needed — but nothing proves that end to end. Read `SortingModel.swift:305-330`
to confirm the error reaches `errorMessage`, then pin it.

The fake pipeline in `Tests/SkiVideoCoreTests/FakeSeams.swift` needs a way to
fail. Add to it:

```swift
    /// Set to make the next `resize` throw. The real pipeline throws
    /// `MediaPipelineError.unreadableSource` for Matroska and friends, and
    /// nothing pinned that the message reaches the user.
    var resizeError: Error?
```

and throw it at the top of the fake's `resize`:

```swift
        if let resizeError { throw resizeError }
```

Then add to `Tests/SkiVideoCoreTests/SortingFlowTests.swift`:

```swift
    func testAResizeFailureSurfacesItsMessageToTheUser() async throws {
        let pipeline = FakeMediaPipeline()
        pipeline.resizeError = MediaPipelineError.unreadableSource("run.mkv")
        let model = try makeModel(pipeline: pipeline)

        model.tagCurrentVideo()

        XCTAssertEqual(
            model.errorMessage,
            "run.mkv is not in a format this app can read. Convert it to MP4 or MOV first.",
            "a resize failure must reach the user, not vanish into the queue"
        )
    }
```

`FakeMediaPipeline` is the real type name (`FakeSeams.swift:89`, a
`final class … @unchecked Sendable`, so `resizeError` is a `var` on a reference
type and the test can set it after construction). `makeModel` is the real
helper (`SortingFlowTests.swift:39`) — read its signature and match whatever it
needs to reach a taggable state, which may be more than a pipeline.

The assertion on the exact string is the point: it pins that
`MediaPipelineError`'s `errorDescription` is what surfaces, not a generic
wrapper that would read "The operation couldn't be completed."

- [ ] **Step 5: Run every gate**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test
xcodebuild -scheme SkiVideoViewer-macOS -destination 'platform=macOS' build
xcodebuild -scheme SkiVideoViewer-iPad -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build
```

- [ ] **Step 6: Mutation-test**

| # | Mutation | Must be killed by |
|---|---|---|
| M12 | add `"mkv"` back to `supportedExtensions` | `testTheLibraryDoesNotListFormatsAVFoundationCannotOpen` |
| M13 | in the fake pipeline, swallow `resizeError` instead of throwing | the new sorting-flow test |

- [ ] **Step 7: Commit**

```bash
git add SkiVideoViewer/Sources SkiVideoViewer/Tests
git commit -m "List only the formats AVFoundation can open"
```

---

## Done when

- Tests green on macOS, both app targets build, iPad UI suites unaffected.
- `grep -rn "ffmpeg\|Process(" Sources/ --include="*.swift"` returns nothing.
- Resize works from a Finder-launched build — **a human must check this**, since
  it is the bug that started the work and it cannot be reproduced from a
  terminal-launched process.

## Carried forward — not this plan's work

- **iPad Sort & Resize.** The blocker is gone but no iPad sorting UI exists and
  `canPresentSorting` stays `false`. Useful finding for that spec: `organized/`
  and `organized_resize/` are both `source.appendingPathComponent(...)`
  (`SortingModel.swift:170-171`), so a single security scope covers reading,
  folder creation, moving and writing.
- **The 14 Silvretta `.mkv` files** stop being listed. They are already
  unplayable, so nothing that works today breaks, but converting them once with
  the existing ffmpeg install is the remedy if they are wanted.
- **Quality comparison.** Average bitrate is not CRF; matching 3.7 Mbps
  nominally does not mean matching quality clip-for-clip, and busy snow spray is
  where they will diverge. Needs eyeballing on a real run.
- **Progress reporting.** `AVAssetWriter` could report it where ffmpeg could
  not; not designed.
