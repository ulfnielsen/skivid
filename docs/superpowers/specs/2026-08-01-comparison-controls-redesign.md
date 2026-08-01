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
  **momentary** slow-motion action that starts playback at 0.25×. Identical
  regardless of target. It is not a toggle: `applyTransport(.slow)` is
  fire-and-play, the rate it sets lives on `AVPlayer` and the model publishes
  nothing to render a toggle's state from, so an on/off icon would go stale at
  exactly the moment playback stops. The route back to 1× is play/pause — it
  pauses, and the next play starts at full rate.
- **Scrubber** sits above, showing the targeted clip, or the common timeline
  when `Both`.

One row of about nine controls replaces three rows of eighteen, and it reads the
same on touch and Mac.

**Why this survives auto-sync.** Automatic temporal detection is planned. When
it lands, `Both` becomes the near-permanent default and `Left`/`Right` become a
correction affordance. Nothing is rebuilt — the selector simply stops being
touched. Designing per-side control as a *mode of one transport* rather than as
its own UI is what makes that demotion free.

### Per-side control while synced: the nudge

While synced, targeting `Left` or `Right` does not hand that clip a plain,
independent seek — that would let a −5s tap silently drift the pair out of
alignment while the status bar still claimed "Synchronized". Instead, the four
seek actions (`back5`, `back1`, `forward1`, `forward5`) become a **nudge**: the
targeted clip moves, and *its own sync point moves with it by the same amount*,
so the pair stays locked, at the corrected offset. The other clip does not
move. `playPause` and `slow` stay paired regardless of target — playing or
slowing one side alone would desync exactly what the user just aligned — so
they always resolve to the synced pair while `isSynced` is true, the same as
`Both` would.

This is what makes the correction affordance real rather than aspirational:
`scrub` derives its offset from the two sync points, so a nudge's correction
propagates to every subsequent synced scrub for free, and
`returnToSyncPoints()` returns to the corrected alignment rather than the one
being corrected away from.

**The subtlety a reimplementation is likely to get wrong.** The sync point
shifts by the distance *actually travelled*, not the distance requested. A
locked pair satisfies `L_cur − L_sync == R_cur − R_sync`. If a nudge clamps —
at 0, or at the clip's end — and the sync point is shifted by the requested
amount instead of the travelled one, that invariant breaks by exactly
`requested − travelled`: the live playhead and the sync-point-derived offset
disagree, and the next synced scrub jumps by the difference. Verified by
mutation — shifting by the requested seconds instead of the extracted
travelled distance is caught by a dedicated test.

**A known bug the nudge introduces.** Before `nudge`, sync points only ever
came from `currentTime()`, which is always inside the clip's bounds. `nudge`
is unbounded in the direction that matters here — a nudge near a clip boundary
can push a sync point *outside* the clip. Measured: sync points at 0, the pair
moved to 30, then `back5` on `Left` gives `leftSyncPoint == -5.0`.
`returnToSyncPoints()` seeks with raw `AVPlayer.seek`, bypassing the model's
own clamping helper, so on real (non-empty) media that seek would clamp to 0
and land the pair five seconds out of alignment — the exact failure `nudge`
exists to prevent. **The misaligned return has not itself been observed**,
only reasoned to: the test fixtures are zero-byte files that accept a negative
seek verbatim, so what is measured is the negative sync point, not the clamped
return landing wrong. Say that plainly rather than implying it was seen. The
fix belongs with whoever owns `returnToSyncPoints`: either clamp the sync
point on write inside `nudge` and refuse the excess travel, or route the
return seek through the same clamping helper `seek(_:to:)` already uses.

### Icons, not text

"Play / Pause", "Slow Together 0.25×" and "Back to Sync Points" as text buttons
are why the bar is rows deep. SF Symbols at 44pt hit targets fit the whole set
on one line and are legible on both platforms — these are our own `Button`s, so
44pt is genuinely achievable here; see "Platform differences" for the system
controls it is not. Mac restores the words as hover tooltips.

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
| Left/Right seek actions | plain per-side seek | **nudge** — the clip moves and its own sync point moves with it; the other clip is untouched |
| Left/Right play/slow | plays/slows that clip alone | stays paired — resolves to the synced pair regardless of target |
| ⚓ does | Set sync points | Return to sync points |
| ⚓ secondary action | — | Clear sync |

The anchor button absorbs three of today's text buttons. Secondary action is
long-press on touch, right-click on Mac.

### Narrow widths

An 11-inch iPad in portrait is 834pt and the bar will not fit on one line. It
**wraps to two rows** rather than shrinking targets. Touch target size wins over
row count. An iPad mini is 744pt and must also be checked — nothing narrower has
been tested at any point in this project.

Measured in Task 2, via `ViewThatFits` hosted headlessly at a sweep of widths:

- **Wrap threshold 880.5pt**, identical whether aligning or synced. 881pt gives
  one row, 880pt gives two. Both 834pt and 744pt wrap, as intended.
- **One row is 60pt tall; two rows are 112pt.** (An earlier plan said 92pt —
  that predated the 44pt row frames.)
- The two-row layout holds its 112pt down to about 460pt, far below anything
  this project targets.
- macOS keeps one row, because `ComparisonView` pins `minWidth: 1000` there.

The threshold is identical in both sync states only because the target picker
has a fixed width rather than one that varies with its segment count. With a
variable width the bar's ideal width was 830.5pt aligning and 880.5pt synced —
straddling 834pt, so tapping the anchor on an 11-inch iPad reflowed one row into
two and resized the video mid-alignment.

### Platform differences

One layout, two input methods. **44pt targets for the controls we build;
system controls at their platform-standard size.** A mouse can hit small things
but does not suffer from large ones, and one geometry is far cheaper to
maintain than two.

The rule used to read "44pt targets everywhere". It was amended in Task 2 after
the exemption turned out to be unavoidable *and* correct:

| Control | Kind | Hit target |
|---|---|---|
| Six transport buttons, sync anchor | our `Button` + `contentShape` | **44×44**, as specified |
| Layout picker, target picker | `Picker(.segmented)` | 24pt macOS, **32pt iPadOS** |
| Scrubber | `Slider` | 16pt macOS |

**Why the exemption is deliberate, not a concession.** 32pt is what iPadOS uses
for segmented controls throughout; matching the platform is the right answer for
the mode switch, not a compromise on it. And it is not reachable from SwiftUI
anyway: measured, a `frame(height: 44)` around a segmented picker or a slider
*centres* the control without growing it — identical drawn extent framed and
unframed — and `contentShape(Rectangle())` on the framed parent does not extend
the hit region either. Synthetic clicks selected a segment over the same ~24pt
band with `contentShape`, without it, and with no frame at all; a parent's
content shape defines that view's own hit region and cannot route a hit into a
child control's segments. Its only measurable effect was to *swallow* clicks in
the surrounding band, so it is deliberately absent.

The 44pt frames remain, because reserving the row is real and gives the two-row
layout its rhythm. They just do not enlarge the control, and no comment or spec
line should claim they do.

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

```swift
public enum ComparisonTarget: String, CaseIterable, Identifiable, Sendable {
    case both, left, right
    public var id: String { rawValue }
}

public enum TransportAction: String, CaseIterable, Identifiable, Sendable {
    case back5, back1, playPause, forward1, forward5, slow
    public var id: String { rawValue }
}

@Published public var target: ComparisonTarget = .left {
    didSet {
        if !availableTargets.contains(target) { target = lastTouchedTarget }
    }
}

public func applyTransport(_ action: TransportAction)
```

`applyTransport` is the single entry point the control bar drives, and the
keyboard shortcuts route through it too so a key and its on-screen button
cannot disagree. It switches on `target`: for `.both` it calls `seekSynced`,
`playSynced`/`pauseBoth`; for `.left`/`.right` the four seek actions go
through the new `nudge(_:by:)` rather than plain `seek(_:by:)` — see "Per-side
control while synced" above — and `playPause`/`slow` go to
`toggleIndividual`/`playIndividual`, which already delegated to the synced
pair when `isSynced`, so `applyTransport` does not have to test for pairing
itself.

`target` is genuinely independent state, not derivable from `isSynced`: a user
may target `Left` while synced, in which case the seek actions correct that
side against the other rather than moving the pair.

No existing model method's *signature* changes. `nudge(_:by:)` is new;
`applyTransport(_:)` is new; `handle(_:)` (the keyboard router) now routes
through `applyTransport` instead of calling `playSynced`/`seekSynced`
directly, which is a deliberate behaviour change — while aligning, Space now
plays the targeted clip instead of answering "Set the sync points first."

### The invariant: `target` can never hold a value `availableTargets` refuses

If it did, a segmented picker bound to `target` would render no selection at
all — SwiftUI's behaviour when a bound value isn't among the options it's
given. `target`'s `didSet` self-enforces this rather than relying on every
call site to remember it: `availableTargets` always contains `.left` and
`.right`, so `.both` is the only value that can ever need correcting, and the
landing value, `lastTouchedTarget`, derives from the two-case `ComparisonSide`
and so is structurally incapable of being `.both` itself — there is no
`.both`-to-`.both` loop to worry about. The three places that used to
hand-demote (`removeSync`, `clearSync`, and now the `didSet`) all funnel
through the same `lastTouchedTarget`.

### The last-touched side (fixed in Task 2)

`lastTouchedSide` — what a `.both`-losing demotion falls back to — was
originally written in exactly two places: `applyTransport`'s per-side branch,
and `load(_:side:)`. Every other per-side entry point left it stale, and the
control bar made that reachable: dragging the scrubber is the only route to an
absolute seek, since `TransportAction` has no such case. Measured symptom —
select Right, align it by dragging, sync, clear sync, and land back on **Left**.

Fixed by moving the rule into the model rather than asking each new control to
remember it. `noteTouched(_:)` is called by `scrub`, `nudge`, `seek(_:by:)`,
`seek(_:to:)`, `toggleIndividual` and `playIndividual`, and `target`'s own
`didSet` records a side the moment the picker selects one — choosing `Right` is
the clearest statement of preference there is, and on its own it used to record
nothing.

`noteTouched` refuses while `target == .both`, which is the part a naive fix
gets wrong. `lastTouchedSide` answers one question — which side a demotion
lands on — so it must follow only calls that name a side. While targeting
`Both` the scrubber shows the common timeline and drags it through
`scrub(.left, to:)`, because there is no paired overload; recording that as a
touch on Left would reintroduce the same bug for a user who had chosen Right.
`applyTransport` already behaved this way (its `.both` branch never wrote it);
the direct entry points now agree. `load(_:side:)` stays unconditional:
dropping a clip into a pane names that side whatever the target is, and it has
to be recorded before `clearSync` demotes off `both`.

## Testing

- The 14 existing `ComparisonModelTests` must keep passing unchanged.
- **New model tests:** target routing — with `target == .left`, a seek moves the
  left player and not the right; with `.both` while synced, both move. Default
  target is `.both` when synced and follows the last-touched side while
  aligning.
- **Nudge semantics** are covered separately, mutation-verified: the sync point
  shifts by the distance actually travelled rather than the distance
  requested; the correction propagates to a subsequent synced `scrub`; and
  `returnToSyncPoints()` lands on the corrected alignment rather than the one
  being corrected away from.
- **One remaining coverage gap.** The *play* direction of the synced pairing
  (targeting a side with `playPause`/`slow` while synced, which resolves to
  `playSynced`) is untested — reaching it calls
  `setRate(_:time:atHostTime:)`, which raises on an unready `AVPlayerItem` and
  would crash the suite rather than fail it, given the zero-byte fixtures used
  elsewhere. The *pause* direction is tested and mutation-verified —
  `toggleIndividual` routes to `pauseBoth` without touching the raising API.
  Closing the play direction needs decodable media; `AVAssetWriter`-generated
  fixtures would work on both platforms without shelling out to `Process`.
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
