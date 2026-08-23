# Watch and Sort on a Phone — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a coach can open a library, watch clips, and run Sort & Resize on an
iPhone. Comparison stays iPad-and-Mac only.

**Architecture:** `ContentView` branches on `horizontalSizeClass`. Regular keeps
today's `NavigationSplitView` untouched; compact gets a `NavigationStack` rooted
on the libraries list — Libraries → Athletes → Viewer, three pushes, the shape
iOS already teaches. Both branches reuse the existing `sidebar` and `detail`
subviews rather than growing a second copy of them. `SortingSheet` loses its
fixed minimums at compact width and stacks its label-field-button rows; nothing
about the sorting *model* changes.

**Tech Stack:** Swift 6.1 / SwiftPM (`swiftLanguageModes: [.v5]`), AVFoundation,
SwiftUI, XCTest, XcodeGen.

## What was measured before this plan was written

Not inferred — run, and in one case photographed.

- **An iPhone 17 Pro is 402 × 874 pt.** From a screenshot taken of the app
  running on that simulator: 1206 × 2622 px at 3×.
- **The app already builds and launches on a phone.** `TARGETED_DEVICE_FAMILY`
  flipped to `"1,2"` as a throwaway probe, built for and installed on an
  iPhone 17 Pro simulator, launched, screenshotted, then reverted. It compiles
  and runs with no source changes at all.
- **And it is unusable.** `NavigationSplitView` collapses to the sidebar on a
  phone, so the app lands on "Athletes". The libraries list lives in the detail
  pane, which is only pushed by selecting an athlete — and there are no athletes
  until a library is open. The toolbar carrying "Connect Google Drive…" and
  "Add Folder…" is attached to the detail column (`#if os(iOS)` in
  `ContentView`), so it is not on screen either. **There is no way in.**
- **`ComparisonView` declares `.frame(minWidth: 1000, minHeight: 680)`** —
  2.5× the phone's width.
- **`SortingSheet` declares `.frame(minWidth: 820, minHeight: 640)`** — 2×.
- **`IOSSecondaryScreenPresenter` hardcodes `canPresentComparison = true` and
  `canPresentSorting = true`.** Both buttons would appear on a phone; one of
  them opens a screen that cannot fit.
- **The viewer is already adaptive.** `ViewerPane` is a `GeometryReader` with
  `maxWidth` caps (460, 220, 320); `ViewerControlBar` is two buttons in 72
  lines. Neither is expected to need work — but see Task 6, which checks rather
  than assumes.
- **Sorting is button-driven, not keyboard-driven.** "Skip", the athlete
  buttons, "Add … & Tag", "Previous/Next Clip" are all real buttons;
  `keyboardShortcut(.defaultAction)` and `onSubmit` are accelerators on top.
  The phone needs layout work, not an interaction redesign.
- **Cellular already downloads.** There is no `allowsCellularAccess`,
  `waitsForConnectivity`, `allowsExpensiveNetworkAccess` or
  `allowsConstrainedNetworkAccess` anywhere in `Sources/`. `ClipCache` fetches
  through `URLSessionTransport(session: .shared)`, and `URLSession.shared`
  defaults `allowsCellularAccess` to `true`. **The chosen policy — always
  download — is today's behaviour and costs no work.** It is written down here
  so nobody later "fixes" it by adding a restriction.

## Global Constraints

- **The regular-width layout must not move.** Mac and iPad render exactly what
  they render today. Every compact change is behind a size-class branch, and
  the existing iPad UI tests are the check that says so.
- **No changes to `SortingModel`, `ClipPublisher`, `ViewerModel` sorting paths,
  or any Drive/OAuth code.** This plan is navigation and layout. If a task
  finds itself editing sorting logic, the task is wrong.
- **Comparison is out of scope and must be *absent* on a phone, not broken.**
  A button that opens a 1000pt screen on a 402pt device is worse than no button.
- **Test command is not plain `swift test`.** Prefix every invocation:
  `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter …`
- **Never `git add -A`** — `AppBundle/` holds intentionally uncommitted artwork.

## Tasks

### Task 1 — A phone can reach its libraries

The whole plan in one task: without it nothing else is testable on a phone.

- [ ] Add a compact branch to `ContentView.body` keyed on
      `@Environment(\.horizontalSizeClass)`. Regular: today's
      `NavigationSplitView`, unchanged. Compact: `NavigationStack` rooted on
      `LibrariesView`, pushing the athletes list when a library opens and the
      viewer when an athlete is selected.
- [ ] Reuse `sidebar` and `detail`'s inner views. Do not fork them — two copies
      of the athlete list is how the phone silently stops getting fixes.
- [ ] `LibrariesView` already carries its own "Add Folder…" and "Connect Google
      Drive…" buttons, so the root screen needs no toolbar. Verify that is true
      rather than assuming it.
- [ ] Test: a compact-width render lands on the libraries list. The existing
      `LibraryReopenTests` cover the model; this needs a UI-level check (Task 6).

### Task 2 — Comparison is absent at phone width

- [ ] Gate the Compare toolbar item on `horizontalSizeClass != .compact` in
      `ContentView.toolbarContent`, rather than in
      `IOSSecondaryScreenPresenter` — the presenter has no size class and
      giving it one would make a display concern into a model concern.
- [ ] Leave `canPresentComparison` alone. It answers "can this platform present
      a second screen at all", which is still true of an iPhone; the reason to
      hide the button is width, and that belongs to the view.
- [ ] Test: assert the item is absent at compact and present at regular.

### Task 3 — Sorting fits a 402pt screen

- [ ] Make `.frame(minWidth: 820, minHeight: 640)` conditional on regular width.
      At compact, no minimum.
- [ ] `setupView`: the label-field-button rows ("Raw clips" + path + "Choose…",
      "Athlete list" + path + "Choose…") stack vertically at compact. Consider
      a `Form`, which is the idiomatic iOS answer and would look right on both
      — but only if it does not disturb the regular layout (see constraints).
- [ ] `taggingView`: already a vertical stack with the player on top, so the
      work is the controls beneath it — the athlete match row needs to wrap or
      scroll rather than run off the edge.
- [ ] The hint line "←/→ seek 5s · Return tags · Resize queue: one at a time"
      names keys a phone does not have. Show the keyboard half only where there
      is a keyboard, or reword it.
- [ ] Verify the resize queue survives backgrounding — a phone suspends far
      more aggressively than an iPad on a desk, and a half-finished resize
      queue is the kind of thing that only shows up on a real device.

### Task 4 — The target admits phones

- [ ] `TARGETED_DEVICE_FAMILY: "1,2"` in `project.yml`. **It appears twice** —
      the app target (line ~83) and the UI test target (line ~127). Both.
- [ ] Decide orientations for phone. The iPad allows portrait and both
      landscapes; a phone watching ski footage wants landscape, and the
      viewer should not fight it.
- [ ] `xcodegen generate`, then build both schemes — SwiftPM staying green is
      not evidence the Xcode project does. This repo has been bitten by exactly
      that (`2026-08-13-sign-in-and-fetch-on-select.md`, task 1).

### Task 5 — Copy that assumes two columns

- [ ] "Choose one on the right." (`ContentView`, sidebar empty state) is false
      on a phone. Make it size-class aware or reword it so it is true on both.
- [ ] Sweep for others: any string naming a column, a side, or a window.

### Task 6 — Proof, on a phone

- [ ] Extend the UI test target to an iPhone destination. The iPad UI tests are
      the only automated UI check in this repo and they must stay green — run
      both, and expect the suite's wall-clock to roughly double.
- [ ] Screenshot each of the three screens on an iPhone simulator via
      `xcrun simctl io <sim> screenshot` and *look at them*. This works without
      Screen Recording permission, unlike `screencapture` on the desktop; it is
      how the "no way in" finding above was made.
- [ ] Deliberate-failure check on the reachability test: revert Task 1 and
      confirm the test goes red. A test that passes against the bug it was
      written for is worse than no test — that happened twice in this codebase's
      recent history.
- [ ] Full suite including the slow tests before sign-off:
      `SKI_SLOW_TESTS=1 DEVELOPER_DIR=… swift test`.

## What this plan does not do

- **Comparison on a phone.** 1148 lines built around a two-up layout at 1000pt.
  A stacked-portrait / side-by-side-landscape redesign is its own plan.
- **Sorting source selection.** How a phone gets at an SD card — a USB-C reader,
  Files, AirDrop — is untouched; the existing `pickFolder` path is whatever it
  already is on iOS.
- **Any cellular policy.** See the measurement above: always-download is the
  current behaviour and the chosen one.
- **Mac or iPad layout changes.** If a diff touches regular-width rendering,
  it has left the plan.
- **App Store or TestFlight.** Development signing, same as the iPad install.

## Open questions

- **Landscape lock for the viewer?** A coach showing an athlete a run holds the
  phone sideways. Whether the viewer should force landscape or merely support
  it is a judgement call this plan does not make.
- ~~**Sorting on a phone in the field.**~~ **Answered: a USB-C card reader
  works.** The card mounts in Files, so `UIKitFolderPicker` can reach it like
  any other location, and `keepsSourceIntact` — built for the iPad plan — is
  already the rule that keeps the card unwritten. Task 3 is worth finishing.
