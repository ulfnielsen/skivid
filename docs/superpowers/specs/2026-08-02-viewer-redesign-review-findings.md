# Viewer Redesign — Whole-Branch Review Findings

**Date:** 2026-08-02
**Reviewed:** `05e8b67..09f9aa2`, merged as `b648c3c`
**Status:** notes only — nothing fixed, because parallel work is in flight

Every finding below was verified by measurement or by a mutation run against a
clean 148-test baseline, not by reading. Ordered by what to do first.

---

## Critical

### C1. The status chip is illegible over snow — on the comparison screen

`Shared/ComparisonStatusChip.swift:43` vs `Shared/ViewerPane.swift:54-66`

The spec said the viewer's status "moves into the same capsule chip the
comparison screen uses". It did not. `ViewerPane` re-implements it inline with a
different background, `lineLimit`, and padding. Measured headlessly
(`NSHostingView` + `cacheDisplay`, luminance histogram over the rendered bitmap):

| Style | over snow (RGB 240) | over black |
|---|---|---|
| `.thinMaterial` — comparison | capsule 243, text 253 → **1.09 : 1** | 3.68 : 1 |
| `.black.opacity(0.45)` — viewer | capsule 131, text 237 → **3.21 : 1** | fine |

Two checks make this trustworthy: the material genuinely adapts headlessly
(118 → 185 → 243 across black, mid and snow backgrounds, so it is not a flat
fallback), and the viewer's 3.21:1 reproduces Task 4's on-device 3.17:1.

**Failure:** a coach aligns two snow runs, and every sentence the comparison
redesign routes through the chip — "Set the sync points first.", "Choose both
videos before setting sync points.", "Synchronized from L … and R …" — renders
at 1.09:1 and is simply not there. Those rows were deleted; the chip is their
only home.

The earlier verdict "the chip is fine at 3.17:1" measured the viewer's **private
fork**, not the shared component. It reads badly exactly once, on the screen
nobody checked.

**Change:** promote one `StatusChip` (rename `ComparisonStatusChip`), give it
`.black.opacity(0.45)`, and have `ViewerPane` use it. Reconcile `lineLimit`
deliberately — `ViewerModel.status` produces "Could not connect to Google
Drive", which the viewer truncates and the comparison screen would wrap.

### C2. Two of the six viewer transport actions have no behavioural coverage

`SkiVideoCore/ViewerModel.swift:328-331`

Mutating `.back5` to `seek(seconds: -1)` **and** `.forward1` to
`seek(seconds: 5)` at the same time leaves 148/148 green. `back1` is covered only
by `testBack1DoesNotGoNegative`, which starts at 0 and asserts 0 — so −5
satisfies it identically. Neither magnitude is pinned on either platform; the
iPad tests only assert those buttons exist.

**Failure:** "Back 5 seconds" moves 1s and "Forward 1 second" jumps 5s, while
every icon, tooltip and accessibility label still says the right thing.

**Change:** `scrub(to: 10)` on the 20s fixture, then assert the four seek actions
land at 5 / 9 / 11 / 15.

---

## Important

### I3. The layout tests assert a claim that was already disproved

`Tests/SkiVideoViewerTests/ViewerLayoutMeasurementTests.swift:21, 97, 133, 144`

- Line 21 cites `ViewerOnIPadUITests.testTheControlBarFitsOneRowInPortrait`,
  which **does not exist**. The real test is
  `testTheControlBarWrapsInPortraitBecauseTheSidebarKeeps270Points`, asserting
  the opposite.
- The two measurement tests use 834/744pt — the *window* widths, which
  `NavigationSplitView` never offers the bar in portrait (564/474 measured).
- Line 144 asserts `band < 130` with the message "or the redesign cost height
  rather than saving it". In the shipping default configuration the band is
  156pt, so that message describes what actually happened.

These were written *after* the 156pt measurement. **Failure:** the next engineer
reads a green suite and concludes portrait beats the old band by 26pt. It loses
by 26pt.

**Change:** rename both tests to say "when the bar is offered them", replace the
`< 130` assertion with an explicit pair pinning 104pt at ≥557pt and 156pt at
564pt and 474pt, and fix the cross-reference.

### I4. The spec still carries the disproved headline

`docs/superpowers/specs/2026-08-01-viewer-screen-redesign-design.md:103-116, 234`

Still claims ~104pt at every iPad width and "smaller than today's 125–135pt".
Line 116 explicitly required stating plainly if the one-row claim failed. It
failed, it was stated in the task report, and nobody wrote it back.

**Change:** amend §Layout and Risk 3 with 104pt landscape / 156pt portrait and
the 270pt-sidebar cause.

### I5. `TimelineScrubber`'s entire reason to exist is untested

`Shared/TimelineScrubber.swift:17-19, 45`

Replacing `displayedTime` with plain `time` — deleting the mid-drag state the
doc comment calls the view's whole purpose — leaves 148/148 green. Deleting the
release re-seek also survives. Both `@State` properties are unverified, on the
one view **both** screens share.

**Failure:** the thumb fights the finger during a drag — the exact bug the
comment says the state prevents — on both screens, with nothing to catch it.

**Change:** drive `onEditingChanged` through the real `NSSlider` in
`SharedControlsWiringTests` at drag-start and drag-end, asserting `onScrub`
fires on release.

### I6. Nothing asserts the time readout

`Shared/ViewerControlBar.swift:45`

Swapping `currentTime` and `duration` survives the whole suite. The layout tests
use an empty model where both are 0, so the swap is invisible there by design,
and no iPad test reads the label. **Failure:** the bar reads
"00:31.0 / 00:12.4". **Change:** one iPad assertion against the known-length
fixture.

### I7. The seek buttons report nothing; the arrow keys do

`ViewerModel.swift:328-331` vs `:466` vs `ComparisonModel.swift:395`

Three reporting behaviours behind one shared `TransportControls`: the viewer's
seek actions set no status, `performArrowTap` sets "Forward 1 seconds",
`ComparisonModel.nudge` sets "Left nudged +1 seconds". On the macOS viewer the
← key and the −1s button — which the spec blessed as "two input routes to one
action, which is correct and normal" — visibly differ: one moves the chip, the
other does not.

**Change:** give the viewer's seek cases a status matching `performArrowTap`'s
wording, and fix the "1 seconds" pluralisation while there.

### I8. `makeRealVideoFile` is duplicated three times, twice inside one target

`Tests/SkiVideoCoreTests/RealVideoFixture.swift:16`,
`Tests/SkiVideoViewerTests/SharedControlsWiringTests.swift:349`,
`Tests/SkiVideoViewerTests/ViewerControlsWiringTests.swift:464`

The recorded justification — SPM test targets cannot depend on one another —
covers the cross-target copy but not the second copy inside `SkiVideoViewerTests`.
Those two files are in the same target and can share one `internal` helper
today, no package change, ~55 duplicated lines removed.

---

## Minor

- **M1. macOS has no letterbox, so the caption sits on moving video.**
  `macOS/NativePlayerView.swift:11` uses `.resizeAspectFill`; iOS uses
  `.resizeAspect`. `ViewerPane.swift:6-9` justifies the caption's zero cost with
  "the letterbox area already exists" — true on iPad, false on macOS. All
  screenshots so far are iPad. Whatever scrim fixes the 1.15:1 caption must be
  judged on macOS too, where the case is worse.
- **M2. Three copies of the same 44pt icon-button idiom** —
  `TransportControls.swift:29-42`, `ViewerControlBar.swift:59-71`,
  `ComparisonControlBar.swift:146-163`. `TransportControls` was extracted
  precisely because duplicates drift, and then two more were written. Extract a
  `BarButton`.
- **M3. Five of seven assertions in
  `ViewerOnIPadUITests.testTheStatusChipIsAConstantWidthAndClearsTheControlsBelowIt:424-433`
  are structurally satisfied.** Chip and caption are overlays on opposite
  corners of the same pane; the bar buttons are in a sibling below it. Their
  frames cannot intersect for any pane taller than ~60pt. Only the width check
  and `window.contains` do work.
- **M4. Stale doc comment.** `ViewerModel.swift:22-23` says `videoIndex` is
  "Internal: no view reads it". The caption now renders `clipDescription`,
  computed from it, and an iPad test reads it back.
- **M5. Two enablement predicates in one band, unexplained.**
  `ViewerControlBar.swift:39,70` gate on `currentPlaybackURL != nil`; the
  scrubber beside them gates on `duration <= 0`. Between clip selection and
  duration arrival — "a visible moment for a remote Drive item" — the transport
  is live while the timeline is dead. Consistent with the comparison screen, but
  neither states the intent.
- **M6. Scrubber identifier asymmetry.** The viewer's scrubber has
  `accessibilityIdentifier("Viewer timeline")`; `ComparisonScrubber` has none and
  no compare UI test locates its slider. Either both or neither.

---

## Cleared

The `Timecode` extraction is covered (mutating its format string kills four
tests). `ComparisonScrubber`'s accessibility label and value survived the
extraction byte-identically. `deinit`/`timeObserver` is handled.
`Sources/SkiVideoViewer/Shared/` purity holds, with `SinglePlayerView.swift` the
sole AppKit/UIKit importer.

## Still open, outside this review

- The iPad portrait band is 156pt against the ~130pt it replaced. Fixing it means
  defaulting the sidebar collapsed at narrow widths — the option deliberately not
  taken when this was scoped.
- The macOS viewer and the macOS comparison window both still need a human check.
- `landmark-align` and the in-flight subject-sync work both target the comparison
  screen. No merge order has been decided.
