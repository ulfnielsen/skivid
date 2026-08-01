# iPadOS Phase 5 — Outcomes and Carried-Forward Items

**Date:** 2026-08-01
**Branch:** `ipados-phase5`, 8 commits off `ipados-phase3` at `c026c42`
**Plan:** `docs/superpowers/plans/2026-08-01-ipados-phase5-compare-on-ipad.md`
**Prior phase:** `docs/superpowers/specs/2026-07-31-ipados-phase3-outcomes.md`

## What landed

**Compare works on iPad.** `SkiVideoViewerApp_iOS` holds a `@StateObject
IOSSecondaryScreenPresenter` publishing an `Identifiable` `ComparisonRequest`,
and presents it with `.fullScreenCover(item:)`. Tapping "Compare Videos…"
opens the comparison screen full-screen; `Close` returns to the viewer.

**The overlay is rewritten in SwiftUI, on both platforms.**
`OverlayPlayerStack` (`Shared/OverlayPlayerStack.swift`) is a `ZStack` of two
`SinglePlayerView`s (`AVPlayerLayer`-backed, one file, `#if os(macOS)` /
`#if os(iOS)` inside it) with `.blendMode(.difference)` / `.opacity()` and a
`.compositingGroup()`. `ComparisonView.swift` moved from `macOS/` back into
`Shared/`, which is where phase 3 said it belonged once a non-AppKit overlay
existed. `macOS/OverlayPlayerView.swift` (the old two-`NSView`,
`CALayer.compositingFilter` implementation) is untouched and unreferenced —
see "The macOS overlay decision" below.

**`SecondaryScreenPresenter.canPresent` split into two flags** —
`canPresentComparison` and `canPresentSorting` — because turning the old
single flag on for iPad would have revealed a Sort button that does nothing
(`SortingSheet` drives `FFmpegMediaPipeline`, which shells out via `Process`,
unavailable on iOS). `IOSSecondaryScreenPresenter` answers
`canPresentComparison == true`, `canPresentSorting == false`, both constants,
as the seam requires (`ContentView` reads them while building `body` and does
not observe the presenter). `NoSecondaryScreenPresenter` was deleted; every
other call site (`MacSecondaryScreenPresenter`, `ContentView`, both test
files) was updated to the two-flag shape.

**An XCUITest target exists**: `SkiVideoViewer-iPadUITests`
(`Tests/SkiVideoViewerUITests/CompareOnIPadUITests.swift`), the first UI-level
gate in the repo. `simctl` has no input injection, so this is the only check
that can actually tap the iPad UI rather than just render or compile it.

**Current gates**, all requiring
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`:

| Command | Result |
|---|---|
| `swift test` | **80 tests, 0 failures** (re-confirmed after this phase's one comment fix) |
| `xcodebuild -scheme SkiVideoCore-iOS -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' test` | **48 tests, 0 failures** (re-confirmed) |
| `xcodebuild -scheme SkiVideoViewer-iPad -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' test` | **4 tests, 0 failures** — the new UI test scheme |
| `xcodebuild -scheme SkiVideoViewer-macOS -destination 'platform=macOS' build` | BUILD SUCCEEDED |
| `xcodebuild -scheme SkiVideoViewer-iPad -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build` | BUILD SUCCEEDED |
| `./build_app.sh` | prints the shipping macOS bundle path |
| `./scripts/ipad-smoke.sh` | `==> RUNNING` plus a screenshot |

Both suites grew, not shrank, from phase 3's 77 macOS / 46 iOS baseline.

## The spike that shaped the phase

`CALayer.compositingFilter` is a **silent no-op on iOS** — measured, not
assumed, on an iPad Pro 11-inch (M5) simulator: a red layer under a cyan one
with `CIDifferenceBlendMode` rendered the overlap as plain cyan instead of
white. Porting macOS's `OverlayPlayerView` (two `AVPlayerLayer`-backed
`NSView`s composited via `compositingFilter`) verbatim to iOS would have
shipped a Difference mode that silently did nothing and looked plausible in
code review — the property compiles, the value is a real `CIFilter` name,
nothing crashes.

SwiftUI `.blendMode(.difference)` does work, including — the part that was
not obvious going in — on `AVPlayerLayer`-backed views: the same clips
rendered white in difference mode and grey under `.opacity(0.5)`. Video
layers are not composited out-of-band from the rest of SwiftUI here. This is
why the overlay became a SwiftUI `ZStack`, not a second AppKit/UIKit view
pair. Task 3 proved the result on iPad by pixel measurement (not eyeball):
difference/1.0 → `(253,255,255)` white; blend/0.5 → `(127,128,128)` grey;
blend/0.0 → `(254,0,0)` red (bottom, left); blend/1.0 → `(1,255,255)` cyan
(top, right); letterbox `(0,0,0)` with no backdrop leak. Nine of the ten
macOS overlay rules were preserved exactly this way.

## The document-picker false-negative trap

The most valuable finding for anyone writing UI tests against this app.
`ViewerModel.start(initialDirectory: nil)` calls `chooseDirectory()` from
`ContentView.onAppear`, so **every launch opens a
`UIDocumentPickerViewController`** before anything else. Its content lives in
`com.apple.DocumentManagerUICore` and never appears in the app's own
accessibility tree — `XCUIApplication(bundleIdentifier:
"com.apple.DocumentManagerUICore")` reports `state == .notRunning`, and a
hierarchy dump of the app shows only the viewer underneath. But the picker's
dismiss region **does** appear, as `app.otherElements["PopoverDismissRegion"]`,
and until it is gone that region swallows every tap.

The failure mode is silent, not an error: a test can find a button (e.g.
`Compare Videos…`), be told `isHittable == true`, tap it cleanly, and have
nothing happen — the tap actually lands on the invisible dismiss region. The
task 4 implementer confirmed this empirically (temporary `NSLog` calls plus
`log show`, removed before commit — `grep -rn SKIPROBE Sources/ Tests/` is
clean) rather than inferring it, and the reviewer reproduced the same trap
independently while re-verifying the branch.

The fix is a `launchPastTheFolderPicker()` helper used by every test: launch,
wait for `PopoverDismissRegion`, tap at normalized `(0.5, 0.97)` (outside the
centred sheet, inside the dismiss region), wait for the region to disappear —
and `XCTFail` if the picker never appeared, so a future change that stops
auto-opening it breaks the tests loudly instead of having them silently pass
for the wrong reason. **Anything that taps this app must dismiss the picker
first and fail loudly if it is absent.**

## VERIFIED BY THE USER, 2026-08-01

**The macOS overlay renders correctly, including Difference mode.** This was the
one rule whose iPad proof did not transfer: `.blendMode(.difference)` was
measured on iOS, and AppKit hosting is a different compositor path. Confirmed by
eye on the Mac. The eyeball list below is therefore **closed**, not outstanding.

Consequence: `Sources/SkiVideoViewer/macOS/OverlayPlayerView.swift` was kept
solely as the one-line revert path (swap `OverlayPlayerStack` back to
`OverlayPlayerView` in `Shared/ComparisonView.swift`). That reason is gone —
the file is unreferenced dead code and can be deleted.

## The macOS overlay decision and its eyeball list

Mid-phase, the controller identified and disclosed its own process error: the
plan gated "unify the overlay on macOS" behind an approval-only Task 4b, but
Task 3's dispatch had already told the implementer to delete the `#if
os(macOS)` conditional selecting the old overlay — which forces macOS onto
the new SwiftUI overlay by the back door, the exact outcome Task 4b existed
to gate.

**The user was asked and ruled: keep the unified SwiftUI overlay on macOS.**
The user will verify it by eye; nothing here can look at a Mac screen.
`macOS/OverlayPlayerView.swift` is deliberately left in the tree, untouched
and unreferenced (confirmed: `git diff` against it is empty, and its only
`grep` hit across `Sources/` and `Tests/` is its own `struct` declaration) —
it is the one-line revert path. To revert, swap the view identifier at
`Shared/ComparisonView.swift:85` back to the AppKit overlay.

The reviewer's prioritised check list for that eyeball pass, most important
first:

1. **Difference mode actually goes white/black, not a normal-looking blend.**
   First because it is the only rule whose iPad proof does not transfer —
   the `compositingFilter` no-op was iOS-specific; nothing here tested
   whether macOS's *old* AppKit path and the *new* SwiftUI path render
   difference mode identically.
2. **Overlay ⇄ Side-by-side round-trips leave no black panes.** This is the
   dropped-and-restored player-detach rule (see "Uncovered paths" below) —
   on macOS specifically, the side-by-side pane is an `AVPlayerView`, a
   different code path than iPad's, and it was never exercised here.
3. **Slider travel in blend mode** — the opacity slider should track visibly
   and smoothly across its full range.
4. **Resize smoothness and playback frame rate** — a generic regression
   check against the previous AppKit overlay's feel.

## Uncovered paths

From the final review, stated plainly rather than implied to work:

- **`IOSSecondaryScreenPresenter` has zero unit coverage.** No test target
  compiles `Sources/SkiVideoViewer/iOS` — `project.yml` has exactly three
  targets touching that tree: `SkiVideoViewer-iPad` (the app), and the new
  `SkiVideoViewer-iPadUITests` (which drives the app black-box, not the type
  directly). There is no `SkiVideoViewerTests`-equivalent for iOS sources.
- **`OverlayPlayerStack` and `SinglePlayerView` have no tests on either
  platform.** Their correctness rests on the pixel measurements taken once
  during task 3 and on the UI tests' screenshots, not on an XCTest that
  would fail if either regressed.
- **Compare has never run with real clips loaded on iPad.** The UI tests
  open Compare from an empty library, so both panes are black in every
  captured screenshot. Playback, sync points, and the difference blend
  against actual video are unexercised on iPad — the phase 3 clip pipeline
  covers the main viewer, not this screen.
- **`Choose File…` from inside the comparison cover is unexercised.** It
  presents a second `UIDocumentPickerViewController`, this time from a view
  already inside a `.fullScreenCover`. Given what the *launch* picker did to
  the first version of the UI tests, this nested presentation is the most
  likely place for a similar conflict to hide, and nothing here has checked
  it.
- **Devices narrower than 834pt are untested.** Only the iPad Pro 11-inch
  (M5) simulator (834pt portrait width) was used. An iPad mini is 744pt
  portrait — 90pt narrower — and the transport button rows were already
  wrapping (`Slow 0.25×` to two lines, the timecode splitting) at 834pt, so a
  narrower device is expected to be worse, not merely unverified.

## Carried forward

### Phase 4 (touch and keyboard input) — unchanged scope

Phase 4 still owns touch and keyboard input; this phase did not touch it.
`ComparisonView` on iPad is wired to `InertInputSource()`, the same
do-nothing source the main viewer uses, "correct until phase 4 brings touch
and keyboard input." Everything gated on real input remains dead on iPad
until then.

### Sort on iPad — blocked on phase 2

Sort stays blocked on phase 2's AVFoundation media pipeline, as phase 3 also
recorded. `SortingSheet` compiles for iOS only because it takes
`MediaPipeline` as a protocol; the sole implementation
(`FFmpegMediaPipeline`) shells out via `Process`, which does not exist on
iOS. This phase made the block explicit and load-bearing rather than merely
theoretical: `canPresentSorting` is hard-`false` on `IOSSecondaryScreenPresenter`
specifically because there is nothing correct for it to do yet.

### Pre-existing portrait layout issue — deliberately left alone

`Divider()` inside the overlay's pane-header and per-pane transport
`HStack`s is vertically greedy, so those rows compete with
`OverlayPlayerStack` for height. In portrait on the iPad Pro 11-inch, the
video stack gets roughly a quarter of the available height. This is
`ComparisonView`'s pre-existing shape, present since before phase 5, and it
renders the same way on macOS — fixing it would change macOS rendering,
which was out of scope here, so it was left alone on both platforms. Worth a
later look once someone can watch a Mac screen for the eyeball pass above.

Separately, but in the same portrait check: nothing else was clipped or
unreachable in either orientation on the iPad Pro 11-inch. The layout picker,
blend picker, transport rows (tight but legible), overlay controls row, and
synchronised controls row all remained hittable and on-screen. No layout
adaptation was made because none was needed at that width — see "Uncovered
paths" above for why a narrower device is a different question.

## This phase's one fix

The whole-branch review flagged a stale comment in
`Tests/SkiVideoCoreTests/ComparisonModelTests.swift` (around
`testLeavingDifferenceModeRestoresTheSliderOpacity`): it said
`OverlayPlayerStack` "no longer branches on `blend` for opacity," which was
true only briefly — task 4 restored the branch
(`Shared/OverlayPlayerStack.swift:42`,
`.opacity(blend == .difference ? 1 : max(0, min(1, topOpacity)))`) as
defence in depth, per the reviewer's argument recorded in the ledger (P5 Task
3, minor 2). A reader trusting the stale comment could conclude the branch
was dead code and delete it, reopening the exact silent failure it guards
against: a future call site passing `overlayOpacity` instead of
`topLayerOpacity` would produce a translucent difference blend with no
compile error and no failing test. The comment was rewritten to state that
the view re-applies the model's rule as defence in depth, that the model
remains where the rule lives, and that the forced 1.0 must therefore be
computed, never latched. The test body was left unchanged — it was already
correct.


## Spike resolved for phase 4 (measured 2026-08-01)

The design doc flagged backward slow-scrub as **risk #1**, to be spiked early
because a bad result would reshape the phase 4 input design. It reasoned that
`canPlayReverse` is "usually false" for camera H.264, so iPad would fall back to
`ViewerModel`'s 12.5-seeks-per-second timer and stutter on external storage.

**That reasoning was wrong for this footage.** Measured against real
`~/Ski/Neuss2026` clips with a retained `AVPlayer`, waiting for
`.readyToPlay`:

```
C0087.MP4: READY  canPlayReverse=true  canPlaySlowReverse=true  canPlayFastReverse=true
C0098.MP4: READY  canPlayReverse=true  canPlaySlowReverse=true  canPlayFastReverse=true
```

So `ViewerModel.resumeHeldPlayback` takes the smooth
`playImmediately(atRate: -0.35)` branch, and the timer fallback is dead code for
this library. Phase 4's hold-to-scrub can rely on smooth reverse.

Two caveats:
- **Measured on macOS**, not on iOS. Same VideoToolbox H.264 decoder underneath,
  but phase 4 should confirm on the simulator before depending on it.
- A first attempt returned `status=0` (`.unknown`) with `canPlayReverse=false`,
  because the probe let the `AVPlayer` deallocate so the item never loaded. That
  is a **false negative that looks exactly like a real answer** — any future
  probe of this property must retain the player and wait for `.readyToPlay`.
