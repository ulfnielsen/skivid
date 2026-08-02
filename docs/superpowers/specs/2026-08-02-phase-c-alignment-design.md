# Phase C — Landmark Alignment — Design

**Depends on:** `2026-08-02-phase-c-alignment-findings.md` (the measurement this is built on)
and `2026-08-02-subject-sync-design.md` (which supplies the run starts).

## Why

Overlay mode draws both clips into one rect with no spatial alignment, so difference
blending is only readable when the two runs happened to be filmed from about the same camera
position. Registering the background makes it readable in general.

The measurement says this is worth doing and says how. At equal run phase, translational
registration beats identity comfortably for roughly two thirds of the first 17 seconds
(t = 0–4 and t = 8–13, overlap 0.68–0.92, residual roughly half of identity), and fails in
between — not by aligning wrongly, but by finding a large true translation that leaves the
two frames little shared view. Inside even a small overlap the terrain still cancels.

Three things follow, and two contradict what the lab's exporter does today: gate on
**overlap**, do not **latch off** (recovery is real and lasts seconds), and fall back to
**identity** rather than to a held warp that shoves one clip into the corner.

## Shape

Alignment is a **precomputed track**, not a live computation.

Registering a frame pair costs 7–10 ms at half scale. Doing that during playback, on top of
decoding two streams that are being kept in sync, risks dropping frames at 50 fps — and a
stutter in a synced pair is exactly the thing the operator is looking at. So the pass runs
once, like subject analysis, and playback applies a stored translation, which is free.

It is also what makes the exporter and the live overlay agree: both consume the same track
rather than each registering for themselves.

## The track

```swift
/// One registered frame pair.
public struct AlignmentSample: Codable, Equatable, Sendable {
    /// Seconds after the run start, common to both clips.
    public let time: TimeInterval
    /// Applied to the right clip to bring it onto the left, in normalised
    /// frame widths so it survives a change of working resolution.
    public let translation: CGVector
    public let overlap: Double
    public let residual: Double
    /// What the residual would have been with no warp. Stored so "did
    /// alignment earn its place" stays answerable from the file.
    public let identityResidual: Double
}

public struct AlignmentTrack: Codable, Equatable, Sendable {
    public let version: Int
    public let computedAt: Date
    public let leftClip: String
    public let rightClip: String
    /// The run starts this was computed against. A track computed for
    /// different starts describes a different comparison and must not be used.
    public let leftStart: TimeInterval
    public let rightStart: TimeInterval
    public let parameters: AlignmentParameters
    public let samples: [AlignmentSample]
}
```

Only a **translation** is stored. Homographic registration was measured worse than identity
at two of three scales on this footage, and a translation keeps both the file and the
playback transform trivial.

Samples are stored **raw** — ungated and uneased. The gating thresholds are a judgement the
data does not fully settle, so they are applied on load, and changing them costs nothing.
This is the same principle the subject sidecar follows: record what was measured, decide
separately.

At 25 fps over 20 s that is 500 rows of five numbers — tens of kilobytes.

### Storage

`<leftStem>--<rightStem>.skialignment.json`, beside the left clip. A track describes a
*pair*, so it cannot live in either clip's own sidecar.

`leftStart`/`rightStart` are recorded because a track is only meaningful for the sync it was
computed against. If either has changed, the track is stale — reported, not deleted, exactly
as `ClipAnalysis` handles staleness.

## Gating and easing

Applied when a track is loaded, never baked into the file.

- **Engage** when overlap rises above **0.68**; **disengage** when it falls below **0.55**.
  Two thresholds, not one: the measured good windows sit at 0.68 and above and the bad ones
  at 0.49 and below, so the gap is wide, and a single threshold would flap wherever the
  signal crosses it.
- **Ease** between engaged and identity over **0.25 s** rather than cutting. The boundary is
  crossed several times in 17 s, and a hard cut is a visible jump each time.
- **Never latch.** The lab's exporter stops for the remainder of the clip after three
  consecutive failures, on the reasoning that divergence is monotonic. It is not: the
  measured recovery at t = 8 holds for five seconds. Latching would discard it.
- **Fall back to identity**, not to the last good warp. Holding a stale translation through
  a low-overlap stretch is what puts one clip in the corner — measured at t = 5.

```swift
public enum AlignmentGate {
    /// The eased, gated translation to apply at `time`, or nil for identity.
    public static func translation(
        in track: AlignmentTrack,
        at time: TimeInterval,
        engageAbove: Double = 0.68,
        disengageBelow: Double = 0.55,
        easeSeconds: Double = 0.25
    ) -> CGVector?
}
```

Between samples the translation is linearly interpolated, but **only inside an engaged
run** — interpolating across a disengaged stretch would invent a warp for frames that were
measured not to have one.

## Components

### `SkiVideoCore`

- `AlignmentTrack.swift` — the types above, plus `AlignmentParameters` (sample rate, working
  width, registration method) and staleness against a pair of run starts.
- `AlignmentTrackStore.swift` — the pair-keyed sidecar, mirroring `ClipAnalysisStore`.
- `AlignmentAnalyzer.swift` — the pass: read both clips from their run starts, register each
  sampled pair, emit the track. Async, determinate progress, cancellable between pairs.
- `AlignmentGate.swift` — the pure gating and easing above.
- `FrameRegistration` is already here.

### The app

Overlay mode gains an **Align** toggle, disabled until a track exists, and a **Compute
alignment** action beside it. `OverlayPlayerStack` takes an optional translation and applies
it to the top player's rect; it stays a pure renderer and does not learn about tracks.

The status chip says when alignment is disengaged, so a stretch of unaligned overlay reads
as a decision rather than a failure.

### The exporter

`OverlayClipWriter` lives in the `landmark-align` worktree and is not in the app. Porting it
is its own task; this design's contribution is that it should consume the same
`AlignmentTrack` and the same `AlignmentGate`, deleting its own registration and its
give-up rule — which the measurement has now disproven.

## Testing

`AlignmentGate` is pure and gets the load-bearing tests, all on synthetic tracks:

- overlap rising through 0.68 engages; falling through 0.55 disengages; a signal oscillating
  **between** the two thresholds does not flap — this is what the two-threshold design
  exists for, and a single-threshold implementation must fail it
- the easing reaches identity over `easeSeconds` and does not overshoot
- interpolation happens inside an engaged run and **not** across a disengaged one
- a long disengaged stretch followed by recovery **re-engages** — the anti-latch test, and
  the one that would have caught the exporter's current behaviour
- an empty track yields identity everywhere rather than crashing

Staleness: a track whose `leftStart` differs from the current run start is reported stale and
its samples are kept.

Every one of these is mutation-verified. Seven tests in this project's recent history passed
regardless of the logic they targeted; assume the eighth is in here somewhere.

`AlignmentAnalyzer` is covered by verification, not unit tests.

## Verification

Compute a track for C0094 + C0092 at the detected starts, then:

1. Report the fraction of samples engaged, and where the engaged windows fall. They should
   reproduce the measured t = 0–4 and t = 8–13.
2. Render the overlay in difference mode, aligned and unaligned, and **send both** with the
   timestamps used. The aligned one should show terrain cancelling to near-black with the
   skiers standing out; the unaligned one should not.
3. Show a transition: frames either side of a disengage, proving the ease rather than a jump.
4. Report the wall-clock cost of the pass, and confirm a second open of the same pair reuses
   the track without recomputing.

**Then repeat the sweep on a second synced pair before the thresholds are considered
settled.** The findings rest on one clip pair, one frame per sample; the good and bad
stretches were contiguous rather than alternating, which argues against noise, but the
windows may sit elsewhere on other footage. If they do, the thresholds are the thing to
revisit — not the design, which only assumes that good and bad windows exist and are
separable by overlap.

## Not in this

- Homographic or affine registration. Measured worse than identity here; revisit only with
  evidence.
- Aligning in side-by-side layout, where each clip has its own pane and a warp means nothing.
- Time-warping one skier onto the other's pace. That is a different feature and remains
  unspecified.
- Any change to subject detection or run-start detection.
