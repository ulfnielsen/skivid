# Phase C — Landmark Alignment — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Register the two clips' backgrounds against each other so Overlay mode's difference blending is readable, applying the warp only where it earns its place.

**Architecture:** A one-off pass registers sampled frame pairs from the detected run starts and stores a translation track beside the clips. Playback reads that track through a pure gate that decides, per frame, whether to apply the translation, ease toward identity, or do nothing. The gate is where all the judgement lives and is unit-tested; the pass and the rendering are covered by looking at the output.

**Tech Stack:** Swift 6.1 (language mode 5), Vision, AVFoundation, CoreGraphics, SwiftUI. macOS 13 / iOS 17.

**Spec:** `docs/superpowers/specs/2026-08-02-phase-c-alignment-design.md`
**Measurement it rests on:** `docs/superpowers/specs/2026-08-02-phase-c-alignment-findings.md`

## Global Constraints

- Branch `alignment-track`, cut from `main`.
- `SkiVideoCore` targets **macOS 13 and iOS 17**. `VNTrack*ImageRegistrationRequest` and other macOS 14+ Vision API are forbidden. `VNTranslationalImageRegistrationRequest` is what this uses.
- Everything crossing a target boundary is `public`, including memberwise initialisers.
- Translations are in **normalised frame widths**, never pixels, so a track survives a change of working resolution. Convert at the edges.
- **Only translational registration.** Homographic measured worse than identity at two of three scales on this footage; do not add it "for completeness".
- **NEVER** use `CIContext.render(toBitmap:rowBytes:bounds:format:colorSpace:)` with `.R8` and DeviceGray — it silently returns all zeros here and has cost this project three debugging cycles.
- Test constants asymmetric. Overlap series must cross the thresholds in both directions and must include a stretch that oscillates *between* them.
- Every load-bearing test is **mutation-verified**: break the rule it targets, confirm it fails, revert, report both outcomes. Seven tests in this project's recent history passed regardless of the logic they claimed to cover. A surviving mutation means the test is worthless — strengthen it and say so.
- **Offscreen rendering is not evidence that a SwiftUI control is visible.** Measured repeatedly here: a view-tree search finds no `NSControl` for a button that plainly renders, `ImageRenderer` cannot draw a `Menu`, `cacheDisplay` renders one as empty, and `fittingSize` reports a healthy size for a control that paints nothing. For "is it on screen", only the running app counts.
- Build/test: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build|test` from `SkiVideoViewer/`.
- Commit after each task.

## What already exists

`FrameRegistration.register(reference:floating:method:)` in `SkiVideoCore`, returning a
`matrix_float3x3` whose translation column is **already the transform to apply to the
floating image to bring it onto the reference** — do not invert it. `ClipFrameReader` reads
frames sequentially. `RegistrationResidual` is **not** in the app; the measurement of
residual and overlap has to be written here or ported from the `landmark-align` worktree at
`/Users/ulfnielsen/Ski/ski-landmark-align/SkiVideoViewer/Sources/SkiVideoCore/RegistrationResidual.swift`.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/SkiVideoCore/RegistrationResidual.swift` (port) | Mean absolute difference and overlap fraction under a warp |
| `Sources/SkiVideoCore/AlignmentTrack.swift` (create) | `AlignmentSample`, `AlignmentTrack`, `AlignmentParameters`, staleness |
| `Sources/SkiVideoCore/AlignmentTrackStore.swift` (create) | The pair-keyed sidecar |
| `Sources/SkiVideoCore/AlignmentGate.swift` (create) | Gating, easing, interpolation — all the judgement |
| `Sources/SkiVideoCore/AlignmentAnalyzer.swift` (create) | The registration pass |
| `Sources/SkiVideoViewer/Shared/OverlayPlayerStack.swift` (modify) | Accept and apply a translation |
| `Sources/SkiVideoViewer/Shared/OverlayBlendBar.swift` (modify) | The Align toggle and Compute action |
| `Sources/SkiVideoViewer/Shared/ComparisonView.swift` (modify) | Own the track, drive the pass |
| `Tests/SkiVideoCoreTests/AlignmentGateTests.swift` (create) | The load-bearing tests |
| `Tests/SkiVideoCoreTests/AlignmentTrackTests.swift` (create) | Round-trip, staleness |
| `Tests/SkiVideoCoreTests/AlignmentAnalyzerTests.swift` (create) | End to end on the ground-truth pair |

---

### Task 1: The track, its store, and the residual it needs

**Files:**
- Port: `Sources/SkiVideoCore/RegistrationResidual.swift` (+ its tests from the same worktree)
- Create: `Sources/SkiVideoCore/AlignmentTrack.swift`, `Sources/SkiVideoCore/AlignmentTrackStore.swift`
- Test: `Tests/SkiVideoCoreTests/AlignmentTrackTests.swift`

**Interfaces:**
- Produces: `AlignmentSample`, `AlignmentTrack`, `AlignmentParameters`, `AlignmentTrackStore.{sidecarURL,load,save}`, `Residual`, `RegistrationResidual.measure(reference:floating:warp:)`

- [ ] **Step 1: Port the residual**

```bash
W=/Users/ulfnielsen/Ski/ski-landmark-align/SkiVideoViewer
cp $W/Sources/SkiVideoCore/RegistrationResidual.swift Sources/SkiVideoCore/
cp $W/Tests/SkiVideoViewerTests/RegistrationResidualTests.swift Tests/SkiVideoCoreTests/
```

Repoint the test to `@testable import SkiVideoCore`. `TestImageFactory` is already in
`SkiVideoCoreTests`. Note that Task 1 of the previous plan worked around this file's absence
with a private `TestResidual` helper inside `FrameRegistrationTests`; now that the real one
is here, **delete that helper and point the test at `RegistrationResidual`** — two copies of
the same measurement is how they drift.

- [ ] **Step 2: Write the failing tests**

`Tests/SkiVideoCoreTests/AlignmentTrackTests.swift`:

```swift
import CoreGraphics
import XCTest
@testable import SkiVideoCore

final class AlignmentTrackTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func track(leftStart: TimeInterval = 18.56) -> AlignmentTrack {
        AlignmentTrack(
            version: 1,
            computedAt: Date(timeIntervalSince1970: 1_754_140_000),
            leftClip: "C0094.MP4", rightClip: "C0092.MP4",
            leftStart: leftStart, rightStart: 4.40,
            parameters: .current,
            samples: [
                AlignmentSample(
                    time: 0.0, translation: CGVector(dx: 0.031, dy: -0.017),
                    overlap: 0.913, residual: 5.04, identityResidual: 9.63
                ),
                AlignmentSample(
                    time: 0.5, translation: CGVector(dx: 0.036, dy: -0.021),
                    overlap: 0.854, residual: 5.17, identityResidual: 11.66
                ),
            ]
        )
    }

    func testRoundTrips() throws {
        let decoded = try JSONDecoder().decode(
            AlignmentTrack.self, from: JSONEncoder().encode(track())
        )
        XCTAssertEqual(decoded.samples.count, 2)
        XCTAssertEqual(decoded.samples[1].translation.dx, 0.036, accuracy: 1e-9)
        XCTAssertEqual(decoded.samples[0].overlap, 0.913, accuracy: 1e-9)
        XCTAssertEqual(decoded.rightStart, 4.40, accuracy: 1e-9)
    }

    func testTheSidecarNamesBothClipsAndSitsBesideTheLeftOne() {
        let left = directory.appendingPathComponent("C0094.MP4")
        let right = directory.appendingPathComponent("sub/C0092.MP4")
        let url = AlignmentTrackStore.sidecarURL(left: left, right: right)

        XCTAssertEqual(url.lastPathComponent, "C0094--C0092.skialignment.json")
        XCTAssertEqual(url.deletingLastPathComponent().path, directory.path)
    }

    func testSaveThenLoadRoundTrips() throws {
        let left = directory.appendingPathComponent("C0094.MP4")
        let right = directory.appendingPathComponent("C0092.MP4")
        try AlignmentTrackStore.save(track(), left: left, right: right)

        XCTAssertEqual(
            AlignmentTrackStore.load(left: left, right: right)?.samples.count, 2
        )
    }

    func testATrackComputedForDifferentRunStartsIsStale() {
        // A track describes one comparison. Re-picking the subject moves the
        // run start, and every translation in the file then refers to a pairing
        // of frames that no longer happens.
        XCTAssertTrue(
            track(leftStart: 12.0).isStale(leftStart: 18.56, rightStart: 4.40)
        )
        XCTAssertFalse(
            track().isStale(leftStart: 18.56, rightStart: 4.40)
        )
    }

    func testStalenessSurvivesFloatingPointNoiseInTheStarts() {
        // The starts come back through JSON and through a detector that reports
        // to two decimals; an exact-equality check would call every reloaded
        // track stale and recompute a 15-second pass on every open.
        XCTAssertFalse(
            track().isStale(leftStart: 18.560000001, rightStart: 4.4)
        )
    }
}
```

- [ ] **Step 3: Run to verify they fail**

Expected: compile failure — none of these types exist.

- [ ] **Step 4: Write the types**

`AlignmentParameters` carries `sampleRate` (25), `workingWidth` (320), and `durationSeconds`
(how far past the run start the pass went), plus a `matches` like `AnalysisParameters`.

`AlignmentTrack.isStale(leftStart:rightStart:)` compares within a tolerance of **0.01 s** —
see the test above for why exact equality is wrong.

`AlignmentTrackStore.sidecarURL(left:right:)` builds `<leftStem>--<rightStem>.skialignment.json`
beside the **left** clip. `load` returns nil for a missing or unparseable file and never
overwrites one it could not parse, exactly as `ClipAnalysisStore` does.

- [ ] **Step 5: Run, then mutation-check**

1. Make `isStale` use exact equality. Expected: `testStalenessSurvivesFloatingPointNoiseInTheStarts` fails.
2. Make `sidecarURL` use only the left stem. Expected: `testTheSidecarNamesBothClipsAndSitsBesideTheLeftOne` fails.

- [ ] **Step 6: Commit**

```bash
git add Sources/SkiVideoCore/RegistrationResidual.swift Sources/SkiVideoCore/AlignmentTrack.swift Sources/SkiVideoCore/AlignmentTrackStore.swift Tests/SkiVideoCoreTests/
git commit -m "Store a pair's alignment as a track beside the clips"
```

---

### Task 2: The gate

**Files:**
- Create: `Sources/SkiVideoCore/AlignmentGate.swift`
- Test: `Tests/SkiVideoCoreTests/AlignmentGateTests.swift`

**Interfaces:**
- Consumes: `AlignmentTrack`, `AlignmentSample`
- Produces: `AlignmentGate.translation(in:at:engageAbove:disengageBelow:easeSeconds:)`

**This is the task that matters.** Every judgement in Phase C lives here, and all of it is
pure. The pass and the rendering are plumbing by comparison.

- [ ] **Step 1: Write the failing tests**

```swift
import CoreGraphics
import XCTest
@testable import SkiVideoCore

final class AlignmentGateTests: XCTestCase {
    /// A track whose overlap follows `overlaps` at 0.5s spacing, with a
    /// translation that grows so interpolation is observable.
    private func track(_ overlaps: [Double]) -> AlignmentTrack {
        AlignmentTrack(
            version: 1, computedAt: Date(timeIntervalSince1970: 1_754_140_000),
            leftClip: "L.MP4", rightClip: "R.MP4",
            leftStart: 18.56, rightStart: 4.40, parameters: .current,
            samples: overlaps.enumerated().map { index, overlap in
                AlignmentSample(
                    time: Double(index) * 0.5,
                    translation: CGVector(
                        dx: 0.02 + Double(index) * 0.004,
                        dy: -0.01 - Double(index) * 0.003
                    ),
                    overlap: overlap, residual: 5.0, identityResidual: 9.0
                )
            }
        )
    }

    func testAHealthyStretchIsAligned() {
        let gate = AlignmentGate.translation(
            in: track([0.91, 0.88, 0.84, 0.86, 0.90]), at: 1.0
        )
        XCTAssertNotNil(gate)
        XCTAssertEqual(gate?.dx ?? 0, 0.028, accuracy: 1e-9)
    }

    func testALowOverlapStretchIsIdentity() {
        XCTAssertNil(
            AlignmentGate.translation(in: track([0.41, 0.26, 0.23, 0.29, 0.35]), at: 1.0)
        )
    }

    /// The whole reason there are two thresholds. A signal wandering inside the
    /// band must hold whatever state it was in, not toggle on every sample.
    func testASignalOscillatingBetweenTheThresholdsDoesNotFlap() {
        // Engages on the first sample, then wanders in 0.55...0.68 forever.
        let wandering = track([0.91, 0.66, 0.57, 0.64, 0.58, 0.67, 0.56, 0.63])
        for step in 1..<8 {
            XCTAssertNotNil(
                AlignmentGate.translation(in: wandering, at: Double(step) * 0.5),
                "disengaged inside the band at sample \(step)"
            )
        }

        // The mirror: starts disengaged, wanders in the band, stays off.
        let fromBelow = track([0.22, 0.57, 0.66, 0.58, 0.64, 0.61])
        for step in 1..<6 {
            XCTAssertNil(
                AlignmentGate.translation(in: fromBelow, at: Double(step) * 0.5),
                "engaged inside the band at sample \(step)"
            )
        }
    }

    /// The anti-latch test. The lab exporter stops for the rest of the clip
    /// after three consecutive failures; measured recovery at t=8 held for five
    /// seconds, so that behaviour would discard a genuinely alignable window.
    func testALongDisengagedStretchReEngagesOnRecovery() {
        let recovering = track([0.91, 0.24, 0.31, 0.28, 0.22, 0.26, 0.34, 0.79, 0.83, 0.81])
        XCTAssertNil(AlignmentGate.translation(in: recovering, at: 1.5))
        XCTAssertNotNil(
            AlignmentGate.translation(in: recovering, at: 4.5),
            "never re-engaged after a long disengaged stretch"
        )
    }

    func testTheEaseReachesIdentityAndDoesNotOvershoot() {
        // Engaged, then falls off a cliff at t=1.0.
        let falling = track([0.91, 0.88, 0.24, 0.22, 0.20])
        let atCliff = AlignmentGate.translation(in: falling, at: 1.0)
        let midEase = AlignmentGate.translation(in: falling, at: 1.125)
        let afterEase = AlignmentGate.translation(in: falling, at: 1.30)

        // Shrinking toward zero, never past it, and gone by easeSeconds.
        XCTAssertNotNil(midEase)
        XCTAssertLessThan(abs(midEase?.dx ?? 1), abs(atCliff?.dx ?? 0))
        XCTAssertGreaterThanOrEqual(midEase?.dx ?? -1, 0)
        XCTAssertNil(afterEase)
    }

    func testInterpolationHappensInsideAnEngagedRun() {
        let engaged = track([0.91, 0.88, 0.84])
        let between = AlignmentGate.translation(in: engaged, at: 0.25)

        // Halfway between sample 0 (0.020) and sample 1 (0.024).
        XCTAssertEqual(between?.dx ?? 0, 0.022, accuracy: 1e-9)
    }

    func testAnEmptyTrackIsIdentityEverywhere() {
        XCTAssertNil(AlignmentGate.translation(in: track([]), at: 0))
        XCTAssertNil(AlignmentGate.translation(in: track([]), at: 5))
    }

    func testATimeBeyondTheLastSampleIsIdentity() {
        // The pass covers a fixed duration; past its end nothing was measured,
        // and holding the last translation indefinitely is the stale-warp
        // failure this design exists to avoid.
        XCTAssertNil(AlignmentGate.translation(in: track([0.91, 0.88]), at: 30))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Expected: compile failure — `AlignmentGate` does not exist.

- [ ] **Step 3: Implement**

```swift
public enum AlignmentGate {
    public static func translation(
        in track: AlignmentTrack,
        at time: TimeInterval,
        engageAbove: Double = 0.68,
        disengageBelow: Double = 0.55,
        easeSeconds: Double = 0.25
    ) -> CGVector?
}
```

Walk the samples from the start, carrying an engaged/disengaged state: engaged becomes
disengaged only when overlap drops **below** `disengageBelow`; disengaged becomes engaged
only when it rises **above** `engageAbove`. Anything in between leaves the state alone —
that is the hysteresis, and the oscillation test is what proves it.

Within an engaged run, interpolate `translation` linearly between the bracketing samples.
Do not interpolate across a boundary.

For `easeSeconds` after a disengage, return the last engaged translation scaled linearly to
zero; after that, nil. Return nil past the last sample.

Document why each rule exists, citing the measurement: two thresholds because the good
windows sit at ≥0.68 and the bad at ≤0.49; no latch because recovery at t=8 held five
seconds; identity rather than a held warp because at t=5 the held warp puts one clip in the
corner.

- [ ] **Step 4: Run the tests**

Expected: all pass.

- [ ] **Step 5: Mutation-check — all five, reverting each**

1. Collapse to one threshold (`engageAbove` used for both). Expected: `testASignalOscillatingBetweenTheThresholdsDoesNotFlap` fails.
2. Latch: once disengaged, stay disengaged. Expected: `testALongDisengagedStretchReEngagesOnRecovery` fails.
3. Cut instead of easing (return nil the instant overlap drops). Expected: `testTheEaseReachesIdentityAndDoesNotOvershoot` fails.
4. Return the nearest sample instead of interpolating. Expected: `testInterpolationHappensInsideAnEngagedRun` fails.
5. Hold the last translation past the end of the track. Expected: `testATimeBeyondTheLastSampleIsIdentity` fails.

Report all five. Any that survives means that test does not discriminate — strengthen it and say so.

- [ ] **Step 6: Commit**

```bash
git add Sources/SkiVideoCore/AlignmentGate.swift Tests/SkiVideoCoreTests/AlignmentGateTests.swift
git commit -m "Gate alignment on overlap, with hysteresis and no latching"
```

---

### Task 3: The pass

**Files:**
- Create: `Sources/SkiVideoCore/AlignmentAnalyzer.swift`
- Test: `Tests/SkiVideoCoreTests/AlignmentAnalyzerTests.swift`

**Interfaces:**
- Consumes: `ClipFrameReader`, `FrameRegistration`, `RegistrationResidual`, `AlignmentTrack`
- Produces: `AlignmentAnalyzer.analyse(left:right:leftStart:rightStart:parameters:progress:)`

- [ ] **Step 1: Implement**

Read both clips from their run starts at `parameters.sampleRate` and `parameters.workingWidth`,
for `parameters.durationSeconds`. For each pair at the same offset:

- register right onto left, translational
- measure `Residual` under that warp and under identity
- emit an `AlignmentSample` with the translation **normalised by frame width**

`FrameRegistration`'s warp is already the transform to apply to the floating image; do not
invert it. Progress is reported per pair, and `Task.checkCancellation()` is checked between
pairs.

A pair whose registration throws contributes a sample with zero translation and zero
overlap, so the gate reads it as disengaged rather than the sample vanishing and the
timeline silently shortening.

- [ ] **Step 2: Write the end-to-end test**

`XCTSkipUnless` the ground-truth footage is present, as `SubjectAnalyzerTests` does.

Assert against the measured findings — these are the numbers this design was derived from,
so a disagreement is a real finding and **must not be tuned away**:

- the engaged fraction over t = 0…17 is between 0.5 and 0.8
- **t = 2.0 is engaged**, and **t = 6.0 is not**
- at t = 2.0 the sample's `residual` is below its `identityResidual`

Also assert the pass is cancellable and that a track round-trips through the store.

- [ ] **Step 3: Run and report**

Report the engaged windows the pass actually finds, against the measured t = 0–4 and
t = 8–13, and the wall-clock cost. If the windows differ, report it — that is the second
measurement the spec asks for, arriving early.

- [ ] **Step 4: Commit**

```bash
git add Sources/SkiVideoCore/AlignmentAnalyzer.swift Tests/SkiVideoCoreTests/AlignmentAnalyzerTests.swift
git commit -m "Register the pair from their run starts into an alignment track"
```

---

### Task 4: Applying it in Overlay mode

**Files:**
- Modify: `Sources/SkiVideoViewer/Shared/OverlayPlayerStack.swift`, `OverlayBlendBar.swift`, `ComparisonView.swift`
- Test: `Tests/SkiVideoViewerTests/OverlayAlignmentWiringTests.swift` (create)

**Read first:** `OverlayPlayerStack.swift`'s header — it explains why the overlay is SwiftUI
rather than two `AVPlayerLayer`s (`CALayer.compositingFilter` is a silent no-op on iOS) and
why `.blendMode(.difference)` is used. Do not undo that. `OverlayBlendBar.swift` documents
why no `contentShape` may be added to its controls.

- [ ] **Step 1: Apply the translation**

`OverlayPlayerStack` gains `let translation: CGVector` (normalised, `.zero` for none) and
offsets the **top** player by it, scaled by the rendered width. It stays a pure renderer
taking players and values — it must not learn about tracks, models or stores.

- [ ] **Step 2: Own the track in `ComparisonView`**

An `AlignmentSessionModel` (in `SkiVideoCore`, alongside `SubjectSessionModel` and following
its shape: idle / computing(progress) / ready(track) / failed, with the same
update-memory-before-writing rule) loads the sidecar when both sides have a subject, and
runs the pass on demand.

`ComparisonView` feeds `AlignmentGate.translation(in:at:)` the current playback offset from
the sync point and passes the result down.

- [ ] **Step 3: The controls**

`OverlayBlendBar` gains an **Align** toggle, disabled with a `.help` explaining why when no
track exists, and a **Compute alignment** action that runs the pass with determinate
progress and a working Cancel. Follow the bar's existing discipline: fixed widths, no
`contentShape`, `.help` and `.accessibilityLabel` on every control.

The status chip says when alignment is disengaged, so an unaligned stretch reads as a
decision rather than a failure.

- [ ] **Step 4: Wiring tests**

Mirror `SharedControlsWiringTests`. Cover: the toggle reaches the model; **Compute
alignment** starts the pass; the toggle is disabled with no track; a track whose run starts
are stale disables the toggle and says so.

- [ ] **Step 5: Check the bar still fits**

`OverlayBlendBar` is inside the same band as the control bar. Run
`ComparisonLayoutMeasurementTests` and confirm nothing moved; if the overlay band now wraps
at 834pt, **report it rather than shrinking a control**.

- [ ] **Step 6: Mutation-check**

1. Apply the translation to the bottom player instead of the top. Expected: a wiring or render test fails. If none does, add one — "which clip moves" is the whole behaviour.
2. Ignore the gate and always apply the raw sample. Expected: a test asserting identity during a low-overlap stretch fails.

- [ ] **Step 7: Commit**

---

### Task 5: Prove it, and measure a second pair

**Files:** none — evidence is the deliverable

- [ ] **Step 1: Compute and report**

Compute the track for C0094 + C0092 at the detected starts. Report the engaged fraction, the
engaged windows, and the wall-clock cost. Confirm reopening the pair reuses the track.

- [ ] **Step 2: Show it**

In the running app, Overlay + Difference, aligned and unaligned. **Send both, listing every
image with its clip and timestamp.** Aligned should show terrain cancelling to near-black
with the skiers standing out; unaligned should not. Also capture frames either side of a
disengage, showing the ease rather than a jump.

Offscreen renders do not count for this. Only the running app.

- [ ] **Step 3: The second pair**

Run the alignment sweep on a second synced pair — pick any two clips from
`~/Ski/Neuss2026/organized/2026-07-19_Neuss` whose subjects can be picked, detect their run
starts, and sweep t = 0…17.

Report where the engaged windows fall. **If they sit elsewhere than 0–4 and 8–13, that is
the finding**, and the thresholds are what to revisit — the design only assumes good and bad
windows exist and are separable by overlap. Do not adjust the thresholds to make this pair
match the first.

---

## Self-Review Notes

- **Spec coverage.** Track and storage → Task 1. Gating, hysteresis, easing, no-latch →
  Task 2. The precomputed pass → Task 3. Overlay application and controls → Task 4.
  Verification and the second pair → Task 5.
- **Deliberately not here.** Homographic registration; alignment in side-by-side; time
  warping. The exporter consuming the same track is in the spec but needs `OverlayClipWriter`
  ported first, which is its own task.
- **The riskiest assumption**, stated so it is not forgotten: the thresholds come from one
  clip pair with one frame per sample. Task 5 Step 3 is what tests it, and it is placed last
  deliberately — the design does not depend on the numbers, only on good and bad windows
  being separable.
