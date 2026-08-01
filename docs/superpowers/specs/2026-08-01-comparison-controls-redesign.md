# Comparison Controls Redesign — Touch and Mac

**Date:** 2026-08-01
**Status:** Approved design, not yet implemented
**Applies to:** the comparison screen on both macOS and iPadOS

## Problem

The comparison screen spends most of its space on controls. Measured from
screenshots of the shipping build:

- **Side-by-side:** seven rows of chrome — layout picker, two "Choose File"
  header rows, two scrubber-plus-transport rows, a Close/Independent/Sync row, a
  six-button "together" row, and a hint line.
- **Overlay:** nine rows, and worse — the two per-side header rows float *above*
  the composited image in white bands, so the video is a strip getting roughly a
  quarter of the height.

Eighteen transport buttons are on screen at once, all of them text.

## The core redundancy

`ComparisonModel` already routes per-side calls to synced behaviour when
`isSynced` is true. `toggleIndividual(_:)`, `playIndividual(_:rate:)`,
`seek(_:by:)` and `scrub(_:to:)` each check `isSynced` first and delegate to
`playSynced` / `pauseBoth` / `seekSynced`.

So the per-side transports and the separate "together" transport are **the same
controls twice**. The model unifies them by mode; the UI shows both anyway.

## Design

### One transport plus a target selector

```
  [ Both | Left | Right ]     <<  <  ▶  >  >>   ⏱     0:12.4 / 0:31.0
   target                     transport         slow   time
```

- **Target** decides who receives the transport actions. `Left`/`Right` call
  `seek(_:by:)` and `toggleIndividual(_:)`; `Both` calls `seekSynced`,
  `playSynced`, `pauseBoth`.
- **`Both` is offered only once sync points are set.** Verified in the model:
  `playSynced(rate:)` and `seekSynced(by:)` both open with
  `guard isSynced else { status = "Set the sync points first."; return }`. So
  today's six-button "together" row is **entirely inert during the aligning
  phase** — a permanent row that can only produce a nag message, in the state
  the user spends most of their time in. The selector shows `Left`/`Right`
  while aligning and gains `Both` on sync, so no control is ever present
  without being usable.
- **Transport** is five actions — −5s, −1s, play/pause, +1s, +5s — plus a
  slow-motion toggle. Identical regardless of target.
- **Scrubber** sits above, showing the targeted clip, or the common timeline
  when `Both`.

One row of about nine controls replaces three rows of eighteen, and it reads the
same on touch and Mac.

**Why this survives auto-sync.** Automatic temporal detection is planned. When
it lands, `Both` becomes the near-permanent default and `Left`/`Right` become a
correction affordance. Nothing is rebuilt — the selector simply stops being
touched. Designing per-side control as a *mode of one transport* rather than as
its own UI is what makes that demotion free.

### Icons, not text

"Play / Pause", "Slow Together 0.25×" and "Back to Sync Points" as text buttons
are why the bar is rows deep. SF Symbols at 44pt hit targets fit the whole set
on one line and are legible on both platforms. Mac restores the words as hover
tooltips.

### Layout

**Side-by-side, aligning:**

```
+----------------------------+----------------------------+
|                            |                            |
|         LEFT VIDEO         |        RIGHT VIDEO         |
|                            |                            |
| Idun_run2.mp4              | Nora_run1.mp4              |
+----------------------------+----------------------------+
| =========================O=============================  |
| [SbS|Ovl] [Both|L|R]  << < ▶ > >> ⏱  0:12.4/0:31.0   ⚓  |
+---------------------------------------------------------+
```

**Overlay:**

```
+---------------------------------------------------------+
|                                                         |
|                   OVERLAID VIDEO                        |
|                    (full width)                         |
|                                                         |
+---------------------------------------------------------+
| Left ======O====== Right   [Blend|Difference]           |
| =========================O=============================  |
| [SbS|Ovl] [Both|L|R]  << < ▶ > >> ⏱  0:12.4/0:31.0   ⚓  |
+---------------------------------------------------------+
```

### Deleted outright

- **The two "Choose File" header rows.** Setup UI holding permanent space. An
  empty pane shows a centred *Choose Clip* button inside the pane; a loaded pane
  shows its filename small over the letterbox, costing zero layout height. In
  overlay mode they disappear entirely — there are no panes.
- **The "together" transport row.** Subsumed by the target selector.
- **The hint line.** Discoverability moves to tooltips and key equivalents.
- **The standalone layout picker row.** It moves into the control bar as the
  leftmost segmented control, costing no row of its own.
- **"Close" on macOS.** The window already has a close button. iPad keeps a
  dismiss chip over the video's top-left, because a full-screen cover has no
  chrome of its own.

Net: side-by-side goes from seven chrome rows to two; overlay from nine to
three, with the video no longer sandwiched between control bands.

### States

The bar's contents do not change between states — only its defaults and one
button's meaning.

| | Aligning (`isSynced == false`) | Synced |
|---|---|---|
| Target offers | `Left`, `Right` | `Both`, `Left`, `Right` |
| Target defaults to | `Left`, then the last-touched side | `Both` |
| Scrubber shows | the targeted clip | the common timeline |
| ⚓ does | Set sync points | Return to sync points |
| ⚓ secondary action | — | Clear sync |

The anchor button absorbs three of today's text buttons. Secondary action is
long-press on touch, right-click on Mac.

### Narrow widths

An 11-inch iPad in portrait is 834pt and the bar will not fit on one line. It
**wraps to two rows** rather than shrinking targets below 44pt. Touch target
size wins over row count. An iPad mini is 744pt and must also be checked —
nothing narrower has been tested at any point in this project.

### Platform differences

One layout, two input methods. 44pt targets everywhere: a mouse can hit small
things but does not suffer from large ones, and one geometry is far cheaper to
maintain than two.

- **macOS adds** hover tooltips restoring the words the icons replaced, and
  keeps the existing key equivalents (⌘Return sets sync points, space, arrows).
- **iPadOS adds** nothing, because it needs nothing extra.

**This deliberately changes macOS.** Every previous phase carried "macOS
behaviour must not change" as a hard constraint. That constraint is explicitly
**lifted for the comparison screen only**. Since macOS cannot be driven from the
implementation environment, a human must exercise the Mac comparison window
before this lands.

## Structure

`ComparisonView` is 290 lines holding seven sub-views, which is how the chrome
accreted without anyone noticing. Split into files that each do one thing:

| File | Responsibility |
|---|---|
| `ComparisonPane` | one video, its filename, its empty-state Choose button |
| `ComparisonScrubber` | the timeline for whatever is targeted |
| `ComparisonControlBar` | target selector, transport, time, anchor |
| `OverlayBlendBar` | blend slider and mode; overlay only |
| `ComparisonView` | composition only, ~60 lines |

All five live in `Sources/SkiVideoViewer/Shared/`. None may import AppKit or
UIKit — `SinglePlayerView` remains the only file there that does.

## Model change

One addition:

```swift
public enum ComparisonTarget: String, CaseIterable, Identifiable, Sendable {
    case both, left, right
    public var id: String { rawValue }
}

@Published public var target: ComparisonTarget = .both
```

Everything else already exists. The control bar routes to `seek(_:by:)`,
`toggleIndividual(_:)`, `seekSynced(by:)`, `playSynced(rate:)` and `pauseBoth()`
by target. No existing model method changes signature or behaviour.

`target` is genuinely independent state, not derivable from `isSynced`: a user
may nudge one side while synced, which is exactly the correction affordance
auto-sync will leave behind.

## Testing

- The 14 existing `ComparisonModelTests` must keep passing unchanged.
- **New model tests:** target routing — with `target == .left`, a seek moves the
  left player and not the right; with `.both` while synced, both move. Default
  target is `.both` when synced and follows the last-touched side while
  aligning.
- **New UI tests** in the existing iPad UI-test target: the target selector
  switches, the transport acts on the selected clip, and the anchor button's
  label changes with `isSynced`.
- **Layout regression:** a screenshot at 834pt portrait confirming the bar wraps
  to two rows with no clipping, and one at 744pt (iPad mini).

Every UI test must dismiss the launch document picker first — its
`PopoverDismissRegion` swallows taps while being invisible to the accessibility
tree, so a test can find a button, be told it is hittable, tap it cleanly, and
have nothing happen. `CompareOnIPadUITests` has the helper.

## Coordination risk

The `landmark-align` worktree (`/Users/ulfnielsen/Ski/ski-landmark-align`) has
diverged substantially — roughly 79 files and 6.6k insertions against a
different `SkiVideoCore`, adding Vision-based **spatial** registration with
per-frame warping, plus an overlay clip export. It restructures the same
comparison code this redesign touches, and it removes the current overlay's
stated limitation ("there is deliberately no spatial alignment").

**Decide merge order before either lands.** Reconciling two independent
restructurings of the comparison screen after the fact is materially harder than
sequencing them. This spec assumes the redesign lands first and that
landmark-align rebases onto it; if that is wrong, this spec needs revisiting
rather than merging.

## Out of scope

Automatic temporal sync (planned, not designed here), spatial registration (the
`landmark-align` worktree), and the viewer screen's controls — this spec covers
the comparison screen only.
