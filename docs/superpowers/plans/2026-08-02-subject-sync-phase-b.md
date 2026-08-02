# Subject Sync, Phase B (UI) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the operator find the subject in a clip, pick which segments are their athlete, and have the comparison sync itself from the detected run start — with the result stored so it never has to be done twice.

**Architecture:** Phase A's `SkiVideoCore` already does the work: `SubjectAnalyzer` produces a `ClipAnalysis`, `SubjectPickModel` holds the selection and refuses overlapping picks, `SegmentThumbnails` redraws the previews, `ClipAnalysisStore` persists the sidecar, and `ComparisonModel.applySync` applies the result. Phase B adds one sheet, one button, and the wiring between them.

**Tech Stack:** SwiftUI (shared across macOS 13 and iPadOS 17), Combine, `SkiVideoCore`.

**Spec:** `docs/superpowers/specs/2026-08-02-subject-sync-design.md`

## Global Constraints

- Branch `subject-sync-ui`, cut from `subject-sync-core` (which is merged up to date with `main` at `b648c3c`). Phase A is on that branch; do not re-implement any of it.
- **The 44pt touch-target rule applies to controls we build, not to system controls.** Buttons we make are genuinely 44×44 by `frame` plus `contentShape`. Segmented pickers are 32pt and correct at that size. This is documented at the top of `ComparisonControlBar.swift` — read it.
- Do **not** add a `.contentShape` or background tap gesture to the control band: measured, it swallows clicks in the surrounding band. The same file documents this.
- Every new control carries `.help(...)` and `.accessibilityLabel(...)` with the same string, matching the existing controls.
- Status chip accessibility labels use the `Status: ` prefix; the chip is `allowsHitTesting(false)` and a constant 340pt. Do not size it to its text.
- Shared views live in `Sources/SkiVideoViewer/Shared/` and must compile for both platforms — no AppKit or UIKit imports.
- Build/test: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` / `swift test` from `SkiVideoViewer/`.
- Every load-bearing test is verified by **mutation**: break the rule it targets, confirm it fails, revert, report both outcomes. Five tests in this project's recent history passed regardless of the logic they claimed to cover, each found only this way. A surviving mutation means the test is worthless — strengthen it and say so.
- Commit after each task.

## What already exists (Phase A — do not rewrite)

```swift
public enum SubjectAnalyzer {
    public static func analyse(clip: URL, parameters: AnalysisParameters = .current,
                               previewCount: Int = 5,
                               progress: @Sendable (Double) -> Void = { _ in }) async throws -> ClipAnalysis
    public static func runStart(clip: URL, analysis: ClipAnalysis,
                                segmentIDs: [Int]) async throws -> SubjectRunStart.Outcome
    public enum AnalysisError: Error { case noFrames(String), noPeopleFound(String) }
}
public enum ClipAnalysisStore {
    public static func sidecarURL(for clip: URL) -> URL
    public static func load(for clip: URL) -> ClipAnalysis?
    public static func save(_ analysis: ClipAnalysis, for clip: URL) throws
}
public enum SegmentThumbnails {
    public static func strip(clip: URL, segment: AnalysedSegment,
                             cell: CGSize = CGSize(width: 72, height: 96),
                             scale: Int = 2, background: CGColor = …) throws -> CGImage?
}
public final class SubjectPickModel: ObservableObject {
    public let segments: [AnalysedSegment]
    @Published public private(set) var selected: [Int]
    public var selectedInTimeOrder: [Int] { get }
    public func isSelected(_:) -> Bool
    public func isSelectable(_:) -> Bool
    public func exclusionReason(for:) -> String?
    public func toggle(_ id: Int)
}
public struct ClipAnalysis { let version: Int; let analysedAt: Date; let parameters: AnalysisParameters
                             let segments: [AnalysedSegment]; let subject: SubjectPick?
                             func isStale(against:) -> Bool; func with(subject:) -> ClipAnalysis }
public struct SubjectPick { let segmentIDs: [Int]; let runStart: StoredRunStart }
public enum StoredRunStart { case started(time:baseline:threshold:), alreadyRunning(firstSeen:)
                             var syncTime: TimeInterval { get } }
public extension ComparisonModel {
    func applySync(left: TimeInterval, right: TimeInterval)
    var syncOrigin: SyncOrigin { get }   // .manual | .detected(left:right:)
}
```

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/SkiVideoCore/ComparisonModel.swift` (modify) | A status sentence naming a detected sync |
| `Sources/SkiVideoCore/SubjectSessionModel.swift` (create) | Per-side analysis state: idle / running / ready / failed, and the sidecar round-trip |
| `Sources/SkiVideoViewer/Shared/SubjectPickSheet.swift` (create) | The grid of segment cards, progress and cancel |
| `Sources/SkiVideoViewer/Shared/SegmentCard.swift` (create) | One card: strip, range, count, selection and exclusion |
| `Sources/SkiVideoViewer/Shared/ComparisonControlBar.swift` (modify) | One button, plus a secondary action |
| `Sources/SkiVideoViewer/Shared/ComparisonView.swift` (modify) | Sheet presentation |
| `Tests/SkiVideoCoreTests/SubjectSessionModelTests.swift` (create) | State machine, sidecar reuse, staleness |
| `Tests/SkiVideoCoreTests/ComparisonModelTests.swift` (modify) | The detected-sync status sentence |
| `Tests/SkiVideoViewerTests/ComparisonLayoutMeasurementTests.swift` (modify) | Re-measured wrap threshold |
| `Tests/SkiVideoViewerTests/SubjectPickWiringTests.swift` (create) | The sheet's buttons reach the model |

---

### Task 1: The status sentence for a detected sync

**Files:**
- Modify: `Sources/SkiVideoCore/ComparisonModel.swift`
- Test: `Tests/SkiVideoCoreTests/ComparisonModelTests.swift`, and `Tests/SkiVideoViewerTests/ComparisonLayoutMeasurementTests.swift`

**Interfaces:**
- Consumes: `applySync`, `syncOrigin` (Phase A)
- Produces: a `status` string distinguishing a detected sync from a manual one

**Why this is its own task.** The chip that displays `status` is a constant 340pt wide and clipped to two lines, and `ComparisonLayoutMeasurementTests` pins the longest reachable status at **83 characters** — because at that length it already overran into the other pane once. A new, longer sentence is a layout change, and it must be measured before anything is built on top of it.

- [ ] **Step 1: Write the failing tests**

In `ComparisonModelTests.swift`, alongside the `applySync` tests Phase A added:

```swift
    func testADetectedSyncSaysSoInTheStatus() async throws {
        let model = try await makeAlignedModel()

        model.applySync(left: 18.64, right: 4.42)

        XCTAssertTrue(
            model.status.lowercased().contains("detected"),
            "a detected sync must be attributable from the status; got: \(model.status)"
        )
    }

    func testAManualSyncDoesNotClaimToBeDetected() async throws {
        let model = try await makeAlignedModel()
        model.applySync(left: 18.64, right: 4.42)

        model.setSyncPoints()

        XCTAssertFalse(model.status.lowercased().contains("detected"))
    }
```

In `ComparisonLayoutMeasurementTests.swift`, replace the hard-coded 83 in `testTheLongestStatusIsReachableWithNoClipsLoaded` only if measurement requires it — see Step 3 — and add:

```swift
    /// The detected-sync sentence is a new candidate for longest status, and
    /// the chip is a constant 340pt clipped to two lines. If it does not fit,
    /// it is silently truncated — the failure mode the chip's width cap exists
    /// to prevent.
    func testTheDetectedSyncStatusFitsTheChip() async throws {
        let model = try await makeAlignedModel()
        model.applySync(left: 18.64, right: 4.42)

        let height = chipHeight(status: model.status, width: 834)
        let twoLine = chipHeight(status: String(repeating: "x ", count: 60), width: 834)

        XCTAssertLessThanOrEqual(
            height, twoLine,
            "the detected-sync status needs more than two lines: \(model.status)"
        )
    }
```

Use the `chipHeight`/`NSHostingView` harness already in that file; if its helper is named differently, use the existing one and say so in your report.

- [ ] **Step 2: Run to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'ComparisonModelTests|ComparisonLayoutMeasurementTests'`
Expected: the two status tests fail; the chip test may pass or fail depending on the current sentence.

- [ ] **Step 3: Write the sentence, then measure it**

In `applySync`, after establishing sync, set:

```swift
        status = "Synced from detected starts · L \(Timecode.string(left)) · R \(Timecode.string(right))"
```

Then **measure**: print `model.status.count` for that sentence and compare with the 83 the existing test pins. If it is longer, update `testTheLongestStatusIsReachableWithNoClipsLoaded`'s threshold to the new measured figure **and say in your report what the new longest status is and how long**. If the chip test fails, shorten the sentence — dropping the `· L`/`· R` labels, then the word "starts" — until it fits, and report the final wording and its length. Do not widen the chip; its constant width is what makes "it cannot reach the other pane" checkable at all.

- [ ] **Step 4: Run the tests**

Expected: all pass, including every pre-existing test in both files.

- [ ] **Step 5: Mutation-check**

1. Remove the `status = ...` assignment from `applySync`, so it keeps `setSyncPoints`'s sentence. Expected: `testADetectedSyncSaysSoInTheStatus` fails.
2. Make the sentence three lines long (repeat it). Expected: `testTheDetectedSyncStatusFitsTheChip` fails. If it passes, the chip harness is not measuring wrapping and the test is worthless — say so and fix it.

- [ ] **Step 6: Commit**

```bash
git add Sources/SkiVideoCore/ComparisonModel.swift Tests/SkiVideoCoreTests/ComparisonModelTests.swift Tests/SkiVideoViewerTests/ComparisonLayoutMeasurementTests.swift
git commit -m "Say in the status when a sync came from detected starts"
```

---

### Task 2: Per-side analysis state

**Files:**
- Create: `Sources/SkiVideoCore/SubjectSessionModel.swift`
- Test: `Tests/SkiVideoCoreTests/SubjectSessionModelTests.swift`

**Interfaces:**
- Consumes: `SubjectAnalyzer`, `ClipAnalysisStore`, `ClipAnalysis`, `SubjectPick`, `StoredRunStart`
- Produces: `SubjectSessionModel` with `state`, `analyse(clip:)`, `cancel()`, `confirm(segmentIDs:)`, `storedSubject(for:)`

**Why in `SkiVideoCore` and not the view.** Analysis is a ~16s async job with progress, cancellation, disk IO and three failure modes. Putting that in a SwiftUI view makes it untestable without a UI harness; here it is a plain observable object with unit tests.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import SkiVideoCore

final class SubjectSessionModelTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func analysis(subject: SubjectPick?) -> ClipAnalysis {
        ClipAnalysis(
            version: 1, analysedAt: Date(timeIntervalSince1970: 1_754_121_660),
            parameters: .current,
            segments: [
                AnalysedSegment(id: 1, firstSeen: 3.1, lastSeen: 9.7, detectionCount: 214,
                                peakHeightFraction: 0.41, previews: []),
                AnalysedSegment(id: 2, firstSeen: 11.4, lastSeen: 18.2, detectionCount: 137,
                                peakHeightFraction: 0.29, previews: []),
            ],
            subject: subject
        )
    }

    private func clip(_ name: String = "C0094.MP4") -> URL {
        directory.appendingPathComponent(name)
    }

    func testAStoredAnalysisIsReusedWithoutAnalysingAgain() throws {
        try ClipAnalysisStore.save(analysis(subject: nil), for: clip())
        let session = SubjectSessionModel()

        let reused = session.loadStored(for: clip())

        XCTAssertNotNil(reused)
        XCTAssertEqual(reused?.segments.count, 2)
        guard case .ready = session.state else {
            return XCTFail("expected ready, got \(session.state)")
        }
    }

    func testNoSidecarLeavesTheSessionIdle() {
        let session = SubjectSessionModel()

        XCTAssertNil(session.loadStored(for: clip()))
        guard case .idle = session.state else {
            return XCTFail("expected idle, got \(session.state)")
        }
    }

    func testConfirmingAPickWritesItToTheSidecar() throws {
        try ClipAnalysisStore.save(analysis(subject: nil), for: clip())
        let session = SubjectSessionModel()
        _ = session.loadStored(for: clip())

        try session.confirm(
            segmentIDs: [2, 1],
            runStart: .started(time: 4.42, baseline: 1.12, threshold: 2.02),
            for: clip()
        )

        let reloaded = ClipAnalysisStore.load(for: clip())
        XCTAssertEqual(reloaded?.subject?.segmentIDs, [2, 1])
        XCTAssertEqual(reloaded?.subject?.runStart.syncTime ?? 0, 4.42, accuracy: 1e-9)
    }

    func testAnUnwritableFolderStillLeavesThePickUsableInMemory() throws {
        try ClipAnalysisStore.save(analysis(subject: nil), for: clip())
        let session = SubjectSessionModel()
        _ = session.loadStored(for: clip())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: directory.path
            )
        }

        // Persistence failing is not analysis failing: the operator has just
        // done the expensive part and must not lose it because the footage sits
        // on a read-only volume.
        XCTAssertThrowsError(
            try session.confirm(
                segmentIDs: [1],
                runStart: .alreadyRunning(firstSeen: 0.12),
                for: clip()
            )
        )
        XCTAssertEqual(session.pickedSubject?.segmentIDs, [1])
    }

    func testStalenessIsSurfacedWithoutDiscardingThePick() throws {
        var older = AnalysisParameters.current
        older = AnalysisParameters(
            fps: 30, detectionWidth: older.detectionWidth, initialJump: older.initialJump,
            speedMultiplier: older.speedMultiplier, maxHeightRatio: older.maxHeightRatio,
            maxMisses: older.maxMisses, cutOnAmbiguity: older.cutOnAmbiguity,
            minSamples: older.minSamples
        )
        let stale = ClipAnalysis(
            version: 1, analysedAt: Date(timeIntervalSince1970: 1_754_121_660),
            parameters: older, segments: analysis(subject: nil).segments,
            subject: SubjectPick(
                segmentIDs: [1],
                runStart: .started(time: 4.42, baseline: 1.12, threshold: 2.02)
            )
        )
        try ClipAnalysisStore.save(stale, for: clip())
        let session = SubjectSessionModel()

        let loaded = session.loadStored(for: clip())

        XCTAssertTrue(session.isStale)
        XCTAssertEqual(loaded?.subject?.segmentIDs, [1], "a stale pick is kept, not dropped")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Expected: compile failure — `SubjectSessionModel` does not exist.

- [ ] **Step 3: Write the model**

`Sources/SkiVideoCore/SubjectSessionModel.swift`. Shape:

```swift
@MainActor
public final class SubjectSessionModel: ObservableObject {
    public enum State: Equatable {
        case idle
        case analysing(progress: Double)
        case ready(ClipAnalysis)
        case failed(String)
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var isStale = false
    public var analysis: ClipAnalysis? { get }
    public var pickedSubject: SubjectPick? { get }

    public init()

    /// Reads the sidecar if there is one, moving to `.ready`. Returns what it
    /// found so a caller can decide whether to offer analysis.
    @discardableResult
    public func loadStored(for clip: URL) -> ClipAnalysis?

    /// Runs the analysis, publishing progress. Cancels any run in flight first.
    public func analyse(clip: URL) async

    public func cancel()

    /// Records the pick in memory, then writes the sidecar. Throws only on the
    /// write — the pick is kept either way.
    public func confirm(
        segmentIDs: [Int], runStart: StoredRunStart, for clip: URL
    ) throws
}
```

The ordering in `confirm` is the point: update in-memory state **first**, then attempt the write, then rethrow. An operator who has just spent 20 seconds and made a judgement must not lose it because the footage is on a read-only volume.

`analyse` catches `SubjectAnalyzer.AnalysisError` and `CancellationError` separately — a cancel returns to `.idle`, a failure goes to `.failed` with the error's description. It must not leave the state on `.analysing`.

- [ ] **Step 4: Run the tests**

Expected: all pass.

- [ ] **Step 5: Mutation-check**

1. In `confirm`, attempt the write before updating in-memory state and return early on failure. Expected: `testAnUnwritableFolderStillLeavesThePickUsableInMemory` fails.
2. Make `loadStored` return nil when `isStale(against:)` is true. Expected: `testStalenessIsSurfacedWithoutDiscardingThePick` fails.

- [ ] **Step 6: Commit**

```bash
git add Sources/SkiVideoCore/SubjectSessionModel.swift Tests/SkiVideoCoreTests/SubjectSessionModelTests.swift
git commit -m "Hold per-side analysis state and the sidecar round-trip"
```

---

### Task 3: The segment card and the picking sheet

**Files:**
- Create: `Sources/SkiVideoViewer/Shared/SegmentCard.swift`
- Create: `Sources/SkiVideoViewer/Shared/SubjectPickSheet.swift`
- Test: `Tests/SkiVideoViewerTests/SubjectPickWiringTests.swift`

**Interfaces:**
- Consumes: `SubjectPickModel`, `SubjectSessionModel`, `SegmentThumbnails`, `AnalysedSegment`
- Produces: `SubjectPickSheet(session:clip:onConfirm:)`, and the accessibility identifiers `Segment <id>`, `Use as subject`, `Cancel analysis`

- [ ] **Step 1: Write the card**

One card per segment, laid out as a horizontal strip of its previews above two lines of text:

```
┌──────────────────────────────────┐
│ [img][img][img][img][img]        │
│ 29.9s – 46.3s                    │
│ 408 samples                      │
└──────────────────────────────────┘
```

- The strip comes from `SegmentThumbnails.strip(clip:segment:)`, rendered **off the main thread** and cached per segment id. Five seeks per card times a dozen cards is seconds of work; doing it synchronously in `body` freezes the sheet.
- Selected cards get a visible accent border and a checkmark. Selection state must be legible without colour alone.
- An unselectable card is dimmed and shows `model.exclusionReason(for:)` in place of its sample count. **Show the reason, do not merely disable** — a control that does nothing with no explanation reads as a bug.
- `.accessibilityIdentifier("Segment \(segment.id)")`, `.accessibilityLabel` naming the range and count, and `.accessibilityAddTraits(.isSelected)` when selected.
- 44pt minimum tap target for the card's tap area.

- [ ] **Step 2: Write the sheet**

Four states, matching `SubjectSessionModel.State`:

- **idle** — a single "Find subject" button and one line saying roughly how long it takes.
- **analysing** — a *determinate* `ProgressView(value:)` and a Cancel button. A 16-second job with an indeterminate spinner and no escape is the wrong shape; both are required.
- **ready** — a `LazyVGrid` of cards, adaptive with a minimum column width, plus a footer with the selection summary and **Use as subject**, disabled until at least one segment is selected.
- **failed** — the message and a Retry button. `SubjectAnalyzer.AnalysisError.noPeopleFound` is an expected outcome, not a crash: say "No people were detected in this clip" and offer Retry, nothing more alarming.

The sheet must work at iPad portrait widths. Follow the `ViewThatFits` and fixed-width discipline documented in `ComparisonControlBar.swift`.

`onConfirm` receives `selectedInTimeOrder`; the sheet does not compute the run start itself — Task 4 owns that, so the sheet stays a view.

- [ ] **Step 3: Write the wiring tests**

`Tests/SkiVideoViewerTests/SubjectPickWiringTests.swift`, following `SharedControlsWiringTests.swift` in the same directory — read it first and mirror its harness rather than inventing one.

Cover: tapping a card toggles selection in the model; tapping an excluded card does not; **Use as subject** is disabled with an empty selection and enabled with one; **Use as subject** calls `onConfirm` with the selected ids in time order; Cancel calls `session.cancel()`.

- [ ] **Step 4: Run and mutation-check**

1. Make the card's tap action call `toggle` unconditionally, ignoring `isSelectable`. Expected: the excluded-card test fails.
2. Remove the `disabled` on **Use as subject**. Expected: the empty-selection test fails.

Report both. A surviving mutation means the harness is not exercising the control — say so.

- [ ] **Step 5: Commit**

```bash
git add Sources/SkiVideoViewer/Shared/SegmentCard.swift Sources/SkiVideoViewer/Shared/SubjectPickSheet.swift Tests/SkiVideoViewerTests/SubjectPickWiringTests.swift
git commit -m "Add the subject picking sheet"
```

---

### Task 4: The entry point, and re-measuring the bar

**Files:**
- Modify: `Sources/SkiVideoViewer/Shared/ComparisonControlBar.swift`
- Modify: `Sources/SkiVideoViewer/Shared/ComparisonView.swift`
- Test: `Tests/SkiVideoViewerTests/ComparisonLayoutMeasurementTests.swift`

**Interfaces:**
- Consumes: `SubjectPickSheet`, `SubjectSessionModel`, `ComparisonModel.applySync`
- Produces: the accessibility identifier `Find subject`

**Read `ComparisonControlBar.swift`'s header comment before editing.** It records measurements that adding a control will invalidate, and the reasoning behind each fixed width.

- [ ] **Step 1: Add one control, not two**

A single 44×44 button beside the anchor, `person.crop.rectangle` or similar, which opens the sheet **for the targeted side** — `model.target.scrubbedSide`, the same rule the scrubber and time label already follow, so the bar has one notion of which side controls act on.

Its secondary action, as a `contextMenu` exactly like the anchor's, offers **Sync from detected starts**, enabled only when both sides have a stored subject. Follow the anchor's pattern: the whole `contextMenu` is conditional, not just its contents — a menu whose only item is disabled still pops up empty.

Two buttons would cost another 60pt of bar. One button plus a secondary action is the established shape here and is why the anchor absorbed three text buttons.

- [ ] **Step 2: Present the sheet from `ComparisonView`**

`ComparisonView` owns the two `SubjectSessionModel`s, one per side, and presents the sheet. On confirm it calls `SubjectAnalyzer.runStart`, then `session.confirm(...)`, then — when both sides have a subject — `model.applySync(left:right:)`.

Per the spec the sync applies immediately. When either side's stored run start is `.alreadyRunning`, its sync time is that clip's first sample: apply it, and let the status say the sync came from detected starts as Task 1 arranged.

A `confirm` that throws means the sidecar could not be written. Surface it once, plainly, and keep going — the pick is still good for this session.

- [ ] **Step 3: Re-measure the wrap threshold**

`testTheBarWrapsBetween880And881Points` asserts the bar's ideal width to the point. Adding a control **will** break it, and that is the test working: it is a measurement, not a preference.

Measure the new ideal width with the existing harness, rename the test to the new figure, and update its literals. Then confirm the two assertions that actually matter still hold:

- at 834pt and 744pt the bar is still **two rows**, not three
- the synced and aligning states still produce the **same** height at both widths — the constant-width picker discipline exists precisely so tapping the anchor cannot reflow the bar

Report the old and new ideal widths verbatim. **If the bar now needs three rows at 834pt, stop and report it** rather than shrinking a control to force a fit; that is a design decision, not an implementation one.

- [ ] **Step 4: Run the full suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: all pass. Report the total.

- [ ] **Step 5: Mutation-check**

1. Change the sheet to open for a fixed side rather than `model.target.scrubbedSide`. Expected: a wiring test fails — if none does, add one, because "acts on the targeted side" is the whole rule.
2. Make the `contextMenu` unconditional. Expected: a test asserting no empty menu while unanalysed fails; add it if absent.

- [ ] **Step 6: Commit**

```bash
git add Sources/SkiVideoViewer/Shared/ComparisonControlBar.swift Sources/SkiVideoViewer/Shared/ComparisonView.swift Tests/SkiVideoViewerTests/ComparisonLayoutMeasurementTests.swift
git commit -m "Open the subject sheet from the comparison bar, and re-measure it"
```

---

### Task 5: Prove it on real footage

**Files:** none — this task's deliverable is evidence

- [ ] **Step 1: Run the pair**

Open `Idun Nielsen/C0094.MP4` and `Fabien Wiest/C0092.MP4` in the comparison window. Find subject on each, pick the athlete's segments, confirm.

Expected picks, from the verified decomposition: C0094 the four segments spanning 13.8–46.3s; C0092 the three spanning 0.5–26.2s. Expected starts: **18.6s** and **4.4s**.

- [ ] **Step 2: Report the evidence**

**Screenshot every step and list each image with what it shows.** At minimum: the sheet mid-analysis with its progress bar; the grid for both clips; the grid with an overlapping segment visibly excluded and its reason shown; the synced pair with the status chip readable.

State plainly whether the athlete was identifiable from the five-frame strips **in the running app** — that assumption was verified against rendered PNGs, not against the shipped sheet, and the sheet's cell size or scaling may differ from what was measured.

- [ ] **Step 3: Prove the sidecar earns its place**

Close the comparison window and reopen the same pair. **Sync from detected starts** must be available immediately, apply the same times, and not re-analyse — time it and report the figure. If it re-analyses, the feature has not achieved its purpose and that is the finding.

Confirm `C0094.skianalysis.json` exists beside the clip and report its contents.

- [ ] **Step 4: Report honestly**

Report what happened, including anything that looked wrong. A measured failure here is worth more than a clean report: the whole point of Phase A's verification discipline was that four separate claims in this project turned out to be false when the images were finally looked at.

---

## Self-Review Notes

- **Spec coverage.** Sheet → Task 3. Entry points → Task 4. Immediate sync application → Task 4. Status attribution → Task 1. Sidecar reuse and staleness → Task 2. Overlap exclusion → surfaced in Task 3's card, enforced by Phase A's `SubjectPickModel`. Verification → Task 5.
- **Two integration constraints the spec did not anticipate**, both found by reading the merged viewer redesign: the bar's wrap threshold is asserted to the point and must be re-measured rather than relaxed (Task 4 Step 3), and the status chip is a constant 340pt clipped to two lines with the longest status pinned at 83 characters, so a new sentence is a layout change (Task 1).
- **Deliberately not here.** Batch analysis; an entry point in the main viewer; a detected-start marker on the comparison scrubber; re-identification across clips. The first three are small follow-ups once this lands.
- **Known open defects in the detection layer, unchanged.** A truncated upper-body detection breaks the track (C0094 at 24.76s); the missing-segment warning false-alarms when the camera pans away (C0089 at 5.04s). Neither blocks this work, and neither should be fixed inside it.
- **Two performance follow-ups from Phase A that the operator will feel here.** `analyse` and `runStart` each decode and pose-detect the clip independently, so confirming a pick costs a second ~20s pass; and cancellation cannot interrupt the initial decode, so Cancel is ignored for the first ~6s. Both are `SubjectAnalyzer` changes. If Task 5's evidence shows either is intolerable in use, say so — that is the signal to do them next.
