# Viewer Screen Redesign — Touch and Mac

**Date:** 2026-08-01
**Status:** Approved design, not yet implemented
**Applies to:** the main player (viewer) screen on both macOS and iPadOS

## Problem

Two things are wrong with the viewer, and only one of them is visual.

### The screen cannot be seeked on iPad at all

`seek(seconds:)` in `ViewerModel` is private and reachable only through a
`PlaybackIntent` emitted by the platform's `PlaybackInputSource`. On macOS,
`AppKitInputSource` emits those intents from the arrow keys. On iPadOS the
implementation is `InertInputSource`, which by design emits nothing:

```swift
/// Phase 3 has no iPad input source. Touch gestures and hardware-keyboard
/// support arrive in phase 4; until then the app is driven entirely by the
/// on-screen list and transport buttons, and this emits nothing.
```

So on iPad there is no way to move within a clip — not by gesture, not by
control, not at all. The only playback actions are play/pause and stepping to
another clip.

### The control band spends its space on things that do not work

Measured from the shipping build's source (`ContentView.swift:189-225`), the
band is roughly 125–135pt: 16pt padding, a stacked athlete-name and
clip-description block at about 51pt, 10pt spacing, a button row that becomes
about 40pt once the hint text wraps to two lines, and 16pt padding.

What that buys: three text buttons, a two-line label, and this hint line —

```
↑/↓ clips · Page Up/Down athletes · ⌘F find athlete · Space play/pause
                                     · ←/→ tap, double-tap, or hold
```

— which is the widest element in the band, describes five keyboard shortcuts,
and on iPad describes an interaction model the platform does not have. Its most
important entry, `←/→`, is the one that does not exist there at all.

For comparison, the redesigned comparison screen's band costs 156pt in portrait
and delivers a scrubber, six transport controls, two segmented pickers, a time
readout and the anchor. The viewer spends nearly the same vertical budget on a
fraction of the capability, and **there is no timeline anywhere in the viewer on
either platform** — `ViewerModel` publishes neither current time nor duration.

## Design

### One transport, one scrubber, one row

```
  ────────────────●──────────────────────────────────────────
  ◀◀   ◀   ▶‖   ▶   ▶▶   ⏱        0:12.4 / 0:31.0      ⏮  ⏭
  -5  -1       +1  +5  slow                             clip
```

- **Scrubber** on top, showing position in the current clip. New.
- **Transport** is the identical six controls the comparison screen has —
  −5s, −1s, play/pause, +1s, +5s, slow motion — with the same icons, the same
  meanings and the same 44pt targets. One idiom across both screens.
  **Slow motion is a one-shot action, not a toggle and not a hold**, matching
  the comparison screen exactly: pressing it starts playback at 0.25×, and the
  way back to full rate is play/pause, which pauses and then resumes at 1×. It
  is deliberately not rendered as a toggle, because the rate lives on
  `AVPlayer`, which publishes nothing — a toggle drawn from it would show stale
  state whenever the periodic time observer is idle, which is exactly while
  paused. The label is the action (`Play at quarter speed`), not a state. The
  same icon must not mean one thing on one screen and another elsewhere.
- **Clip stepping** (`⏮ ⏭`, today's Previous/Next) sits at the far right of the
  same row. It is navigation *between* clips rather than transport *within* one,
  so it earns visual separation but not a row of its own.

### Deleted outright

- **The athlete name and clip description rows.** They become a caption over
  the bottom-left of the letterbox, exactly as the comparison screen's filename
  does. Measured there at 29.0pt minimum height — the same as a plain `Text` —
  and therefore free, because the letterbox area already exists.
- **The hint line.** macOS restores the words as hover tooltips; iPadOS needs
  none once the controls are visible rather than described.

### Status

`model.status` moves into the same capsule chip the comparison screen uses:
overlaid top-trailing on the video, `allowsHitTesting(false)`, width-capped.

Its copy must also change. The current status says things like
`Paused · Space to play`, which is false on a platform with no space bar. Status
text in this screen states what happened, not which key to press.

### Layout

The comparison screen's bar needs 880.5pt largely because of two segmented
pickers worth roughly 320pt. The viewer has neither — no layout mode, no target
selector. What remains is six transport controls, a time readout and two
clip-step buttons, on the order of 650pt.

**Expectation, to be measured, not a result:** the row fits one line at 834pt
and at 744pt, making the band

```
44pt scrubber + 60pt row = ~104pt at every iPad width
```

That is smaller than today's 125–135pt *and* smaller than the comparison
screen's 156pt portrait band, while adding a timeline.

If measurement contradicts this, the bar wraps exactly as the comparison
screen's does and the band becomes ~156pt. The implementation plan must record
the measured figure rather than this estimate, and must state plainly if the
one-row claim fails.

### Input model

Reaching the seek does **not** require the unexecuted phase 4 input work.

The comparison screen's control bar calls `model.seek(...)` directly and never
goes through `PlaybackIntent`. The viewer's transport row does the same.
Therefore:

- **`InertInputSource` is not modified.** It stays inert.
- **Phase 4 remains unexecuted and optional.** It reduces to hardware-keyboard
  support and touch gestures on iPad — genuine improvements, but no longer the
  gate on basic capability.
- **macOS keeps `AppKitInputSource` unchanged**, including the ←/→ tap,
  double-tap and hold-to-shuttle vocabulary, which is precise and worth keeping.

**One touch gesture is added:** tap the video to play/pause. It is the single
universal video gesture, and without it the video is inert to touch. Swipe-for-
clip and edge-hold-to-shuttle are deliberately **not** added — the transport row
already carries those actions, and adding gestures for them would recreate the
two-ways-to-do-one-thing duplication this project's comparison redesign existed
to collapse.

**A deliberate non-hazard, recorded so it is not "fixed" later.** On macOS, the
arrow keys and the new transport buttons both reach the same seek. That is two
input routes to one action, which is correct and normal. It is *not* the
comparison screen's ⌘Return defect, which was two **different** actions
(`setSyncPoints()` and `returnToSyncPoints()`) claiming one shortcut with no
defined winner. A future reviewer seeing duplication here should leave it alone.

## Model change

`ViewerModel` gains the machinery `ComparisonModel` already has and proved:

- a periodic time observer publishing `currentTime` and `duration`, which is the
  scrubber's entire reason to exist;
- a narrow public seek entry point — `seek(seconds:)` is currently private at
  `ViewerModel.swift:348` — plus `scrub(to:)`;
- slow-motion rate control.

`togglePlayback()` and `changeVideo(by:)` are already public and unchanged.

**The existing clamp is correct and must not be "fixed" by analogy.** The
comparison screen had a silent misalignment because `returnToSyncPoints()`
seeked two players with raw `AVPlayer.seek`, which clamps each independently and
destroys the offset between them. A single clip has no such offset, and
`ViewerModel.seek` already clamps to duration. The failure class does not exist
here.

## Structure

| File | Responsibility |
|---|---|
| `ViewerPane` | video, athlete/clip caption, tap-to-play |
| `ViewerControlBar` | transport, time, clip stepping |
| `ContentView` | composition, plus the untouched sidebar |
| `TransportControls` | the six transport buttons; shared with the comparison screen |
| `TimelineScrubber` | position and duration; shared with the comparison screen |

All live in `Sources/SkiVideoViewer/Shared/`. None may import AppKit or UIKit —
`SinglePlayerView` remains the only file there that does.

### Shared primitives

The six transport buttons are identical to the comparison screen's. Duplicating
them duplicates the icons, accessibility labels, tooltips, 44pt frames **and**
the `contentShape` placement rules, which took three review rounds and
dispatched `NSEvent` clicks to establish. Duplicated, they will drift.

Extract **`TransportControls`** and **`TimelineScrubber`** as shared views taking
plain values and closures, and migrate the comparison screen onto them. This
makes the comparison code smaller as well.

The cost is modifying freshly-reviewed shipped code. The mitigation is that the
comparison screen's layout is pinned by measurement tests (880.5pt wrap
threshold, 60pt and 112pt heights) and by 7 iPad UI tests, so a regression
surfaces immediately.

## Testing

- **Model tests** for time publishing and seek bounds, **against real
  `AVAssetWriter`-generated media, not the zero-byte fixtures.** Those fixtures
  produce NaN durations, which is precisely why the comparison screen's clamping
  defect survived four task reviews and a task that recorded it as "reasoned to,
  never observed" — the bounds branch never executed.
- **Layout measurement tests** using the `NSHostingView`/`sizeThatFits` harness
  that now exists, pinning the one-row claim in both directions.
- **iPad UI tests** at 834pt and 744pt. Every UI test must dismiss the launch
  document picker first: the 11-inch presents it as a popover whose
  `PopoverDismissRegion` swallows taps while being invisible to the
  accessibility tree, and the mini presents it as a sheet with no such region at
  all. `CompareOnIPadUITests` has the helper handling both.
- **Screenshots** at 834pt and 744pt.

## Platform differences

One layout, two input methods. 44pt targets for controls this project builds;
system controls at platform-standard size.

- **macOS adds** hover tooltips restoring the words the icons replaced, and
  keeps every existing key equivalent.
- **iPadOS adds** tap-to-play on the video.

**This deliberately changes macOS**, as the comparison redesign did. Since macOS
cannot be driven from the implementation environment, a human must exercise the
Mac viewer before this lands: arrow-key seeking, tooltips, ⌘F, clip stepping.

## Risks

1. **macOS is unverifiable from the implementation environment.** A human check
   is required, not optional.
2. **The status chip will now be on two screens** and has still never been seen
   over bright footage. Snow is high-key and low-contrast against a translucent
   grey capsule — the worst input for it. If it reads badly, it reads badly
   twice.
3. **The one-row layout is an estimate, not a measurement.** If it wraps, the
   band is ~156pt and the space claim weakens to roughly parity with today,
   though the capability gain stands.

## Out of scope

- **The athlete sidebar**, its search field and ⌘F. Unchanged.
- **Phase 4 input work** — hardware keyboard and touch gestures beyond
  tap-to-play on iPad.
- **The comparison screen**, except for migrating it onto the shared
  `TransportControls` and `TimelineScrubber`.

## Coordination

The `landmark-align` worktree touches none of `ContentView`, `ViewerModel`,
`NativePlayerView` or `SinglePlayerView` — verified against its 17-file,
6,511-insertion diff. Unlike the comparison redesign, this work has no collision
with it and no merge-order decision to make.
