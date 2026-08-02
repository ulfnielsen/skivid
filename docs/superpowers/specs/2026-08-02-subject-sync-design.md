# Subject Picking and Automatic Sync — Design

## Why

Comparing two runs requires them to start at the same moment. Today that sync point is set
by hand: scrub each clip to the instant the athlete leaves the gate, then press *Set sync
points*. It is fiddly, it is the step people get wrong, and it has to be redone every time
the pair is opened.

Work in the `landmark-align` worktree built the measurement half of a solution and verified
it against four ground-truth clips:

| clip | detected | truth | error |
|---|---|---|---|
| Idun C0082 | 3.8 s | ~2.0 s | +1.8 s |
| Idun C0094 | 18.6 s | 19.0 s | −0.4 s |
| Fabien C0092 | 4.4 s | ~3.8–5.0 s | within |
| Marc C0089 | "already in progress, at or before 0.1 s" | 0.0 s | correct outcome |

The measurement only works because a human names the subject first. Twelve automatic
subject-selection approaches were tried and the best got one clip of four right; the
failure is not tuning but the fact that "which of several skiers is the interesting one" is
a question about the operator's intent. So the operator picks, once per clip, and the
answer is stored.

This spec covers the app side: the picking UI, the storage, and applying the result as a
sync point.

## Storage

Each clip gets a sidecar beside it: `C0094.MP4` → `C0094.skianalysis.json`.

```json
{
  "version": 1,
  "analysedAt": "2026-08-02T08:41:00Z",
  "parameters": {
    "fps": 25, "detectionWidth": 320, "initialJump": 0.06,
    "speedMultiplier": 4.0, "maxHeightRatio": 1.15,
    "maxMisses": 10, "cutOnAmbiguity": true, "minSamples": 8
  },
  "segments": [
    {
      "id": 1, "firstSeen": 29.92, "lastSeen": 46.32,
      "detectionCount": 408, "peakHeightFraction": 0.53,
      "previews": [
        { "time": 29.92, "box": [0.55, 0.15, 0.07, 0.17] }
      ]
    }
  ],
  "subject": {
    "segmentIDs": [3, 4, 5, 1],
    "runStart": { "kind": "started", "time": 18.6, "baseline": 1.89, "threshold": 3.39 }
  }
}
```

A sidecar was chosen over a library index or an application-support cache because it
travels with the footage: copy an athlete's folder to another machine and the analysis goes
with it, and the file is readable and correctable by hand.

**Five previews per segment**, each a time and a normalised box, so the picker redraws its
thumbnail strip with a handful of frame seeks. No images are written next to the footage.
Five is a starting point, chosen to be revisited once the grid has been used in anger.

**Individual detections are not stored.** A 45 s clip yields ~750 detections of 19 joints
each — roughly a megabyte of JSON per clip — and nothing downstream consumes them yet. A
later feature that needs the trajectory can recompute it.

`runStart.kind` is one of `started`, `alreadyRunning`, `neverMoves`, mirroring
`SubjectRunStart.Outcome`. `alreadyRunning` carries `firstSeen` instead of `time`; the sync
point in that case is the clip's first frame, and the UI must say so rather than presenting
a fabricated number.

If the footage folder is not writable, the analysis still completes and is used for the
session; the failure to persist is reported once, plainly, and is not treated as an
analysis failure.

## Staleness

`parameters` records the settings that produced the file. When they differ from the current
defaults the sidecar is marked stale — but nothing is discarded and nothing is recomputed
automatically.

The reasoning: the run start is a *time*, and a time does not expire. The segment list is
working data, and the operator's pick is expensive human input. A stale sidecar therefore
keeps showing its run start and its pick, labelled as produced by older settings, with a
*Re-analyse* action. Silently recomputing would throw away a human decision to chase a
number that was probably already right.

## Components

### `SkiVideoCore` (new files)

Ported unchanged from the `landmark-align` worktree, which has diverged from main and does
not contain the current app structure:

- `PoseDetection.swift` — `PoseDetection`, `FrameDetections`
- `PoseDetector.swift` — Vision body-pose detection
- `TrackletLinker.swift` — commit-and-follow linking with motion-derived gates
- `SubjectCandidates.swift` — grouping into segments
- `SubjectRunStart.swift` — run start inside the subject's box
- `ClipFrameReader.swift` — sequential `AVAssetReader` decode

The worktree's constraint that `SkiVideoCore` must not import AVFoundation no longer
applies: on main, `ComparisonModel`, `ViewerModel` and `SortingModel` already do.

New:

- `ClipAnalysis.swift` — the Codable model above, plus `ClipAnalysisStore` with
  `load(for: URL)` and `save(_:for:)`
- `SubjectAnalyzer.swift` — orchestrates read → detect → link → group into a
  `ClipAnalysis` with no subject set. Async, reports determinate progress, and honours
  cancellation between frames.
- `SubjectPickModel.swift` — observable state for the sheet: segments, selection,
  which segments are disabled, and the resulting run start.

### `ComparisonModel` (modified)

- `applySync(left: TimeInterval, right: TimeInterval)` — seeks both sides and reuses the
  existing sync mechanism, so all current invariants and nudge behaviour are untouched.
- A published `syncOrigin` of `manual` or `detected(left:right:)`, so the status chip can
  say where the sync came from. A wrong automatic sync must be attributable.

### UI (`Sources/SkiVideoViewer/Shared`)

- `SubjectPickSheet.swift` — the grid
- A **Find subject** action per side in the comparison window, and **Sync from detected
  starts** once both sides have a stored subject

## The picking flow

1. **Find subject** on one side. Analysis runs for roughly 20 s on a 45 s clip, so it shows
   a determinate progress bar and a Cancel that actually stops it. A modal spinner with no
   escape is the wrong shape for a 20-second job.
2. The sheet presents segments ordered by detection count. Each card shows a horizontal
   strip of its five preview crops, its time range, and its sample count.
3. Selection is multiple, because a subject's run spans several segments — on C0094 the
   athlete occupies four.
4. **Segments overlapping in time are mutually exclusive.** Selecting one disables any that
   overlap it, with the reason shown. This is not a nicety: C0082 produced 779 detections
   over 776 samples because two picked segments overlapped, which is only possible if one
   of them is a different person. The constraint turns a silent corruption into an option
   the UI will not offer.
5. Confirming measures the run start, writes the sidecar, and applies the sync point
   immediately. The existing nudge controls correct it if it is wrong — which, on the
   measured evidence, it sometimes will be.

Once both sides have a stored subject, **Sync from detected starts** applies both in one
action, reading the sidecars without recomputing.

## Merging with the viewer redesign

`viewer-redesign` is in flight and has completed Tasks 1–2 of 4. Those are already on that
branch and touch files this work also touches:

- `ComparisonModel.swift` — the timecode formatter moved out to `Timecode.swift`
- `ComparisonControlBar.swift` — the six transport buttons extracted into a shared
  `TransportControls`
- `ComparisonScrubber.swift` — the timeline extracted into a shared `TimelineScrubber`
- `ViewerModel.swift` — gained `currentTime`, `duration`, transport and scrub

Its remaining Tasks 3–4 create `ViewerPane.swift` and `ViewerControlBar.swift`, modify
`ContentView.swift`, and add layout and UI tests. **They do not return to any comparison
file.**

This work is therefore split into two phases that can proceed independently.

### Phase A — core, no UI

The ported detection files, `ClipAnalysis`, `ClipAnalysisStore`, `SubjectAnalyzer`,
`SubjectPickModel`, and the `ComparisonModel` additions. Every file is new except
`ComparisonModel.swift`, where the change is two additions in a region the redesign does not
touch. Phase A branches off `main` and can land at any time, in parallel.

### Phase B — the sheet and the entry points

`SubjectPickSheet.swift` plus the two actions in `ComparisonControlBar`. **Branch this off
`main` after `viewer-redesign` merges**, not before. Not because the hunks would conflict —
they probably would not — but because the redesign establishes the conventions this sheet
must follow, and writing it against the pre-merge shape means rewriting it after:

- Reuse `TransportControls` and `TimelineScrubber` if the sheet needs a preview transport;
  do not build a third variant.
- Follow the `ViewThatFits` two-row pattern and the 44pt-touch-target rule already
  documented at the top of `ComparisonControlBar.swift`. The 44pt rule applies to controls
  we build, not to system controls.
- Follow the accessibility-identifier convention Task 3 establishes, including the
  `Status: ` prefix on status chips, so the UI tests can address the new surface the same
  way.

### Explicitly avoided

The design puts **no marker on the comparison scrubber** for the detected run start, and no
entry point in the main viewer. Both would land in files the redesign is actively
restructuring, for a benefit the status chip already delivers. If a scrubber marker turns
out to be wanted, it is a small follow-up once both branches are merged.

## Testing

The pure parts get unit tests in `SkiVideoCoreTests`:

- `ClipAnalysis` round-trips through JSON, including each `runStart.kind`, and an unknown
  `kind` from a future version decodes as an error rather than crashing or silently
  becoming `started`.
- `ClipAnalysisStore` returns nil for a missing sidecar, reports rather than throws when
  the directory is unwritable, and does not overwrite a sidecar it failed to parse.
- Staleness compares parameters and flags a difference without mutating the file.
- Overlap exclusion: given segments with known ranges, selecting one returns the correct
  disabled set, including the case where a segment overlaps two others that do not overlap
  each other.
- `applySync` sets both sides and reports `detected` as the origin; a subsequent manual
  `setSyncPoints` flips the origin back to `manual`.

Every load-bearing test is verified by mutation — break the rule it targets, confirm it
fails, revert, report both outcomes. This is not boilerplate: in the detection work, four
tests turned out to pass regardless of the logic they claimed to cover, and each was found
only this way.

`SubjectAnalyzer` and the frame reader are exercised end to end against
`Idun Nielsen/C0094.MP4`, asserting the sidecar it writes names four segments covering the
athlete's run and a start within a second of 19.0 s.

## Verification

On the real footage, in the app:

1. Open Idun C0094 and Fabien C0092 in the comparison window.
2. Find subject on each; pick the athlete's segments from the grid.
3. Confirm the sync applies and the chip attributes it.
4. Close and reopen the pair: **Sync from detected starts** must be available immediately
   and must not re-analyse.
5. Screenshot the grid for both clips and the synced pair, and report whether the athlete
   is identifiable from the five-frame strips alone — that is the assumption the whole
   picking flow rests on, and it has not been tested at five frames.

## Not in this

- Batch analysis of a folder
- Re-identification of the same athlete across clips
- Storing trajectories
- Any change to the detection algorithm. Two known defects stay open: a truncated
  upper-body detection breaks the track (visible on C0094 at 24.76 s), and the
  missing-segment warning false-alarms when the camera pans off the athlete (C0089 at
  5.04 s). Neither blocks this work.
- The main viewer's entry point. The sheet is self-contained, so adding it there later is
  small; the comparison window is where sync is used and is the smaller surface to get
  right first.
- **Spatially aligning the two clips.** That is Phase C; see below.

## Phase C — landmark alignment, after this lands

Overlay mode draws both clips into the same rect with no spatial alignment, so difference
mode is only readable when both runs happened to be filmed from about the same camera
position. Aligning them on background landmarks is the obvious next step, and it belongs
**after** this work rather than beside it: registration compares terrain, and terrain only
matches when both clips are at the same point in the run. Time sync is the precondition.

The registration machinery already exists in the `landmark-align` worktree — per-frame
`VNTranslationalImageRegistrationRequest`, temporal smoothing, a give-up rule, and
`OverlayClipWriter`. Only `FrameRegistration.swift` was ported here, and only because
`SubjectRunStart` uses it to cancel a single clip's camera pan. Nothing registers one clip
against the other.

**Do not port it before re-measuring it.** Its one recorded finding is that alignment
decays as the clip goes on:

| source time | best residual | overlap |
|---|---|---|
| 2.0 s | 4.92 | 0.842 |
| 3.5 s | 6.05 | 0.878 |
| 5.0 s | 9.04 | 0.759 |

which is what the give-up rule was built around. But that was measured on **wrongly-synced
footage of the wrong two skiers**: at equal elapsed time the two clips showed different
parts of different runs, so the terrain diverging says nothing about whether alignment
works. The thresholds derived from it inherit the same problem.

So Phase C starts with a measurement, not an implementation: re-run the alignment sweep on
a correctly-synced pair and see how long registration actually holds. If it still collapses
within a few seconds, the honest outcome is not to ship it. If it holds, port it and wire
it to Overlay mode using the sync point this work detects.
