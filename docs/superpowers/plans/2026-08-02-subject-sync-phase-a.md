# Subject Sync, Phase A (core) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring subject detection into the app as a library, store the result as a sidecar beside each clip, and give `ComparisonModel` a way to apply a detected sync point — with no UI.

**Architecture:** Six detection files port from the `landmark-align` worktree into `SkiVideoCore` unchanged in behaviour. On top of them sit a Codable `ClipAnalysis` with sidecar persistence, an async `SubjectAnalyzer` that produces one, and a `SubjectPickModel` holding the operator's selection. `ComparisonModel` gains an additive `applySync` and a published `syncOrigin`.

**Tech Stack:** Swift 6.1 (language mode 5), Vision, AVFoundation, CoreImage, CoreGraphics, Combine. SwiftPM. macOS 13 / iOS 17.

**Spec:** `docs/superpowers/specs/2026-08-02-subject-sync-design.md`

## Global Constraints

- Target the branch `subject-sync-core`, cut from `main`. **Do not touch** `ContentView.swift`, `ComparisonControlBar.swift`, `ComparisonScrubber.swift`, `ViewerModel.swift`, `Timecode.swift`, or anything under `Sources/SkiVideoViewer/`. `viewer-redesign` is in flight in those files. Phase A is `SkiVideoCore` plus its tests, and exactly two additions to `ComparisonModel.swift`.
- `SkiVideoCore` supports **macOS 13 and iOS 17**. `VNTrack*ImageRegistrationRequest` and any other macOS 14+ / iOS 17+-only Vision API are forbidden. `VNDetectHumanBodyPoseRequest` and `VNTranslationalImageRegistrationRequest` are available and are what this uses.
- Everything crossing a target boundary is `public`, including memberwise initialisers — SwiftPM does not synthesise public inits.
- All coordinates crossing a public API are normalised to the frame, **origin top-left, y increasing downward**. Vision's bottom-left origin is converted exactly once, in `PoseDetector`.
- Detection constants are ported verbatim and are not to be re-tuned in this plan: `initialJumpFraction 0.06`, `speedMultiplier 4.0`, `speedFloor 0.02`, `widenPerMiss 0.5`, `maxHeightRatio 1.15`, `heightWidenPerMiss 0.1`, `maxMisses 10`, `cutOnAmbiguity true`, `mergeGapSeconds 0`, `minSamples 8`, `baselinePercentile 0.10`, `thresholdMultiplier 1.8`, `sustainedRiseSeconds 0.5`, `quietCeiling 5.0`, `sustainedQuietSeconds 0.5`, sampling `25 fps` at `320 px`.
- **NEVER** use `CIContext.render(toBitmap:rowBytes:bounds:format:colorSpace:)` with `.R8` and a DeviceGray colour space — it silently returns all zeros on this machine and has cost this project three debugging cycles. Render via `CIContext.createCGImage`, then draw into a `CGContext` backed by your byte buffer.
- `String(format: "%@", someString.utf8String!)` crashes with SIGTRAP. Use `%s` with `utf8String`, or pass the Swift `String` directly.
- Test constants must be **asymmetric** — a displacement of `(0.013, -0.007)`, never `(0.01, 0.01)` — and **box aspect ratios must vary within a test**. A uniform `width = 0.4 * height` let a height gate be rewritten as a width gate with every test still green, twice in the previous plan.
- Every load-bearing test is verified by **mutation**: break the rule it targets, confirm the test fails, revert, and report both outcomes. Four tests in the previous plan passed regardless of the logic they claimed to cover, and each was found only this way. A surviving mutation means the test is worthless — strengthen it and say so.
- Build/test: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` and `swift test` from `SkiVideoViewer/`.
- Commit after each task.

## Source of the ported code

The worktree `/Users/ulfnielsen/Ski/ski-landmark-align/SkiVideoViewer` at branch
`landmark-align`. Copy files from there; do not retype them.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/SkiVideoCore/FrameRegistration.swift` (port) | Vision image registration; recovers camera motion between frames |
| `Sources/SkiVideoCore/PoseDetection.swift` (port) | `PoseDetection`, `FrameDetections` value types |
| `Sources/SkiVideoCore/PoseDetector.swift` (port) | Vision body-pose detection; the sole coordinate conversion |
| `Sources/SkiVideoCore/TrackletLinker.swift` (port) | Commit-and-follow linking with motion-derived gates |
| `Sources/SkiVideoCore/SubjectCandidates.swift` (port) | Grouping tracklets into segments |
| `Sources/SkiVideoCore/SubjectRunStart.swift` (port + fold) | Run start inside the subject's box; also hosts `ForegroundSample` and `RunStart` |
| `Sources/SkiVideoCore/ClipFrameReader.swift` (port) | Sequential `AVAssetReader` decode at a target rate and width |
| `Sources/SkiVideoCore/ClipAnalysis.swift` (create) | Codable model, sidecar naming, staleness |
| `Sources/SkiVideoCore/ClipAnalysisStore.swift` (create) | Sidecar read/write |
| `Sources/SkiVideoCore/SubjectAnalyzer.swift` (create) | Async read → detect → link → group |
| `Sources/SkiVideoCore/SubjectPickModel.swift` (create) | Selection state and overlap exclusion |
| `Sources/SkiVideoCore/ComparisonModel.swift` (modify) | `applySync`, `syncOrigin` |
| `Tests/SkiVideoCoreTests/TestImageFactory.swift` (port) | Textured synthetic frames |
| `Tests/SkiVideoCoreTests/FrameRegistrationTests.swift` (port) | |
| `Tests/SkiVideoCoreTests/TrackletLinkerTests.swift` (port) | |
| `Tests/SkiVideoCoreTests/SubjectCandidatesTests.swift` (port) | |
| `Tests/SkiVideoCoreTests/SubjectRunStartTests.swift` (port) | |
| `Tests/SkiVideoCoreTests/ClipAnalysisTests.swift` (create) | Round-trip, staleness, unknown kind |
| `Tests/SkiVideoCoreTests/ClipAnalysisStoreTests.swift` (create) | Missing, unwritable, unparseable |
| `Tests/SkiVideoCoreTests/SubjectPickModelTests.swift` (create) | Overlap exclusion |
| `Tests/SkiVideoCoreTests/SubjectAnalyzerTests.swift` (create) | End-to-end against a real clip |

---

### Task 1: Port the detection core

**Files:**
- Create (copy from the worktree): the seven `Sources/SkiVideoCore/*.swift` marked "port" above
- Create (copy): `Tests/SkiVideoCoreTests/{TestImageFactory,FrameRegistrationTests,TrackletLinkerTests,SubjectCandidatesTests,SubjectRunStartTests}.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `PoseDetection`, `FrameDetections`, `PoseDetector.detections(in:)`, `Tracklet`, `TrackletLinker.link(...)`, `SubjectCandidate`, `SubjectCandidates.candidates(from:...)`, `ForegroundSample`, `RunStart`, `SubjectRunStart.{profile,runStart,detect,Outcome}`, `ClipFrameReader.frames(from:fps:targetWidth:from:to:)`

- [ ] **Step 1: Copy the source files**

```bash
W=/Users/ulfnielsen/Ski/ski-landmark-align/SkiVideoViewer
cp $W/Sources/SkiVideoCore/{FrameRegistration,PoseDetection,PoseDetector,TrackletLinker,SubjectCandidates,SubjectRunStart}.swift Sources/SkiVideoCore/
cp $W/Sources/RegistrationLab/ClipFrameReader.swift Sources/SkiVideoCore/
```

- [ ] **Step 2: Make `ClipFrameReader` public**

It was internal to an executable target. Make the enum, its `ReadError`, and `frames(from:fps:targetWidth:from:to:)` `public`, and give `ReadError` a `public init`. Change nothing else.

- [ ] **Step 3: Fold the two shared types into `SubjectRunStart`, and do not port `RunStartDetector`**

`ForegroundSample` and `RunStart` currently live in `RunStartDetector.swift`, which also holds the **whole-frame** run-start detector. That detector is measured not to work for this purpose — it ranked stationary bystanders above the racer and fired ~15 s late — and the app must not be able to call it. Leaving two detectors in a tree invites wiring the wrong one; that exact reasoning already deleted `SkierStartDetector` earlier in this project.

So: move `ForegroundSample` and `RunStart` verbatim into `SubjectRunStart.swift`, and do **not** copy `RunStartDetector.swift`.

One test depends on the old rule as a contrast. Preserve it by adding to `SubjectRunStart`:

```swift
    /// The rule `SubjectRunStart.runStart` replaced: the sample after the
    /// *last* sustained quiet stretch.
    ///
    /// Kept **only** so the test that distinguishes the two rules has
    /// something to distinguish against — a test asserting "first, not last"
    /// proves nothing if the last-based answer is unavailable to compare with.
    /// It is deliberately not `public`: measured on a whole frame it ranked
    /// bystanders above the racer, and on a subject-local signal it reads
    /// mid-run dips as quiet. Nothing outside the tests may call it.
    static func lastQuietRunStart(
        in samples: [ForegroundSample],
        baselinePercentile: Double = 0.10,
        thresholdMultiplier: Double = 1.8,
        sustainedQuietSeconds: Double = 1.0
    ) -> RunStart?
```

Its body is `RunStartDetector.runStart`'s, copied verbatim from the worktree.

- [ ] **Step 4: Copy the tests and repoint them**

```bash
cp $W/Tests/SkiVideoViewerTests/{TestImageFactory,FrameRegistrationTests,TrackletLinkerTests,SubjectCandidatesTests,SubjectRunStartTests}.swift Tests/SkiVideoCoreTests/
```

In `SubjectRunStartTests`, the premise assertion in `testTakesFirstSustainedRiseNotTheLast` reads `RunStartDetector.runStart(in:)`; change it to `SubjectRunStart.lastQuietRunStart(in:)`. It must still assert that the contrast rule returns **12.0** on that data — that assertion is what makes the test meaningful, so do not weaken it to a range or delete it.

Check every copied test compiles against `@testable import SkiVideoCore` rather than the worktree's `SkiVideoViewerTests` target.

- [ ] **Step 5: Build and run**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'TrackletLinkerTests|SubjectCandidatesTests|SubjectRunStartTests|FrameRegistrationTests'
```

Expected: all pass. The worktree had these green at 83 tests total; report the count you get and any that fail, with the failure text. **A test that fails after a copy is a finding about the port, not something to edit away** — investigate before changing an assertion.

- [ ] **Step 6: Re-verify two mutations survived the port**

Ported tests can silently stop discriminating when their target moves. Run both, revert each:

1. In `TrackletLinker`, replace the speed-derived `base` with the constant `initialJumpFraction`. Expected: `testAFastTrackToleratesAJumpASlowTrackRejects` fails.
2. In `SubjectRunStart.runStart`, delete the sustained-quiet precondition so it never returns `.alreadyRunning`. Expected: `testASubjectNeverStillIsReportedAsAlreadyRunning` and `testQuietCeilingIsAbsoluteNotRelativeToTheBaseline` fail.

Report both outcomes. If either survives, say so and fix the test before continuing.

- [ ] **Step 7: Commit**

```bash
git add Sources/SkiVideoCore Tests/SkiVideoCoreTests
git commit -m "Port subject detection into SkiVideoCore"
```

---

### Task 2: The analysis model and its sidecar

**Files:**
- Create: `Sources/SkiVideoCore/ClipAnalysis.swift`
- Create: `Sources/SkiVideoCore/ClipAnalysisStore.swift`
- Test: `Tests/SkiVideoCoreTests/ClipAnalysisTests.swift`, `Tests/SkiVideoCoreTests/ClipAnalysisStoreTests.swift`

**Interfaces:**
- Consumes: `SubjectCandidate`, `PoseDetection`, `RunStart` from Task 1
- Produces: `ClipAnalysis`, `AnalysisParameters`, `AnalysedSegment`, `SegmentPreview`, `SubjectPick`, `StoredRunStart`, `ClipAnalysisStore.{sidecarURL,load,save}` — Tasks 3, 4 and Phase B all consume these

- [ ] **Step 1: Write the failing tests**

`Tests/SkiVideoCoreTests/ClipAnalysisTests.swift`:

```swift
import XCTest
@testable import SkiVideoCore

final class ClipAnalysisTests: XCTestCase {
    private func parameters(fps: Double = 25) -> AnalysisParameters {
        AnalysisParameters(
            fps: fps, detectionWidth: 320, initialJump: 0.06, speedMultiplier: 4.0,
            maxHeightRatio: 1.15, maxMisses: 10, cutOnAmbiguity: true, minSamples: 8
        )
    }

    private func analysis(runStart: StoredRunStart?) -> ClipAnalysis {
        ClipAnalysis(
            version: 1,
            analysedAt: Date(timeIntervalSince1970: 1_754_121_660),
            parameters: parameters(),
            segments: [
                AnalysedSegment(
                    id: 1, firstSeen: 29.92, lastSeen: 46.32,
                    detectionCount: 408, peakHeightFraction: 0.53,
                    previews: [
                        SegmentPreview(time: 29.92, box: CGRect(x: 0.55, y: 0.15, width: 0.07, height: 0.17)),
                        SegmentPreview(time: 39.41, box: CGRect(x: 0.61, y: 0.13, width: 0.11, height: 0.29)),
                    ]
                ),
            ],
            subject: runStart.map { SubjectPick(segmentIDs: [3, 4, 5, 1], runStart: $0) }
        )
    }

    func testRoundTripsAStartedRunStart() throws {
        let original = analysis(runStart: .started(time: 18.64, baseline: 1.89, threshold: 3.39))
        let decoded = try JSONDecoder().decode(
            ClipAnalysis.self, from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded.segments.first?.previews.last?.box.height ?? 0, 0.29, accuracy: 1e-9)
        XCTAssertEqual(decoded.subject?.segmentIDs, [3, 4, 5, 1])
        guard case let .started(time, baseline, threshold) = decoded.subject?.runStart else {
            return XCTFail("expected started, got \(String(describing: decoded.subject?.runStart))")
        }
        XCTAssertEqual(time, 18.64, accuracy: 1e-9)
        XCTAssertEqual(baseline, 1.89, accuracy: 1e-9)
        XCTAssertEqual(threshold, 3.39, accuracy: 1e-9)
    }

    func testRoundTripsAnAlreadyRunningRunStart() throws {
        let original = analysis(runStart: .alreadyRunning(firstSeen: 0.12))
        let decoded = try JSONDecoder().decode(
            ClipAnalysis.self, from: JSONEncoder().encode(original)
        )

        guard case let .alreadyRunning(firstSeen) = decoded.subject?.runStart else {
            return XCTFail("expected alreadyRunning")
        }
        XCTAssertEqual(firstSeen, 0.12, accuracy: 1e-9)
    }

    func testRoundTripsWithNoSubjectPicked() throws {
        let decoded = try JSONDecoder().decode(
            ClipAnalysis.self, from: JSONEncoder().encode(analysis(runStart: nil))
        )
        XCTAssertNil(decoded.subject)
        XCTAssertEqual(decoded.segments.count, 1)
    }

    func testAnUnknownRunStartKindFailsToDecode() throws {
        // A later version may add a kind. Decoding must fail loudly rather
        // than silently becoming `started` at time zero, which would apply a
        // wrong sync point with no indication anything went wrong.
        var json = String(
            data: try JSONEncoder().encode(
                analysis(runStart: .started(time: 18.64, baseline: 1.89, threshold: 3.39))
            ),
            encoding: .utf8
        )!
        json = json.replacingOccurrences(of: "\"started\"", with: "\"teleported\"")

        XCTAssertThrowsError(
            try JSONDecoder().decode(ClipAnalysis.self, from: Data(json.utf8))
        )
    }

    func testParametersMatchingIsExactAndOrderIndependent() {
        XCTAssertTrue(parameters().matches(parameters()))
        XCTAssertFalse(parameters(fps: 30).matches(parameters(fps: 25)))
    }

    func testStalenessIsReportedWithoutMutatingTheAnalysis() {
        let stored = analysis(runStart: .started(time: 18.64, baseline: 1.89, threshold: 3.39))
        let current = parameters(fps: 30)

        XCTAssertTrue(stored.isStale(against: current))
        // The pick and the time survive: a run start is a time and a time does
        // not expire, and the pick is expensive human input.
        XCTAssertEqual(stored.subject?.segmentIDs, [3, 4, 5, 1])
        XCTAssertFalse(stored.isStale(against: parameters()))
    }
}
```

`Tests/SkiVideoCoreTests/ClipAnalysisStoreTests.swift`:

```swift
import XCTest
@testable import SkiVideoCore

final class ClipAnalysisStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func clip(_ name: String = "C0094.MP4") -> URL {
        directory.appendingPathComponent(name)
    }

    private var sample: ClipAnalysis {
        ClipAnalysis(
            version: 1,
            analysedAt: Date(timeIntervalSince1970: 1_754_121_660),
            parameters: AnalysisParameters(
                fps: 25, detectionWidth: 320, initialJump: 0.06, speedMultiplier: 4.0,
                maxHeightRatio: 1.15, maxMisses: 10, cutOnAmbiguity: true, minSamples: 8
            ),
            segments: [],
            subject: nil
        )
    }

    func testSidecarSitsBesideTheClipAndKeepsItsStem() {
        XCTAssertEqual(
            ClipAnalysisStore.sidecarURL(for: clip()).lastPathComponent,
            "C0094.skianalysis.json"
        )
        XCTAssertEqual(
            ClipAnalysisStore.sidecarURL(for: clip()).deletingLastPathComponent().path,
            directory.path
        )
    }

    func testLoadReturnsNilWhenThereIsNoSidecar() {
        XCTAssertNil(ClipAnalysisStore.load(for: clip()))
    }

    func testSaveThenLoadRoundTrips() throws {
        try ClipAnalysisStore.save(sample, for: clip())
        XCTAssertEqual(ClipAnalysisStore.load(for: clip())?.parameters.fps, 25)
    }

    func testLoadReturnsNilForAnUnparseableSidecarAndLeavesItAlone() throws {
        let url = ClipAnalysisStore.sidecarURL(for: clip())
        try Data("{ not json".utf8).write(to: url)

        XCTAssertNil(ClipAnalysisStore.load(for: clip()))
        // Never silently replace a file we could not read: it may be a newer
        // version, or hand-edited, and overwriting it would destroy work.
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{ not json")
    }

    func testSaveThrowsRatherThanFailingSilentlyWhenTheFolderIsUnwritable() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: directory.path
            )
        }

        XCTAssertThrowsError(try ClipAnalysisStore.save(sample, for: clip()))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'ClipAnalysisTests|ClipAnalysisStoreTests'`
Expected: compile failure — none of these types exist.

- [ ] **Step 3: Write the model**

`Sources/SkiVideoCore/ClipAnalysis.swift`:

```swift
import CoreGraphics
import Foundation

/// The settings that produced an analysis, recorded so a later build can tell
/// a stored result apart from one it would produce now.
public struct AnalysisParameters: Codable, Equatable, Sendable {
    public let fps: Double
    public let detectionWidth: Double
    public let initialJump: Double
    public let speedMultiplier: Double
    public let maxHeightRatio: Double
    public let maxMisses: Int
    public let cutOnAmbiguity: Bool
    public let minSamples: Int

    public init(
        fps: Double, detectionWidth: Double, initialJump: Double,
        speedMultiplier: Double, maxHeightRatio: Double, maxMisses: Int,
        cutOnAmbiguity: Bool, minSamples: Int
    ) {
        self.fps = fps
        self.detectionWidth = detectionWidth
        self.initialJump = initialJump
        self.speedMultiplier = speedMultiplier
        self.maxHeightRatio = maxHeightRatio
        self.maxMisses = maxMisses
        self.cutOnAmbiguity = cutOnAmbiguity
        self.minSamples = minSamples
    }

    /// The values the app analyses with today.
    public static let current = AnalysisParameters(
        fps: 25, detectionWidth: 320, initialJump: 0.06, speedMultiplier: 4.0,
        maxHeightRatio: 1.15, maxMisses: 10, cutOnAmbiguity: true, minSamples: 8
    )

    public func matches(_ other: AnalysisParameters) -> Bool { self == other }
}

/// One moment of a segment, enough to redraw a thumbnail from the video
/// without caching an image next to the footage.
public struct SegmentPreview: Codable, Equatable, Sendable {
    public let time: TimeInterval
    public let box: CGRect

    public init(time: TimeInterval, box: CGRect) {
        self.time = time
        self.box = box
    }
}

/// A contiguous run of detections believed to be one person.
public struct AnalysedSegment: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let firstSeen: TimeInterval
    public let lastSeen: TimeInterval
    public let detectionCount: Int
    public let peakHeightFraction: Double
    public let previews: [SegmentPreview]

    public init(
        id: Int, firstSeen: TimeInterval, lastSeen: TimeInterval,
        detectionCount: Int, peakHeightFraction: Double, previews: [SegmentPreview]
    ) {
        self.id = id
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.detectionCount = detectionCount
        self.peakHeightFraction = peakHeightFraction
        self.previews = previews
    }

    /// Two segments overlapping in time cannot be the same person, so they can
    /// never both belong to one pick.
    public func overlaps(_ other: AnalysedSegment) -> Bool {
        firstSeen <= other.lastSeen && other.firstSeen <= lastSeen
    }
}

/// A run start as stored. Mirrors `SubjectRunStart.Outcome`, minus the cases
/// that mean "there is nothing to store".
public enum StoredRunStart: Codable, Equatable, Sendable {
    case started(time: TimeInterval, baseline: Double, threshold: Double)
    /// The subject was never demonstrably still, so their run began at or
    /// before this time. Not the same as a measured start, and the UI must not
    /// present it as one.
    case alreadyRunning(firstSeen: TimeInterval)

    /// The time to sync on, whichever case it is.
    public var syncTime: TimeInterval {
        switch self {
        case let .started(time, _, _): return time
        case let .alreadyRunning(firstSeen): return firstSeen
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, time, baseline, threshold, firstSeen
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An unrecognised kind throws rather than defaulting. A future version
        // may add one, and silently reading it as `started` at time zero would
        // apply a wrong sync point with nothing to indicate it.
        switch try container.decode(String.self, forKey: .kind) {
        case "started":
            self = .started(
                time: try container.decode(TimeInterval.self, forKey: .time),
                baseline: try container.decode(Double.self, forKey: .baseline),
                threshold: try container.decode(Double.self, forKey: .threshold)
            )
        case "alreadyRunning":
            self = .alreadyRunning(
                firstSeen: try container.decode(TimeInterval.self, forKey: .firstSeen)
            )
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "unrecognised run-start kind '\(other)'"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .started(time, baseline, threshold):
            try container.encode("started", forKey: .kind)
            try container.encode(time, forKey: .time)
            try container.encode(baseline, forKey: .baseline)
            try container.encode(threshold, forKey: .threshold)
        case let .alreadyRunning(firstSeen):
            try container.encode("alreadyRunning", forKey: .kind)
            try container.encode(firstSeen, forKey: .firstSeen)
        }
    }
}

/// The operator's answer: which segments are the athlete, and when they went.
public struct SubjectPick: Codable, Equatable, Sendable {
    public let segmentIDs: [Int]
    public let runStart: StoredRunStart

    public init(segmentIDs: [Int], runStart: StoredRunStart) {
        self.segmentIDs = segmentIDs
        self.runStart = runStart
    }
}

public struct ClipAnalysis: Codable, Equatable, Sendable {
    public let version: Int
    public let analysedAt: Date
    public let parameters: AnalysisParameters
    public let segments: [AnalysedSegment]
    public let subject: SubjectPick?

    public init(
        version: Int, analysedAt: Date, parameters: AnalysisParameters,
        segments: [AnalysedSegment], subject: SubjectPick?
    ) {
        self.version = version
        self.analysedAt = analysedAt
        self.parameters = parameters
        self.segments = segments
        self.subject = subject
    }

    /// Whether this was produced by settings other than the given ones.
    ///
    /// Staleness is reported, never acted on. A run start is a time and a time
    /// does not expire; the segment list is working data; and the pick is
    /// expensive human input. Recomputing silently would discard a decision the
    /// operator made in order to chase a number that was probably already right.
    public func isStale(against current: AnalysisParameters) -> Bool {
        !parameters.matches(current)
    }

    public func with(subject: SubjectPick?) -> ClipAnalysis {
        ClipAnalysis(
            version: version, analysedAt: analysedAt, parameters: parameters,
            segments: segments, subject: subject
        )
    }
}
```

- [ ] **Step 4: Write the store**

`Sources/SkiVideoCore/ClipAnalysisStore.swift`:

```swift
import Foundation

/// Reads and writes the sidecar that sits beside a clip.
///
/// A sidecar rather than a library index or an application-support cache
/// because it travels with the footage: copy an athlete's folder to another
/// machine and the analysis goes with it, and the file stays readable and
/// correctable by hand.
public enum ClipAnalysisStore {
    public static let fileExtension = "skianalysis.json"

    public static func sidecarURL(for clip: URL) -> URL {
        clip.deletingPathExtension().appendingPathExtension(fileExtension)
    }

    /// The stored analysis, or nil when there is none or it cannot be read.
    ///
    /// An unreadable sidecar reads as absent rather than as an error: it may be
    /// a newer version or hand-edited, and the caller's only sensible response
    /// is to offer analysis again. `save` must never overwrite one it could not
    /// parse — see its note.
    public static func load(for clip: URL) -> ClipAnalysis? {
        guard let data = try? Data(contentsOf: sidecarURL(for: clip)) else { return nil }
        return try? decoder.decode(ClipAnalysis.self, from: data)
    }

    /// Writes the sidecar, throwing if it cannot. Callers surface the failure
    /// to the operator once and carry on using the analysis in memory — an
    /// unwritable footage folder is a persistence problem, not an analysis
    /// failure.
    public static func save(_ analysis: ClipAnalysis, for clip: URL) throws {
        try encoder.encode(analysis).write(to: sidecarURL(for: clip), options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
```

- [ ] **Step 5: Run the tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'ClipAnalysisTests|ClipAnalysisStoreTests'`
Expected: all pass.

`CGRect` is `Codable` on both platforms, so `SegmentPreview` needs no custom coding. If it turns out not to be on the iOS 17 SDK, encode `[x, y, width, height]` explicitly and say so in your report.

- [ ] **Step 6: Mutation-check**

One at a time, reverting each; report every outcome including survivals.

1. Change the unrecognised-kind `throw` to `self = .started(time: 0, baseline: 0, threshold: 0)`. Expected: `testAnUnknownRunStartKindFailsToDecode` fails.
2. Make `load` return a freshly-constructed empty `ClipAnalysis` instead of nil on a decode failure, and have `save` run unconditionally after it. Expected: `testLoadReturnsNilForAnUnparseableSidecarAndLeavesItAlone` fails.
3. Change `isStale` to always return `false`. Expected: `testStalenessIsReportedWithoutMutatingTheAnalysis` fails.

- [ ] **Step 7: Commit**

```bash
git add Sources/SkiVideoCore/ClipAnalysis.swift Sources/SkiVideoCore/ClipAnalysisStore.swift Tests/SkiVideoCoreTests/ClipAnalysisTests.swift Tests/SkiVideoCoreTests/ClipAnalysisStoreTests.swift
git commit -m "Store a clip's subject analysis as a sidecar beside it"
```

---

### Task 3: The analyzer

**Files:**
- Create: `Sources/SkiVideoCore/SubjectAnalyzer.swift`
- Test: `Tests/SkiVideoCoreTests/SubjectAnalyzerTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1-2
- Produces: `SubjectAnalyzer.analyse(clip:parameters:previewCount:progress:)` returning `ClipAnalysis`, and `SubjectAnalyzer.runStart(clip:analysis:segmentIDs:)` returning `SubjectRunStart.Outcome`

- [ ] **Step 1: Write the analyzer**

`Sources/SkiVideoCore/SubjectAnalyzer.swift`:

```swift
import AVFoundation
import CoreGraphics
import Foundation

/// Turns a clip into a list of candidate segments, and a chosen set of those
/// segments into a run start.
///
/// Roughly 20s for a 45s clip on this machine, almost all of it Vision. That is
/// why it reports progress and honours cancellation: a job that long with no
/// escape is the wrong shape for a UI.
public enum SubjectAnalyzer {
    public enum AnalysisError: Error, CustomStringConvertible {
        case noFrames(String)
        case noPeopleFound(String)

        public var description: String {
            switch self {
            case let .noFrames(name): return "no frames could be read from \(name)"
            case let .noPeopleFound(name): return "no people were detected in \(name)"
            }
        }
    }

    /// Detects everyone in `clip` and groups them into segments.
    ///
    /// `progress` is called with 0...1 as frames are processed. Cancellation is
    /// checked between frames via `Task.checkCancellation()`, so the caller's
    /// Cancel takes effect within one frame rather than at the end.
    public static func analyse(
        clip: URL,
        parameters: AnalysisParameters = .current,
        previewCount: Int = 5,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> ClipAnalysis {
        let frames = try ClipFrameReader.frames(
            from: clip, fps: parameters.fps, targetWidth: parameters.detectionWidth
        )
        guard !frames.isEmpty else {
            throw AnalysisError.noFrames(clip.lastPathComponent)
        }

        var detections: [FrameDetections] = []
        detections.reserveCapacity(frames.count)
        for (index, frame) in frames.enumerated() {
            try Task.checkCancellation()
            detections.append(contentsOf: PoseDetector.detections(in: [frame]))
            progress(Double(index + 1) / Double(frames.count))
        }

        let tracklets = TrackletLinker.link(
            detections,
            initialJumpFraction: parameters.initialJump,
            speedMultiplier: parameters.speedMultiplier,
            maxHeightRatio: parameters.maxHeightRatio,
            maxMisses: parameters.maxMisses,
            cutOnAmbiguity: parameters.cutOnAmbiguity
        )
        // A zero merge gap means nothing is ever joined across a gap: a
        // candidate is one contiguous segment. Merging is what re-fused
        // different people after the linker had correctly separated them.
        let candidates = SubjectCandidates.candidates(from: tracklets, mergeGapSeconds: 0)
            .filter { $0.detectionCount >= parameters.minSamples }

        guard !candidates.isEmpty else {
            throw AnalysisError.noPeopleFound(clip.lastPathComponent)
        }

        return ClipAnalysis(
            version: 1,
            analysedAt: Date(),
            parameters: parameters,
            segments: candidates.map { segment(from: $0, previewCount: previewCount) },
            subject: nil
        )
    }

    /// The run start for a chosen set of segments, re-reading the clip.
    ///
    /// Re-reads rather than caching the frames from `analyse`: a 45s clip at
    /// 320px is ~1100 CGImages, which is not something to hold across a UI
    /// interaction of unbounded length.
    public static func runStart(
        clip: URL,
        analysis: ClipAnalysis,
        segmentIDs: [Int]
    ) async throws -> SubjectRunStart.Outcome {
        let frames = try ClipFrameReader.frames(
            from: clip,
            fps: analysis.parameters.fps,
            targetWidth: analysis.parameters.detectionWidth
        )
        guard !frames.isEmpty else {
            throw AnalysisError.noFrames(clip.lastPathComponent)
        }
        try Task.checkCancellation()

        let detections = PoseDetector.detections(in: frames)
        let tracklets = TrackletLinker.link(
            detections,
            initialJumpFraction: analysis.parameters.initialJump,
            speedMultiplier: analysis.parameters.speedMultiplier,
            maxHeightRatio: analysis.parameters.maxHeightRatio,
            maxMisses: analysis.parameters.maxMisses,
            cutOnAmbiguity: analysis.parameters.cutOnAmbiguity
        )
        let candidates = SubjectCandidates.candidates(from: tracklets, mergeGapSeconds: 0)
            .filter { $0.detectionCount >= analysis.parameters.minSamples }

        let wanted = Set(segmentIDs)
        let picked = candidates.filter { wanted.contains($0.id) }
        let merged = picked.flatMap(\.detections).sorted { $0.time < $1.time }
        guard let first = merged.first, let last = merged.last else {
            return .noSamples
        }

        let subject = SubjectCandidate(
            id: picked.first?.id ?? 0,
            trackletIDs: picked.flatMap(\.trackletIDs).sorted(),
            detections: merged,
            firstSeen: first.time,
            lastSeen: last.time,
            detectionCount: merged.count,
            bestFrameTime: picked.first?.bestFrameTime ?? first.time,
            bestFrameBox: picked.first?.bestFrameBox ?? first.box,
            peakHeightFraction: picked.map(\.peakHeightFraction).max() ?? 0
        )
        return SubjectRunStart.runStart(
            in: SubjectRunStart.profile(frames: frames, candidate: subject)
        )
    }

    /// `previewCount` moments spread evenly across the segment's life — not its
    /// clearest instant alone. One thumbnail cannot show that a track has
    /// changed person partway through, and rejecting such a track is exactly
    /// what the operator is there to do.
    private static func segment(
        from candidate: SubjectCandidate, previewCount: Int
    ) -> AnalysedSegment {
        let wanted = min(previewCount, candidate.detections.count)
        let previews = (0..<wanted).map { step -> SegmentPreview in
            let position = wanted == 1
                ? 0
                : Int((Double(step) / Double(wanted - 1))
                      * Double(candidate.detections.count - 1))
            let detection = candidate.detections[position]
            return SegmentPreview(time: detection.time, box: detection.box)
        }
        return AnalysedSegment(
            id: candidate.id,
            firstSeen: candidate.firstSeen,
            lastSeen: candidate.lastSeen,
            detectionCount: candidate.detectionCount,
            peakHeightFraction: candidate.peakHeightFraction,
            previews: previews
        )
    }
}
```

- [ ] **Step 2: Write the end-to-end test**

`Tests/SkiVideoCoreTests/SubjectAnalyzerTests.swift`. This one needs real footage, so it skips cleanly when the clip is absent — a checkout on another machine must not fail.

```swift
import XCTest
@testable import SkiVideoCore

final class SubjectAnalyzerTests: XCTestCase {
    /// Ground truth supplied by the project owner: the athlete's run in this
    /// clip starts at 19.0s.
    private static let clip = URL(fileURLWithPath:
        "/Users/ulfnielsen/Ski/Neuss2026/organized/2026-07-19_Neuss/Idun Nielsen/C0094.MP4")

    private func requireClip() throws -> URL {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.clip.path),
            "ground-truth footage not present on this machine"
        )
        return Self.clip
    }

    func testFindsSegmentsCoveringTheAthletesRun() async throws {
        let analysis = try await SubjectAnalyzer.analyse(clip: try requireClip())

        XCTAssertFalse(analysis.segments.isEmpty)
        XCTAssertNil(analysis.subject)
        XCTAssertTrue(analysis.segments.allSatisfy { $0.detectionCount >= 8 })
        XCTAssertTrue(analysis.segments.allSatisfy { $0.previews.count <= 5 })
        // The athlete's run is 19.0-46.3s; some segment must reach the end.
        XCTAssertTrue(
            analysis.segments.contains { $0.lastSeen > 45.0 },
            "expected a segment running to the end of the clip"
        )
    }

    func testProgressRunsFromAboveZeroToOne() async throws {
        let clip = try requireClip()
        actor Recorder {
            var values: [Double] = []
            func record(_ value: Double) { values.append(value) }
        }
        let recorder = Recorder()
        _ = try await SubjectAnalyzer.analyse(clip: clip) { value in
            Task { await recorder.record(value) }
        }
        let values = await recorder.values

        XCTAssertGreaterThan(values.count, 100)
        XCTAssertEqual(values.last ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertTrue(values.allSatisfy { $0 > 0 && $0 <= 1.0 })
    }

    func testCancellationStopsTheAnalysis() async throws {
        let clip = try requireClip()
        let task = Task { try await SubjectAnalyzer.analyse(clip: clip) }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
    }

    func testRunStartOnThePickedSegmentsMatchesGroundTruth() async throws {
        let clip = try requireClip()
        let analysis = try await SubjectAnalyzer.analyse(clip: clip)
        // The athlete's segments, by the ranges established during
        // verification: 13.8-20.1, 20.1-24.5, 25.0-29.9, 29.9-46.3.
        let athlete = analysis.segments
            .filter { $0.firstSeen >= 13.0 && $0.lastSeen <= 46.5 && $0.detectionCount > 100 }
            .map(\.id)
        XCTAssertGreaterThanOrEqual(athlete.count, 3)

        let outcome = try await SubjectAnalyzer.runStart(
            clip: clip, analysis: analysis, segmentIDs: athlete
        )
        guard case let .started(start) = outcome else {
            return XCTFail("expected a measured start, got \(outcome)")
        }
        XCTAssertEqual(start.time, 19.0, accuracy: 1.0)
    }
}
```

- [ ] **Step 3: Run**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SubjectAnalyzerTests`
Expected: all pass; the run-start test lands at 18.6s, inside the ±1.0 tolerance.

These take roughly 20s each. If the suite becomes slow enough to be annoying, say so in your report rather than reducing coverage.

- [ ] **Step 4: Commit**

```bash
git add Sources/SkiVideoCore/SubjectAnalyzer.swift Tests/SkiVideoCoreTests/SubjectAnalyzerTests.swift
git commit -m "Analyse a clip into segments and a picked subject's run start"
```

---

### Task 4: Selection with overlap exclusion

**Files:**
- Create: `Sources/SkiVideoCore/SubjectPickModel.swift`
- Test: `Tests/SkiVideoCoreTests/SubjectPickModelTests.swift`

**Interfaces:**
- Consumes: `AnalysedSegment` from Task 2
- Produces: `SubjectPickModel` with `segments`, `selected`, `toggle(_:)`, `isSelectable(_:)`, `exclusionReason(for:)` — Phase B's sheet binds to these

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import SkiVideoCore

final class SubjectPickModelTests: XCTestCase {
    private func segment(
        _ id: Int, _ firstSeen: TimeInterval, _ lastSeen: TimeInterval, count: Int = 100
    ) -> AnalysedSegment {
        AnalysedSegment(
            id: id, firstSeen: firstSeen, lastSeen: lastSeen,
            detectionCount: count, peakHeightFraction: 0.3, previews: []
        )
    }

    func testEverythingIsSelectableBeforeAnythingIsPicked() {
        let model = SubjectPickModel(segments: [
            segment(1, 0.0, 5.3), segment(2, 3.1, 9.7), segment(3, 11.4, 18.2),
        ])

        XCTAssertTrue(model.segments.allSatisfy { model.isSelectable($0) })
    }

    func testSelectingASegmentExcludesOnlyThoseOverlappingIt() {
        let model = SubjectPickModel(segments: [
            segment(1, 0.0, 5.3), segment(2, 3.1, 9.7), segment(3, 11.4, 18.2),
        ])
        model.toggle(1)

        XCTAssertFalse(model.isSelectable(model.segments[1]), "#2 overlaps #1")
        XCTAssertTrue(model.isSelectable(model.segments[2]), "#3 does not")
        XCTAssertNotNil(model.exclusionReason(for: model.segments[1]))
        XCTAssertNil(model.exclusionReason(for: model.segments[2]))
    }

    func testDeselectingRestoresWhatItExcluded() {
        let model = SubjectPickModel(segments: [segment(1, 0.0, 5.3), segment(2, 3.1, 9.7)])
        model.toggle(1)
        model.toggle(1)

        XCTAssertTrue(model.selected.isEmpty)
        XCTAssertTrue(model.isSelectable(model.segments[1]))
    }

    func testASegmentOverlappingTwoDisjointOnesIsExcludedByEither() {
        // #2 straddles #1 and #3, which do not touch each other. Picking either
        // end must exclude the straddler, and picking both must keep it out.
        let model = SubjectPickModel(segments: [
            segment(1, 0.0, 4.1), segment(2, 3.7, 12.6), segment(3, 11.9, 17.4),
        ])
        model.toggle(3)
        XCTAssertFalse(model.isSelectable(model.segments[1]))
        model.toggle(1)
        XCTAssertFalse(model.isSelectable(model.segments[1]))
    }

    func testAnExcludedSegmentCannotBeSelected() {
        let model = SubjectPickModel(segments: [segment(1, 0.0, 5.3), segment(2, 3.1, 9.7)])
        model.toggle(1)
        model.toggle(2)

        XCTAssertEqual(model.selected, [1])
    }

    func testSelectedIDsComeBackInTimeOrder() {
        let model = SubjectPickModel(segments: [
            segment(1, 20.4, 29.8), segment(2, 0.0, 6.2), segment(3, 8.1, 14.9),
        ])
        model.toggle(1)
        model.toggle(3)
        model.toggle(2)

        XCTAssertEqual(model.selectedInTimeOrder, [2, 3, 1])
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SubjectPickModelTests`
Expected: compile failure — `SubjectPickModel` does not exist.

- [ ] **Step 3: Write the model**

```swift
import Combine
import Foundation

/// The operator's segment selection, and the rule that keeps it coherent.
///
/// Segments overlapping in time are mutually exclusive. This is not a nicety:
/// C0082 produced 779 detections over 776 samples because two picked segments
/// overlapped, which is only possible if one of them is a different person. The
/// union then silently blends two athletes into one trajectory that looks
/// entirely plausible. Making the overlapping option unavailable turns that
/// into something the UI will not offer.
public final class SubjectPickModel: ObservableObject {
    public let segments: [AnalysedSegment]
    @Published public private(set) var selected: [Int] = []

    public init(segments: [AnalysedSegment]) {
        self.segments = segments
    }

    public var selectedInTimeOrder: [Int] {
        segments.filter { selected.contains($0.id) }.map(\.id)
    }

    public func isSelected(_ segment: AnalysedSegment) -> Bool {
        selected.contains(segment.id)
    }

    public func isSelectable(_ segment: AnalysedSegment) -> Bool {
        isSelected(segment) || exclusionReason(for: segment) == nil
    }

    /// Why this segment cannot be picked, phrased for the operator, or nil.
    public func exclusionReason(for segment: AnalysedSegment) -> String? {
        guard !isSelected(segment) else { return nil }
        guard let clash = segments.first(where: {
            selected.contains($0.id) && $0.overlaps(segment)
        }) else { return nil }
        return "Overlaps segment \(clash.id) in time, so they cannot be the same person"
    }

    public func toggle(_ id: Int) {
        guard let segment = segments.first(where: { $0.id == id }) else { return }
        if let index = selected.firstIndex(of: id) {
            selected.remove(at: index)
        } else if isSelectable(segment) {
            selected.append(id)
        }
    }
}
```

`segments` is ordered as the analyzer produced it — descending detection count — so `selectedInTimeOrder` must sort by time itself rather than relying on that order. Implement it by filtering a time-sorted copy, not by filtering `segments` directly; the test above will catch it if you don't.

- [ ] **Step 4: Run the tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SubjectPickModelTests`
Expected: all pass.

- [ ] **Step 5: Mutation-check**

Reverting each; report every outcome including survivals.

1. Make `overlaps` use `<` and `>` instead of `<=` and `>=`. Expected: at least one test fails — if none do, the tests use only strictly-overlapping ranges and must gain a touching-endpoint case.
2. Make `toggle` append unconditionally, ignoring `isSelectable`. Expected: `testAnExcludedSegmentCannotBeSelected` fails.
3. Make `selectedInTimeOrder` return `selected` unchanged. Expected: `testSelectedIDsComeBackInTimeOrder` fails.

- [ ] **Step 6: Commit**

```bash
git add Sources/SkiVideoCore/SubjectPickModel.swift Tests/SkiVideoCoreTests/SubjectPickModelTests.swift
git commit -m "Hold the segment selection, refusing overlapping picks"
```

---

### Task 5: Applying a detected sync point

**Files:**
- Modify: `Sources/SkiVideoCore/ComparisonModel.swift`
- Test: `Tests/SkiVideoCoreTests/ComparisonModelTests.swift` (existing file, add to it)

**Interfaces:**
- Consumes: nothing from earlier tasks — this is deliberately independent of `ClipAnalysis` so the model does not learn about sidecars
- Produces: `ComparisonModel.applySync(left:right:)` and the published `syncOrigin`

**Read `ComparisonModel.swift` before editing.** It maintains an invariant — `L_cur - L_sync == R_cur - R_sync` while synced — and `nudge`, `scrub`, `seekSynced` and `returnToSyncPoints` all depend on it. Reuse the existing sync mechanism rather than assigning `leftSyncPoint`/`rightSyncPoint` yourself.

**This file is also touched by `viewer-redesign`,** which moved the timecode formatter out. Keep your change additive and away from that region so the branches merge cleanly.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/SkiVideoCoreTests/ComparisonModelTests.swift`, following the fixture and setup that file already uses for two loaded videos:

```swift
    func testApplySyncSetsBothSidesAndRecordsItsOrigin() async throws {
        let model = try await loadedPair()   // existing helper in this file

        model.applySync(left: 18.64, right: 4.42)

        XCTAssertTrue(model.isSynced)
        XCTAssertEqual(model.leftSyncPoint.seconds, 18.64, accuracy: 0.05)
        XCTAssertEqual(model.rightSyncPoint.seconds, 4.42, accuracy: 0.05)
        guard case let .detected(left, right) = model.syncOrigin else {
            return XCTFail("expected detected, got \(model.syncOrigin)")
        }
        XCTAssertEqual(left, 18.64, accuracy: 1e-9)
        XCTAssertEqual(right, 4.42, accuracy: 1e-9)
    }

    func testAManualSyncAfterADetectedOneTakesTheOrigin() async throws {
        let model = try await loadedPair()
        model.applySync(left: 18.64, right: 4.42)

        model.setSyncPoints()

        XCTAssertEqual(model.syncOrigin, .manual)
    }

    func testClearingSyncResetsTheOrigin() async throws {
        let model = try await loadedPair()
        model.applySync(left: 18.64, right: 4.42)

        model.removeSync()

        XCTAssertFalse(model.isSynced)
        XCTAssertEqual(model.syncOrigin, .manual)
    }

    func testApplySyncClampsATimeBeyondTheClipRatherThanRefusing() async throws {
        // `alreadyRunning` yields a time at or before the first frame, and a
        // detected start can in principle exceed a clip's duration. Neither
        // should leave the pair half-synced.
        let model = try await loadedPair()

        model.applySync(left: -3.0, right: 9_999.0)

        XCTAssertTrue(model.isSynced)
        XCTAssertGreaterThanOrEqual(model.leftSyncPoint.seconds, 0)
    }
```

If the existing test file has no `loadedPair()` helper, use whatever it already does to get two loaded videos and say in your report what you used.

- [ ] **Step 2: Run to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ComparisonModelTests`
Expected: compile failure — `applySync` and `syncOrigin` do not exist.

- [ ] **Step 3: Add the origin**

```swift
/// Where the current sync points came from.
///
/// Published so the status chip can attribute them. A detected sync is applied
/// immediately, before the operator has seen it, and on measured evidence it is
/// sometimes wrong by a second or more — attribution is what makes that
/// recoverable rather than mystifying.
public enum SyncOrigin: Equatable, Sendable {
    case manual
    case detected(left: TimeInterval, right: TimeInterval)
}
```

and on the model: `@Published public private(set) var syncOrigin: SyncOrigin = .manual`.

Set it to `.manual` in `setSyncPoints()` and in `clearSync(message:)`, and to `.detected` in `applySync`. Assigning it in `clearSync` covers `removeSync` and every other path that drops sync, so no case is missed.

- [ ] **Step 4: Add `applySync`**

```swift
    /// Seeks both clips to the given times and syncs there.
    ///
    /// Times are clamped into each clip's duration: a detected start can be
    /// negative (a run already in progress at the first frame) or, in
    /// principle, beyond the end, and either would otherwise leave the pair
    /// half-synced.
    public func applySync(left: TimeInterval, right: TimeInterval)
```

Implement it by seeking each side to the clamped time and then calling the same routine `setSyncPoints()` uses, so the `L_cur - L_sync == R_cur - R_sync` invariant is established the one existing way. Then overwrite `syncOrigin` with `.detected(left:right:)` — after the call, since `setSyncPoints` sets it to `.manual`.

- [ ] **Step 5: Run the tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ComparisonModelTests`
Expected: all pass, including the file's pre-existing tests.

- [ ] **Step 6: Mutation-check**

1. Remove the `syncOrigin = .manual` assignment from `setSyncPoints`. Expected: `testAManualSyncAfterADetectedOneTakesTheOrigin` fails.
2. Remove the clamping in `applySync`. Expected: `testApplySyncClampsATimeBeyondTheClipRatherThanRefusing` fails.

Report both outcomes.

- [ ] **Step 7: Run the whole suite and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
git add Sources/SkiVideoCore/ComparisonModel.swift Tests/SkiVideoCoreTests/ComparisonModelTests.swift
git commit -m "Apply a detected sync point, and record where a sync came from"
```

Expected: the full suite passes. Report the total count.

---

## Self-Review Notes

- **Spec coverage.** Sidecar → Task 2. Staleness → Task 2. Ported components → Task 1. `SubjectAnalyzer` → Task 3. `SubjectPickModel` and overlap exclusion → Task 4. `ComparisonModel` additions → Task 5. The picking sheet and the two entry points are Phase B by design and are not in this plan.
- **Deliberately not ported.** `RunStartDetector`'s whole-frame detector (measured not to work; kept only as an internal contrast for one test), `RegistrationResidual`, `OverlayExport`, `RegistrationLab`, and the trajectory-coverage computation. Coverage would be genuinely useful for warning about a gappy subject, but the spec does not call for it and inventing scope here would be wrong; it is a good Phase B follow-up.
- **Known open defects, unchanged by this plan.** A truncated upper-body detection breaks the track (C0094 at 24.76 s), and the missing-segment warning false-alarms when the camera pans off the athlete (C0089 at 5.04 s). Both are in the detection layer and are noted in the spec as out of scope.
- **Type consistency.** `AnalysedSegment.id` is the `SubjectCandidate.id` the analyzer produced, and `SubjectPick.segmentIDs` holds those same values. `SubjectAnalyzer.runStart` re-derives candidates from the same parameters, so the ids match — which is exactly why `AnalysisParameters` is stored and why staleness is reported.
