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
