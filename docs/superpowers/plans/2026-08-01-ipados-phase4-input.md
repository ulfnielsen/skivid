# iPadOS Phase 4: Touch and Keyboard Input — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drive the iPad viewer by touch, and by hardware keyboard when one is attached, with the macOS app unchanged.

**Architecture:** `ViewerModel` already consumes `PlaybackIntent`s and owns all the interesting timing — the 0.22s hold threshold, the 0.38s double-tap window, the 0.35× scrub rate. Phase 1 put the seam at "arrow down / arrow up" precisely so a touch gesture could emit the same pair a key press does. So this phase writes an iOS `PlaybackInputSource` and adds no timing logic: press-and-release on a side zone becomes `scrubBegan` → `scrubEnded`, which yields tap, double-tap and hold behaviour identical to macOS for free.

**Tech Stack:** Swift 6.1 (language mode 5), SwiftUI gestures, UIKit (`UIKeyCommand`, `pressesBegan`/`pressesEnded`), XCTest, XCUITest, `xcrun simctl`.

## What earlier phases established that this one relies on

- **`PlaybackIntent`** is: `togglePlayback`, `clip(Step)`, `athlete(Step)`, `scrubBegan(ScrubDirection)`, `scrubEnded(ScrubDirection, performTap: Bool)`, `focusAthleteSearch`, `openFolder`. `Step` is `.previous`/`.next`; `ScrubDirection` is `.backward = -1`/`.forward = 1`.
- **`ViewerModel` owns the timing.** `beginArrow`/`endArrow`/`performArrowTap` hold the thresholds. Do not reimplement them in the input source.
- **Spike resolved (measured):** `canPlayReverse` and `canPlaySlowReverse` are **true** for the real library, so backward hold-scrub takes the smooth `playImmediately(atRate: -0.35)` path, not the 12.5-seeks-per-second timer fallback. The design doc's risk #1 does not apply. Confirm it holds on the simulator before relying on it.
- **`Shared/` must reference no `macOS/`-only type**, and `Shared/SinglePlayerView.swift` is the only file there importing AppKit or UIKit. `project.yml` has no `excludes:`.
- **A UI-test target exists** (`Tests/SkiVideoViewerUITests/`), added in phase 5.
- **The document-picker trap:** the app auto-opens a `UIDocumentPickerViewController` at launch; its `PopoverDismissRegion` swallows taps while being invisible to the accessibility tree. A UI test can find a button, be told it is hittable, tap it cleanly, and have nothing happen. **Every UI test must dismiss the picker first and fail loudly if it is absent.** `CompareOnIPadUITests` has the helper — reuse it, do not reinvent it.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-31-ipados-support-design.md`, "Input model" section. Prior outcomes: the phase 1, 3 and 5 outcome docs under `docs/superpowers/specs/`.
- **The macOS app's behaviour must not change.** macOS cannot be launched from this environment. `macOS/AppKitInputSource.swift` must not be modified — it is the working macOS input path, and phase 1 already fixed two regressions in it.
- `Sources/SkiVideoCore/` must never import `AppKit`, `UIKit`, or `SwiftUI`, nor reference `Process`.
- Swift language mode stays `.v5`. Minimums macOS 13, iOS 17. Nothing `public` without a real consumer.
- **Every shell running `swift build`, `swift test`, `xcodebuild` or `xcrun` must first run `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.**
- Simulator runs are expected. Do NOT launch the macOS app. **Do NOT point anything at `~/Ski` — the sorting flow MOVES files.**
- The Xcode project is generated — `xcodegen generate` from `SkiVideoViewer/` after source-layout changes.

**Baselines that must hold at every task boundary:**

| Command | Expected |
|---|---|
| `swift test` | 80 tests, 0 failures |
| `xcodebuild -scheme SkiVideoCore-iOS -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' test` | 48 tests, 0 failures |
| the iPad UI-test scheme | 4 tests, 0 failures |
| `xcodebuild -scheme SkiVideoViewer-macOS -destination 'platform=macOS' build` | BUILD SUCCEEDED |
| `xcodebuild -scheme SkiVideoViewer-iPad -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build` | BUILD SUCCEEDED |
| `./build_app.sh` | prints the shipping macOS bundle path |
| `./scripts/ipad-smoke.sh` | `==> RUNNING` plus a screenshot |

## Out of scope

Sort on iPad (blocked on phase 2's AVFoundation pipeline), Drive auth (phase 6),
and **bookmark persistence** — the picked folder must still be re-chosen after
relaunch. That is a `SkiVideoCore` public-API change (`ViewerModel` stores
`String` paths, not `bookmarkData()`), large enough to deserve its own phase.

## File Structure

**Created**

| File | Responsibility |
|---|---|
| `Sources/SkiVideoViewer/iOS/TouchInputSource.swift` | Publishes gesture-derived intents; owns the zone and precedence rules |
| `Sources/SkiVideoViewer/iOS/PlaybackGestureOverlay.swift` | The SwiftUI gesture surface laid over the player |
| `Sources/SkiVideoViewer/iOS/KeyCommandHostView.swift` | `UIViewControllerRepresentable` giving `UIKeyCommand` + `pressesBegan`/`pressesEnded` |
| `Tests/SkiVideoViewerTests/TouchInputSourceTests.swift` | Zone mapping, gesture precedence, scrub pairing |
| `Tests/SkiVideoViewerUITests/InputOnIPadUITests.swift` | End-to-end: tap plays, swipe changes clip |

**Modified**

`Sources/SkiVideoViewer/iOS/SkiVideoViewerApp_iOS.swift` (use the real input source),
`Sources/SkiVideoViewer/Shared/ContentView.swift` (overlay the gesture surface; platform-correct hint copy),
`Sources/SkiVideoCore/ViewerModel.swift` (status string — see Task 3).

**Deleted:** `Sources/SkiVideoViewer/iOS/InertInputSource.swift`.

**Unchanged, explicitly:** `macOS/AppKitInputSource.swift`.

---

### Task 1: Touch input

**Files:**
- Create: `Sources/SkiVideoViewer/iOS/TouchInputSource.swift`
- Create: `Sources/SkiVideoViewer/iOS/PlaybackGestureOverlay.swift`
- Create: `Tests/SkiVideoViewerTests/TouchInputSourceTests.swift`
- Modify: `Sources/SkiVideoViewer/iOS/SkiVideoViewerApp_iOS.swift`
- Delete: `Sources/SkiVideoViewer/iOS/InertInputSource.swift`

**Interfaces:**
- Consumes: `PlaybackInputSource`, `PlaybackIntent`, `Step`, `ScrubDirection` from `SkiVideoCore/Seams.swift`.
- Produces: `final class TouchInputSource: PlaybackInputSource` with `func began(at x: CGFloat, width: CGFloat)`, `func moved(translation: CGSize)`, `func ended()`; `struct PlaybackGestureOverlay: View` with `init(source: TouchInputSource)`.

**The mapping**, which mirrors macOS exactly:

| Gesture | Intent | macOS equivalent |
|---|---|---|
| Tap centre third | `.togglePlayback` | Space |
| Press-and-release left/right third | `.scrubBegan` → `.scrubEnded(performTap: true)` | ← / → tap |
| Press-and-hold left/right third | same pair, held | ← / → hold |
| Swipe up / down | `.clip(.previous)` / `.clip(.next)` | ↑ / ↓ |

Athlete switching stays on the sidebar; there is no touch equivalent of Page Up/Down and none is needed.

- [ ] **Step 1: Write the failing tests**

`TouchInputSource` must be drivable without a real gesture, so its API takes plain values. Create `Tests/SkiVideoViewerTests/TouchInputSourceTests.swift`:

```swift
import SkiVideoCore
import XCTest
@testable import SkiVideoViewer

@MainActor
final class TouchInputSourceTests: XCTestCase {
    private func capture(
        _ drive: (TouchInputSource) -> Void
    ) -> [PlaybackIntent] {
        let source = TouchInputSource()
        var intents: [PlaybackIntent] = []
        source.onIntent = { intents.append($0) }
        drive(source)
        return intents
    }

    func testCentreTapTogglesPlayback() {
        let intents = capture { source in
            source.began(at: 500, width: 900)   // middle third
            source.ended()
        }
        XCTAssertEqual(intents.count, 1)
        guard case .togglePlayback = intents[0] else {
            return XCTFail("expected togglePlayback, got \(intents)")
        }
    }

    func testLeftZonePressAndReleaseEmitsABackwardScrubPair() {
        let intents = capture { source in
            source.began(at: 100, width: 900)   // left third
            source.ended()
        }
        XCTAssertEqual(intents.count, 2)
        guard case let .scrubBegan(began) = intents[0],
              case let .scrubEnded(ended, performTap) = intents[1]
        else {
            return XCTFail("expected a scrub pair, got \(intents)")
        }
        XCTAssertEqual(began, .backward)
        XCTAssertEqual(ended, .backward)
        XCTAssertTrue(performTap, "a released press is a tap")
    }

    func testRightZonePressAndReleaseEmitsAForwardScrubPair() {
        let intents = capture { source in
            source.began(at: 800, width: 900)   // right third
            source.ended()
        }
        guard case let .scrubBegan(began) = intents[0] else {
            return XCTFail("expected scrubBegan, got \(intents)")
        }
        XCTAssertEqual(began, .forward)
    }

    func testVerticalSwipeChangesClipAndCancelsAnyScrub() {
        // A drag that starts in a side zone but travels vertically is a clip
        // change, not a scrub — and the scrub it already began must be
        // cancelled without seeking.
        let intents = capture { source in
            source.began(at: 100, width: 900)
            source.moved(translation: CGSize(width: 2, height: 60))
            source.ended()
        }
        guard case .scrubBegan = intents[0],
              case let .scrubEnded(_, performTap) = intents[1],
              case let .clip(step) = intents[2]
        else {
            return XCTFail("expected scrubBegan, cancelling scrubEnded, clip; got \(intents)")
        }
        XCTAssertFalse(performTap, "a cancelled scrub must not seek")
        XCTAssertEqual(step, .next, "downward swipe advances a clip")
    }

    func testUpwardSwipeGoesToThePreviousClip() {
        let intents = capture { source in
            source.began(at: 450, width: 900)
            source.moved(translation: CGSize(width: 0, height: -60))
            source.ended()
        }
        guard case let .clip(step) = intents.last else {
            return XCTFail("expected a clip intent, got \(intents)")
        }
        XCTAssertEqual(step, .previous)
    }

    func testHorizontalDragInASideZoneStaysAScrub() {
        // Sliding sideways within the zone must not be mistaken for a swipe.
        let intents = capture { source in
            source.began(at: 100, width: 900)
            source.moved(translation: CGSize(width: 70, height: 5))
            source.ended()
        }
        XCTAssertEqual(intents.count, 2, "still just a scrub pair, got \(intents)")
    }

    func testDisabledSourceEmitsNothing() {
        let intents = capture { source in
            source.setEnabled(false)
            source.began(at: 100, width: 900)
            source.ended()
        }
        XCTAssertTrue(intents.isEmpty)
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test 2>&1 | grep -E "error:|cannot find" | head -3
```

Expected: `cannot find type 'TouchInputSource' in scope`.

- [ ] **Step 3: Write the input source**

Create `Sources/SkiVideoViewer/iOS/TouchInputSource.swift`. The precedence rule is the important part: a drag that starts in a side zone can travel vertically, so the source must decide by first significant movement and cancel an already-emitted scrub rather than emitting both.

```swift
import CoreGraphics
import SkiVideoCore

/// Turns touches on the player into `PlaybackIntent`s.
///
/// Deliberately no timing logic: `ViewerModel` owns the 0.22s hold threshold
/// and the 0.38s double-tap window, and it distinguishes tap from hold by how
/// long `scrubBegan` and `scrubEnded` are apart. So a press-and-release here
/// produces exactly what a key press and release produce on macOS, and tap,
/// double-tap and hold all behave identically without being reimplemented.
@MainActor
final class TouchInputSource: PlaybackInputSource {
    var onIntent: ((PlaybackIntent) -> Void)?

    /// Vertical travel past which a touch becomes a clip change rather than a
    /// scrub. Large enough that a shaky finger on a side zone does not skip a
    /// clip; small enough that a deliberate swipe is recognised early.
    private let swipeThreshold: CGFloat = 40

    private var isEnabled = true
    private var heldDirection: ScrubDirection?
    private var resolvedAsSwipe = false

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { cancelScrub() }
    }

    func began(at x: CGFloat, width: CGFloat) {
        guard isEnabled, width > 0 else { return }
        resolvedAsSwipe = false
        let third = width / 3
        if x < third {
            heldDirection = .backward
            onIntent?(.scrubBegan(.backward))
        } else if x > width - third {
            heldDirection = .forward
            onIntent?(.scrubBegan(.forward))
        } else {
            heldDirection = nil   // centre zone: resolved on release
        }
    }

    func moved(translation: CGSize) {
        guard isEnabled, !resolvedAsSwipe else { return }
        guard abs(translation.height) >= swipeThreshold,
              abs(translation.height) > abs(translation.width)
        else {
            return
        }
        resolvedAsSwipe = true
        cancelScrub()
        onIntent?(.clip(translation.height < 0 ? .previous : .next))
    }

    func ended() {
        guard isEnabled else { return }
        if resolvedAsSwipe {
            resolvedAsSwipe = false
            return
        }
        if let direction = heldDirection {
            heldDirection = nil
            onIntent?(.scrubEnded(direction, performTap: true))
        } else {
            onIntent?(.togglePlayback)
        }
    }

    /// Ends an in-flight scrub without seeking — used when a touch turns out to
    /// be a swipe, and when input is disabled mid-gesture.
    private func cancelScrub() {
        guard let direction = heldDirection else { return }
        heldDirection = nil
        onIntent?(.scrubEnded(direction, performTap: false))
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test 2>&1 | tail -3
```

Expected: 87 tests, 0 failures (80 + 7 new).

- [ ] **Step 5: Write the gesture surface**

Create `Sources/SkiVideoViewer/iOS/PlaybackGestureOverlay.swift`:

```swift
import SwiftUI

/// Transparent surface over the player that feeds `TouchInputSource`.
/// One `DragGesture(minimumDistance: 0)` handles taps, holds and swipes alike —
/// the source decides which by first significant movement.
struct PlaybackGestureOverlay: View {
    let source: TouchInputSource

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if value.translation == .zero {
                                source.began(
                                    at: value.startLocation.x,
                                    width: proxy.size.width
                                )
                            } else {
                                source.moved(translation: value.translation)
                            }
                        }
                        .onEnded { _ in source.ended() }
                )
        }
    }
}
```

`onChanged` fires once with zero translation at touch-down, which is what
distinguishes "began" from "moved". Verify that on the simulator in Task 3 — if
SwiftUI does not guarantee it, track the began state in the source instead and
say so in your report.

- [ ] **Step 6: Overlay it on the player**

In `Shared/ContentView.swift`, put the overlay over `NativePlayerView` on iOS
only — macOS has the `NSEvent` monitor and must not gain a gesture surface:

```swift
                NativePlayerView(player: model.player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    #if os(iOS)
                    .overlay(playbackGestures)
                    #endif
```

Pass the overlay in from the platform app rather than constructing it in shared
code, so `Shared/` gains no reference to an `iOS/` type. Read how
`secondaryScreens` was threaded in phase 3 and match that shape.

- [ ] **Step 7: Use the real source and delete the stub**

In `iOS/SkiVideoViewerApp_iOS.swift`, replace `InertInputSource()` with the
shared `TouchInputSource` instance, and:

```bash
cd SkiVideoViewer && git rm Sources/SkiVideoViewer/iOS/InertInputSource.swift
```

- [ ] **Step 8: Run every gate**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test 2>&1 | tail -3
xcodebuild -scheme SkiVideoCore-iOS -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1
xcodebuild -scheme SkiVideoViewer-macOS -destination 'platform=macOS' build 2>&1 | tail -2
./build_app.sh
cd .. && ./scripts/ipad-smoke.sh 2>&1 | tail -2
```

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "Drive the iPad viewer by touch"
```

---

### Task 2: Hardware keyboard

**Files:**
- Create: `Sources/SkiVideoViewer/iOS/KeyCommandHostView.swift`
- Modify: `Sources/SkiVideoViewer/iOS/TouchInputSource.swift` (accept key-derived intents) or add a sibling source — decide and justify
- Modify: `Sources/SkiVideoViewer/Shared/ContentView.swift` (host the responder)

**Interfaces:**
- Consumes: the same `PlaybackIntent` vocabulary.
- Produces: `struct KeyCommandHostView: UIViewControllerRepresentable` forwarding key events to a `PlaybackInputSource`.

**Why a `UIViewController` and not `.onKeyPress`:** `UIKeyCommand` has no key-*up* event, and the arrow hold needs one — `scrubEnded` must fire when the key is released. Only a `UIResponder` overriding `pressesBegan`/`pressesEnded` provides that. SwiftUI's `.onKeyPress(phases:)` would work but requires macOS 14, and this project's macOS floor is 13; the seam exists so the two platforms need not agree.

- [ ] **Step 1: Write the failing tests**

Extend `Tests/SkiVideoViewerTests/TouchInputSourceTests.swift` — or a sibling file if you split the source — with key-mapping tests mirroring `AppKitInputSourceTests`. Read that file first; it is the macOS equivalent and its key codes are the contract:

```swift
    func testSpaceKeyTogglesPlayback() {
        let intents = capture { $0.keyDown(.space) }
        guard case .togglePlayback = intents.first else {
            return XCTFail("expected togglePlayback, got \(intents)")
        }
    }

    func testArrowKeyDownThenUpEmitsAScrubPairWithTap() {
        let intents = capture {
            $0.keyDown(.rightArrow)
            $0.keyUp(.rightArrow)
        }
        XCTAssertEqual(intents.count, 2)
        guard case let .scrubBegan(began) = intents[0],
              case let .scrubEnded(ended, performTap) = intents[1]
        else {
            return XCTFail("expected a scrub pair, got \(intents)")
        }
        XCTAssertEqual(began, .forward)
        XCTAssertEqual(ended, .forward)
        XCTAssertTrue(performTap)
    }

    func testUpAndDownArrowsChangeClip() {
        let intents = capture {
            $0.keyDown(.upArrow)
            $0.keyDown(.downArrow)
        }
        guard case let .clip(up) = intents[0], case let .clip(down) = intents[1] else {
            return XCTFail("expected two clip intents, got \(intents)")
        }
        XCTAssertEqual(up, .previous)
        XCTAssertEqual(down, .next)
    }

    func testArrowKeyUpWithoutADownEmitsNothing() {
        XCTAssertTrue(capture { $0.keyUp(.leftArrow) }.isEmpty)
    }
```

Define whatever small key enum those helpers need. Do NOT try to synthesise
`UIPress` objects — they cannot be constructed meaningfully in a unit test. Test
the mapping function, and leave the responder wiring to Task 3's UI tests. Say
so explicitly in your report rather than implying the wiring is covered.

- [ ] **Step 2: Implement the mapping and run the tests**

Expected after: 91 tests, 0 failures.

- [ ] **Step 3: Write the responder host**

Create `Sources/SkiVideoViewer/iOS/KeyCommandHostView.swift`: a
`UIViewControllerRepresentable` whose controller returns `true` from
`canBecomeFirstResponder`, calls `becomeFirstResponder()` in `viewDidAppear`,
declares `keyCommands` for the keys that need no key-up (Space, ↑, ↓, Page
Up/Down), and overrides `pressesBegan`/`pressesEnded` for the arrows.

**Do not let it steal keys from text fields.** The macOS source guards on
`firstResponder is NSTextView`; the iOS equivalent is to check whether a
`UITextField`/`UITextView` is first responder before acting, and call `super`
otherwise. The athlete search field must keep working — phase 1 had a regression
in exactly this area on macOS and phase 3 had one on iPad.

- [ ] **Step 4: Host it and run every gate**

Attach it in `ContentView` alongside the gesture overlay, iOS only. Then run all
seven gates as in Task 1 Step 8.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Support hardware keyboards on iPad"
```

---

### Task 3: Platform-correct hints, and prove it on the simulator

**Files:**
- Modify: `Sources/SkiVideoViewer/Shared/ContentView.swift:219`
- Modify: `Sources/SkiVideoCore/ViewerModel.swift:345`
- Create: `Tests/SkiVideoViewerUITests/InputOnIPadUITests.swift`

- [ ] **Step 1: Fix the copy that lies**

`ContentView.swift:219` reads:

> `↑/↓ clips  ·  Page Up/Down athletes  ·  ⌘F find athlete  ·  Space play/pause  ·  ←/→ tap, double-tap, or hold`

On iPad there are no Page Up/Down keys and no guarantee of any keyboard, and
after Task 1 the gestures are the primary control. Give each platform its own
string. The iOS one should describe the gestures — tap to play, swipe for
clips, hold the sides to scrub — and may mention the keyboard as optional.

`ViewerModel.swift:345` sets `status = "Paused · Space to play"`, which is
`SkiVideoCore` and cannot mention a platform. Change it to something true
everywhere — "Paused" alone, or "Paused · ready" — and check whether any test
asserts on that exact string before editing.

- [ ] **Step 2: Confirm the reverse-playback spike holds on iOS**

The measurement that `canPlayReverse` is true was taken on macOS. Confirm on the
simulator, because backward hold-scrub depends on it. A short XCUITest or a
temporary probe both work; if you use a probe, revert it and confirm
`git status` is clean. Report the measured values.

If it turns out **false** on iOS, the timer fallback runs at 12.5 seeks/second —
say so plainly and record it as a phase-4 finding rather than working around it
silently.

- [ ] **Step 3: End-to-end UI tests**

Create `Tests/SkiVideoViewerUITests/InputOnIPadUITests.swift`. **Reuse
`CompareOnIPadUITests`'s picker-dismissal helper** — the launch document picker
swallows taps while being invisible to the accessibility tree, so without it a
test can tap successfully and have nothing happen. Cover at least: a centre tap
toggles playback, and a vertical swipe changes clip. Assert on observable UI
(the clip label, the status text), not on internal state.

XCUITest can drive gestures that `simctl` cannot — `app.tap()`, `swipeUp()`,
`press(forDuration:)`. This is the first phase where the interaction itself is
testable; use it.

- [ ] **Step 4: Run every gate and look at a screenshot**

All seven, plus a screenshot from the committed build you read yourself.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Describe the iPad's real controls and cover them end to end"
```

---

## Phase 4 done when

- Tapping the centre of the player toggles playback; tapping the sides seeks;
  holding a side slow-scrubs; swiping up and down changes clip — all proven by
  XCUITest, not asserted.
- A hardware keyboard drives Space, ↑/↓ and the arrow hold, with the athlete
  search field still able to receive typing.
- No on-screen text describes a control that does not exist on that platform.
- All seven gates pass, with both unit suites having grown.
- `macOS/AppKitInputSource.swift` is untouched.

## Carried forward

- **Bookmark persistence** — the picked folder is still lost on relaunch. Needs
  `ViewerModel` to store `bookmarkData()` rather than `String` paths, which is a
  `SkiVideoCore` public-API change.
- **Sort on iPad** stays blocked on phase 2.
- **Devices narrower than 834pt** are untested; an iPad mini is 744pt in
  portrait and the comparison transports already wrap at 834.
