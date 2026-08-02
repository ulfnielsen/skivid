# Phase C — landmark alignment, re-measured on synced footage

**Date:** 2026-08-02
**Status:** measurement complete; design follows from it

## Why this was re-measured

The only recorded finding about landmark alignment said it decays as the clip goes on:

| source time | best residual | overlap |
|---|---|---|
| 2.0 s | 4.92 | 0.842 |
| 3.5 s | 6.05 | 0.878 |
| 5.0 s | 9.04 | 0.759 |

That was measured at equal **elapsed** time on a pair whose runs start 14 seconds apart, so
it compared two different parts of two different runs. Registration matches terrain, and
the terrain differed for reasons that had nothing to do with registration. The give-up rule
in `OverlayClipWriter` was built on that number and inherits the problem.

With the run starts now detected — C0094 at 18.56 s, C0092 at 4.40 s — the same sweep can
be run at equal **run phase**, which is what the measurement was always supposed to mean.

## What was measured

`RegistrationLab <C0094> 18.56+t <C0092> 4.40+t`, t from 0 to 17 in 0.5 s steps, reading
the translational result at 0.50 scale — the cheapest one, and the one the exporter uses.

| window | overlap | residual vs identity |
|---|---|---|
| **t = 0.0 – 4.0** | 0.82 – 0.92 | beats identity by 4 – 8 |
| t = 4.5 – 7.5 | 0.23 – 0.49 | **worse than identity** |
| **t = 8.0 – 13.0** | 0.68 – 0.83 | beats identity by 3 – 6 |
| t = 13.5 – 17.0 | 0.09 – 0.60 | worse |

## What it means

**Alignment is not monotonic decay. It is two good windows with a bad one between them.**
The old finding was an artefact of the sync error, and the "divergence is monotonic"
premise the give-up rule rests on is false on this evidence.

**The failure mode is not misalignment — it is loss of shared view.** From the difference
composites (`/tmp/align-t10.0/diff-translational-0.5.png`,
`/tmp/align-t5.0/diff-translational-0.5.png`, dark = matched):

- At t = 10.0 the warped frame covers most of the image, the snow, tracks and gate poles
  all cancel to near-black, and only the people stand out bright. That is registration
  working.
- At t = 5.0 the recovered translation is large, so the two frames overlap only in a small
  rectangle near the top. **Inside that rectangle the terrain still cancels.** The warp is
  not wrong; the cameras are genuinely looking at different parts of the hill, and matching
  them costs most of the frame.

So low overlap means "these two frames have little in common right now", not "the
registration is bad". That is a clean, cheap health signal, and it is already computed.

## Design consequences

Three things follow, and two of them contradict what `OverlayClipWriter` does today:

1. **Gate on overlap, not on a failure count.** Apply the warp while overlap is healthy —
   the two good windows sit at 0.68 and above, the bad ones at 0.49 and below, so the
   threshold has a wide gap to sit in. Anything in the 0.5 – 0.65 band is a judgement call
   the data does not settle.
2. **Do not latch off.** The current rule stops for the remainder of the clip after three
   consecutive failures, justified by divergence being monotonic. Recovery here is real and
   lasts about five seconds, so latching would discard a genuinely alignable window.
3. **Fall back to identity, not to the last good warp.** Holding a stale warp through a
   low-overlap stretch shoves one clip mostly off-screen — visible at t = 5.0, where the
   floating frame sits in the top-left corner. Unaligned is honest; a large stale
   translation is not.

## Caveats

One clip pair, one frame pair per sample. The good and bad stretches are contiguous rather
than alternating, which argues against noise, but this is a single pair and the windows may
sit elsewhere on other footage. Before any threshold is fixed, the sweep should be repeated
on a second synced pair.

Nothing here has been ported into the app. `FrameRegistration` is in `SkiVideoCore` only
because `SubjectRunStart` uses it to cancel one clip's own camera pan; nothing registers one
clip against another. The rest still lives in the `landmark-align` worktree.

---

## Addendum: the second pair (2026-08-02)

The spec required the sweep to be repeated on a second synced pair before the thresholds
were considered settled. Done, on `Idun Nielsen/C0082.MP4` (run start 3.8 s) against
`Marc/C0089.MP4` (already running at first frame, 0.1 s), t = 0…17.

**Overlap essentially never reaches the engage threshold.** Of 35 samples, one clears 0.68
(t = 16.5, 0.816); the next highest are 0.609 and 0.605, and everything else is at or below
0.432. Under the shipped gate this pair is never aligned.

**That is the correct outcome, not a threshold problem.** Registration finds genuinely low
residuals here — t = 5.0 reads 6.28 against an identity of 16.42, "better by 10.14" — but on
an overlap of 0.146. The composite (`/tmp/pair2-t5/diff-translational-0.5.png`) shows why:
the warped frame is pushed almost entirely off the top-left corner, the terrain inside that
small rectangle matches, and the remaining 85 % of the picture has nothing to compare
against at all. A superb residual measured over a sliver says nothing about the alignment
an operator would see.

Three things follow:

1. **The thresholds carry over unchanged.** They were derived on one pair and are here
   exercised on a pair they reject wholesale, which is the harder test of the two. Nothing
   in the second pair argues for moving them.
2. **Residual alone is not a quality signal, and overlap is not a secondary check.** This is
   the design's central bet — gate on overlap — and the second pair is the case that would
   have exposed it as wrong. It does not.
3. **Alignment is a pair-dependent feature, and the honest answer is often "no".** It
   applies when the two runs were filmed from similar camera positions on the same course
   and declines otherwise. The app must therefore say when alignment is unavailable for a
   pair rather than presenting an Align control that appears broken — the status chip
   already reports disengagement, and a pair that never engages should read the same way.

What is still unmeasured: whether the flicker at t ≈ 4.7 on the first pair is visible in
motion, and whether the 5-sample median wants to be longer. Both need the running app.
