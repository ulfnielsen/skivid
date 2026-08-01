# iPadOS Phase 5: Compare on iPad — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Side-by-side and overlay video comparison on iPad, reachable from the toolbar, with the macOS comparison window unchanged.

**Architecture:** `ComparisonModel` is already in `SkiVideoCore` and its tests already run on the simulator, so this phase is view-layer work. The overlay is rewritten as a SwiftUI `ZStack` using `.blendMode(.difference)` — measured to work on `AVPlayerLayer`-backed views — rather than ported from the macOS `CALayer.compositingFilter` implementation, which is a **no-op on iOS**. `ComparisonView` moves back to `Shared/`, an iOS `SecondaryScreenPresenter` presents it as a full-screen cover, and the layout adapts to portrait.

**Tech Stack:** Swift 6.1 (language mode 5), SwiftPM, XcodeGen 2.45.4, SwiftUI, AVFoundation, AVKit, XCTest, `xcrun simctl`.

## The spike that shaped this plan

Measured on 2026-08-01, iPad Pro 11-inch (M5) simulator, not assumed:

- **`CALayer.compositingFilter` is a silent no-op on iOS.** Two layers, red under
  cyan with `CIDifferenceBlendMode`, rendered the overlap as plain **cyan**
  instead of white. Porting `macOS/OverlayPlayerView.swift` verbatim would have
  shipped a Difference mode that does nothing and looks plausible.
- **SwiftUI `.blendMode(.difference)` works on video.** A red clip under a cyan
  clip in a `ZStack` of two `AVPlayerLayer`-backed views rendered **white**; an
  `.opacity(0.5)` control rendered **grey**. Video layers are not composited
  out-of-band here.

Everything below follows from that.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-31-ipados-support-design.md`. Prior outcomes:
  `docs/superpowers/specs/2026-07-31-ipados-phase1-outcomes.md` and
  `docs/superpowers/specs/2026-07-31-ipados-phase3-outcomes.md`.
- **The macOS app's behaviour must not change.** macOS cannot be launched from
  this environment, so anything touching macOS rendering must be provably
  neutral or explicitly flagged for a human check.
- `Sources/SkiVideoCore/` must never import `AppKit`, `UIKit`, or `SwiftUI`, nor
  reference `Process`.
- `Sources/SkiVideoViewer/Shared/` must contain only files that compile for both
  platforms, and `project.yml` must have **no `excludes:`**. That invariant was
  restored in phase 3; do not reintroduce an exclusion.
- Swift language mode stays `.v5`. Minimums: macOS 13, iOS 17.
- **Every shell running `swift build`, `swift test`, `xcodebuild` or `xcrun` must
  first run `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.**
- **Do NOT point anything at `~/Ski` — the sorting flow MOVES files.** Generate
  fixtures with ffmpeg in a temp directory.
- Verification is automated. On iOS that includes real UI verification via
  `./scripts/ipad-smoke.sh`; do not settle for "it compiles".
- Nothing becomes `public` without a real consumer. Verify by grep.

**Baselines that must hold at every task boundary:**

| Command | Expected |
|---|---|
| `swift test` | 77 tests, 0 failures |
| `xcodebuild -scheme SkiVideoCore-iOS -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' test` | 46 tests, 0 failures |
| `xcodebuild -scheme SkiVideoViewer-macOS -destination 'platform=macOS' build` | BUILD SUCCEEDED |
| `xcodebuild -scheme SkiVideoViewer-iPad -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build` | BUILD SUCCEEDED |
| `./build_app.sh` | prints the shipping macOS bundle path |
| `./scripts/ipad-smoke.sh` | `==> RUNNING` plus a screenshot |

## Out of scope

Touch gestures and hardware-keyboard input (phase 4 — the comparison window is
driven by its on-screen controls this phase), Sort on iPad (needs the phase 2
AVFoundation pipeline, since `FFmpegMediaPipeline` uses `Process`), Drive auth
(phase 6).

## A DECISION FOR THE HUMAN, before Task 4

`.blendMode(.difference)` works on **both** platforms. So the SwiftUI overlay
built in Task 3 could also replace `macOS/OverlayPlayerView.swift`, deleting 98
lines of AppKit and giving both platforms one implementation.

**This plan does NOT do that by default.** Task 4 is written as the safe option
and Task 4b as the unification, and the executor must ask before running 4b.

- **Safe (Task 4, default):** macOS keeps `OverlayPlayerView`; iPad uses the
  SwiftUI overlay. Two implementations of one feature, but zero macOS risk.
- **Unify (Task 4b, needs approval):** both platforms use the SwiftUI overlay.
  Deletes `OverlayPlayerView.swift`. The macOS overlay's rendering changes, and
  **nothing in this environment can verify macOS rendering** — it would need the
  user to compare before/after by eye. The macOS implementation also has one
  property the SwiftUI version must reproduce: `CATransaction` with
  `setDisableActions(true)` to stop layer-frame changes animating during window
  resize (`macOS/OverlayPlayerView.swift:58-67`). SwiftUI has no equivalent knob,
  so resize behaviour may differ.

Recommendation: take Task 4. Revisit unification when someone can watch a Mac
screen — it is a cleanup, not a feature, and the duplication is 98 lines.

## File Structure

**Moved**

| File | From | To |
|---|---|---|
| `ComparisonView.swift` | `macOS/` | `Shared/` |

**Created**

| File | Responsibility |
|---|---|
| `Sources/SkiVideoViewer/Shared/OverlayPlayerStack.swift` | SwiftUI overlay: `ZStack` of two players with blend and opacity |
| `Sources/SkiVideoViewer/Shared/SinglePlayerView.swift` | One `AVPlayer` in a platform-appropriate representable, used by the stack |
| `Sources/SkiVideoViewer/iOS/iOSSecondaryScreenPresenter.swift` | Presents Compare as a full-screen cover; Sort still unavailable |
| `Tests/SkiVideoCoreTests/ComparisonLayoutTests.swift` | Covers `topLayerOpacity` and layout/blend state transitions |

**Modified**

`Shared/ComparisonView.swift` (portrait layout, overlay swap),
`Sources/SkiVideoViewer/iOS/SkiVideoViewerApp_iOS.swift` (use the new presenter),
`SkiVideoViewer/project.yml` (no source-list change expected — verify).

**Unchanged, explicitly:** `macOS/OverlayPlayerView.swift`,
`macOS/ComparisonWindowController.swift`, `SkiVideoCore/ComparisonModel.swift`.

---

### Task 1: Move ComparisonView back to Shared and prove it compiles for iOS

`ComparisonView` was parked in `macOS/` in phase 3 because it references
`OverlayPlayerView`. It cannot move until the overlay is platform-neutral — so
this task moves it and temporarily stubs the overlay branch, which Task 3 fills
in. The point is to surface every *other* iOS incompatibility now, in a small
diff, rather than mixed into the overlay work.

**Files:**
- Move: `Sources/SkiVideoViewer/macOS/ComparisonView.swift` → `Sources/SkiVideoViewer/Shared/ComparisonView.swift`
- Modify: that file's `overlayLayout` and its `.frame(minWidth:minHeight:)`

**Interfaces:**
- Consumes: `ComparisonModel`, `ComparisonLayout`, `OverlayBlend`, `ComparisonSide`, `ComparisonAthleteChoice` from `SkiVideoCore`.
- Produces: `Shared/ComparisonView.swift` compiling for both platforms.

- [ ] **Step 1: Move the file**

```bash
cd SkiVideoViewer/Sources/SkiVideoViewer
git mv macOS/ComparisonView.swift Shared/ComparisonView.swift
```

- [ ] **Step 2: Confirm `project.yml` needs no change**

```bash
cd SkiVideoViewer && grep -n "excludes" project.yml || echo "no excludes — good"
```

Both targets source whole directories, so a file moving between `macOS/` and
`Shared/` changes membership automatically. There should be nothing to edit. If
there is, say so in your report — it would mean phase 3's invariant is weaker
than believed.

- [ ] **Step 3: Temporarily stub the overlay branch**

In `Shared/ComparisonView.swift`, replace the body of `overlayLayout`'s use of
`OverlayPlayerView` with a placeholder so the file is platform-neutral. Keep
`paneHeader`, `overlayControls` and the surrounding structure intact — only the
player view itself is stubbed:

```swift
            // Task 3 replaces this with OverlayPlayerStack. The macOS
            // OverlayPlayerView cannot move here: it is an NSViewRepresentable,
            // and its CALayer.compositingFilter is a no-op on iOS anyway.
            Color.black
                .overlay(Text("Overlay").foregroundStyle(.secondary))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
```

- [ ] **Step 4: Fix the fixed minimum size**

`ComparisonView` sets `.frame(minWidth: 1000, minHeight: 680)`. An 11-inch iPad
is 834pt wide in portrait, so this clips. Match how `ContentView` solved the
same problem in phase 3 — read it first, then apply the same shape:

```swift
        #if os(macOS)
        .frame(minWidth: 1000, minHeight: 680)
        #endif
```

- [ ] **Step 5: Build both targets**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && xcodegen generate
xcodebuild -scheme SkiVideoViewer-macOS -destination 'platform=macOS' build 2>&1 | tail -2
xcodebuild -scheme SkiVideoViewer-iPad -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build 2>&1 | tail -2
```

Expected: both `** BUILD SUCCEEDED **`. If the iPad build fails on something
other than the overlay, that is the point of this task — fix it and report what
it was, since the plan did not predict it.

- [ ] **Step 6: Confirm Shared/ is still platform-neutral**

```bash
cd SkiVideoViewer && grep -n "AppKit\|UIKit\|NS[A-Z]\|UI[A-Z]" Sources/SkiVideoViewer/Shared/*.swift
```

Expected: no output.

- [ ] **Step 7: Run the suites**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test 2>&1 | tail -3 && ./build_app.sh
```

Expected: 77 tests, 0 failures, bundle path printed.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Move ComparisonView into Shared with the overlay stubbed"
```

---

### Task 2: A single-player view that works on both platforms

The overlay needs two independently-positioned players. `NativePlayerView`
exists twice with the same name — `AVPlayerView` on macOS, `AVPlayerViewController`
on iOS — but both are full player *controllers*, heavier than the overlay needs
and awkward to stack. This task adds a minimal `AVPlayerLayer`-backed view.

**Files:**
- Create: `Sources/SkiVideoViewer/Shared/SinglePlayerView.swift`

**Interfaces:**
- Consumes: nothing beyond AVFoundation and SwiftUI.
- Produces: `struct SinglePlayerView: View` with `init(player: AVPlayer)`, rendering one player with `videoGravity = .resizeAspect` and no controls.

- [ ] **Step 1: Write the view**

`Shared/` may not import AppKit or UIKit, so the platform representables are
selected inside one file with `#if` — this is the one place that is unavoidable,
because `NSViewRepresentable` and `UIViewRepresentable` are different protocols.
Keep the conditional as tight as possible and share everything else.

Create `Sources/SkiVideoViewer/Shared/SinglePlayerView.swift`:

```swift
import AVFoundation
import SwiftUI

/// One `AVPlayer` rendered by an `AVPlayerLayer`, with no transport controls.
/// The overlay stacks two of these, so it needs a bare layer rather than the
/// full player controller `NativePlayerView` provides.
///
/// `resizeAspect`, not `resizeAspectFill`: the overlay compares two clips, and
/// cropping either one would make the comparison lie. Phase 3 established the
/// same rule for the main viewer on iPad.
struct SinglePlayerView: View {
    let player: AVPlayer

    var body: some View {
        PlayerLayerRepresentable(player: player)
    }
}

#if os(macOS)
import AppKit

private struct PlayerLayerRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.attach(player)
        return view
    }

    func updateNSView(_ view: PlayerLayerHostView, context: Context) {
        view.attach(player)
    }
}

final class PlayerLayerHostView: NSView {
    private let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        wantsLayer = true
        let host = layer ?? CALayer()
        layer = host
        playerLayer.videoGravity = .resizeAspect
        host.addSublayer(playerLayer)
    }

    override func layout() {
        super.layout()
        // Layer frame changes animate implicitly, which lags the video during a
        // window resize. Apply them immediately.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func attach(_ player: AVPlayer) {
        if playerLayer.player !== player {
            playerLayer.player = player
        }
    }
}
#else
import UIKit

private struct PlayerLayerRepresentable: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.attach(player)
        return view
    }

    func updateUIView(_ view: PlayerLayerHostView, context: Context) {
        view.attach(player)
    }
}

final class PlayerLayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        playerLayer.videoGravity = .resizeAspect
    }

    func attach(_ player: AVPlayer) {
        if playerLayer.player !== player {
            playerLayer.player = player
        }
    }
}
#endif
```

The iOS side uses `layerClass` so the view's own layer *is* the player layer —
no manual frame maintenance, which is why it needs no `layout()` override.

- [ ] **Step 2: Build both targets**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && xcodegen generate
xcodebuild -scheme SkiVideoViewer-macOS -destination 'platform=macOS' build 2>&1 | tail -2
xcodebuild -scheme SkiVideoViewer-iPad -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build 2>&1 | tail -2
```

Expected: both succeed.

- [ ] **Step 3: Note the Shared/ conditional in your report**

Phase 3 established that `Shared/` holds no AppKit or UIKit. This file breaks
that by necessity — the two representable protocols are genuinely different
types. State it plainly in your report and confirm it is the ONLY such file, so
the exception stays visible rather than becoming a precedent.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "Add a shared single-player view backed by AVPlayerLayer"
```

---

### Task 3: The SwiftUI overlay

**Files:**
- Create: `Sources/SkiVideoViewer/Shared/OverlayPlayerStack.swift`
- Modify: `Sources/SkiVideoViewer/Shared/ComparisonView.swift` (replace the Task 1 stub)

**Interfaces:**
- Consumes: `SinglePlayerView` from Task 2; `ComparisonModel.leftPlayer`, `.rightPlayer`, `.topLayerOpacity`, `.blend`; `OverlayBlend` from `SkiVideoCore`.
- Produces: `struct OverlayPlayerStack: View` with `init(bottomPlayer: AVPlayer, topPlayer: AVPlayer, topOpacity: Double, blend: OverlayBlend)` — the same parameter names the macOS `OverlayPlayerView` takes, so the call site reads identically.

- [ ] **Step 1: Write the overlay**

Create `Sources/SkiVideoViewer/Shared/OverlayPlayerStack.swift`:

```swift
import AVFoundation
import SkiVideoCore
import SwiftUI

/// Two clips drawn into the same rect, `bottomPlayer` beneath `topPlayer`.
/// Both use aspect-fit so neither is cropped and both occupy the same frame.
/// There is deliberately no spatial alignment.
///
/// This is SwiftUI rather than the two-`AVPlayerLayer` view macOS uses, because
/// `CALayer.compositingFilter` is a silent no-op on iOS — measured on an iPad
/// Pro 11-inch (M5) simulator, where a red layer under a cyan one with
/// `CIDifferenceBlendMode` rendered the overlap plain cyan instead of white.
/// `.blendMode(.difference)` does work, including on `AVPlayerLayer`-backed
/// views: the same clips rendered white, and an `.opacity(0.5)` control
/// rendered grey.
struct OverlayPlayerStack: View {
    let bottomPlayer: AVPlayer
    let topPlayer: AVPlayer
    let topOpacity: Double
    let blend: OverlayBlend

    var body: some View {
        ZStack {
            Color.black
            SinglePlayerView(player: bottomPlayer)
            SinglePlayerView(player: topPlayer)
                .opacity(blend == .difference ? 1 : max(0, min(1, topOpacity)))
                .blendMode(blend == .difference ? .difference : .normal)
        }
        // Without this the blend composites against everything behind the
        // stack, not just the bottom player.
        .compositingGroup()
    }
}
```

The opacity and blend rules mirror the macOS implementation exactly: difference
mode forces full opacity, blend mode uses the slider. `ComparisonModel.topLayerOpacity`
already encodes the first half of that (`blend == .difference ? 1.0 : overlayOpacity`),
so read it before deciding whether the clamp here is redundant — if it is, use
the model's value and say so.

- [ ] **Step 2: Use it in ComparisonView**

Replace the Task 1 stub in `overlayLayout` with:

```swift
            OverlayPlayerStack(
                bottomPlayer: model.leftPlayer,
                topPlayer: model.rightPlayer,
                topOpacity: model.topLayerOpacity,
                blend: model.blend
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
```

Compare against `macOS/ComparisonView.swift` in git history to confirm the
argument list matches what the macOS overlay was given, so behaviour is the
same on the platform that already worked.

- [ ] **Step 3: Add model-level tests for the blend rules**

Create `Tests/SkiVideoCoreTests/ComparisonLayoutTests.swift`. These run on both
macOS and the iPad simulator, and they pin the rule the view depends on:

```swift
import XCTest
@testable import SkiVideoCore

@MainActor
final class ComparisonLayoutTests: XCTestCase {
    func testBlendModeUsesTheSliderOpacity() {
        let model = ComparisonModel()
        defer { model.close() }

        model.blend = .blend
        model.overlayOpacity = 0.25

        XCTAssertEqual(model.topLayerOpacity, 0.25, accuracy: 0.0001)
    }

    func testDifferenceModeForcesFullOpacity() {
        let model = ComparisonModel()
        defer { model.close() }

        model.blend = .difference
        model.overlayOpacity = 0.25

        XCTAssertEqual(
            model.topLayerOpacity, 1.0, accuracy: 0.0001,
            "difference blending only reads correctly at full opacity"
        )
    }

    func testLayoutDefaultsToSideBySideAndTogglesToOverlay() {
        let model = ComparisonModel()
        defer { model.close() }

        XCTAssertEqual(model.layout, .sideBySide)
        model.layout = .overlay
        XCTAssertEqual(model.layout, .overlay)
    }
}
```

Read `ComparisonModel` first — if `ComparisonModelTests` already covers any of
these, do not duplicate it. Add only what is missing and say which you skipped.

- [ ] **Step 4: Run everything**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test 2>&1 | tail -3
xcodebuild -scheme SkiVideoCore-iOS -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1
xcodebuild -scheme SkiVideoViewer-macOS -destination 'platform=macOS' build 2>&1 | tail -2
./build_app.sh
```

Expected: macOS suite up by however many tests you added, iOS suite likewise, both builds succeed.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Render the comparison overlay with SwiftUI blend modes"
```

---

### Task 4: Present Compare on iPad

**Files:**
- Create: `Sources/SkiVideoViewer/iOS/iOSSecondaryScreenPresenter.swift`
- Modify: `Sources/SkiVideoViewer/iOS/SkiVideoViewerApp_iOS.swift`
- Delete: `Sources/SkiVideoViewer/iOS/NoSecondaryScreenPresenter.swift`

**Interfaces:**
- Consumes: `SecondaryScreenPresenter` from `SkiVideoCore/SecondaryScreens.swift`; `ComparisonView` from Task 1.
- Produces: `final class IOSSecondaryScreenPresenter: ObservableObject, SecondaryScreenPresenter` with `canPresentComparison == true` and `canPresentSorting == false`, publishing the state `ContentView`'s host renders as a full-screen cover.

- [ ] **Step 1: Read the seam and the macOS implementation first**

```bash
cd SkiVideoViewer
cat Sources/SkiVideoCore/SecondaryScreens.swift
cat Sources/SkiVideoViewer/macOS/MacSecondaryScreenPresenter.swift
```

Match the protocol exactly. Note `presentSorting` must remain a no-op on iPad —
Sort needs the phase 2 AVFoundation pipeline, because `FFmpegMediaPipeline` uses
`Process`, which does not exist on iOS.

**A constraint carried from phase 3's review:** `ContentView` reads these flags while building `body`, and the presenter is not observed by
`ContentView`. So the availability flags introduced in Step 2 must be **constants** — do not
compute them from runtime state, or the toolbar will not update.

- [ ] **Step 2: Write the presenter**

The presenter both conforms to the seam and publishes presentation state, so the
app can render a cover. Keep `ComparisonView`'s parameters identical to the
macOS call site.

```swift
import SkiVideoCore
import SwiftUI

/// iPad has no separate windows, so Compare is a full-screen cover. Sort stays
/// unavailable until phase 2 replaces the ffmpeg pipeline, which cannot run on
/// iOS.
@MainActor
final class IOSSecondaryScreenPresenter: ObservableObject, SecondaryScreenPresenter {
    struct ComparisonRequest: Identifiable {
        let id = UUID()
        let initialLeftVideo: URL?
        let openLibrary: [ComparisonAthleteChoice]
        let onClose: () -> Void
    }

    @Published var comparison: ComparisonRequest?

    // Constant on purpose: ContentView reads this while building `body` and
    // does not observe the presenter, so a runtime-varying value would not
    // update the toolbar.
    nonisolated var canPresentComparison: Bool { true }
    nonisolated var canPresentSorting: Bool { false }

    func presentComparison(
        initialLeftVideo: URL?,
        openLibrary: [ComparisonAthleteChoice],
        onClose: @escaping () -> Void
    ) {
        comparison = ComparisonRequest(
            initialLeftVideo: initialLeftVideo,
            openLibrary: openLibrary,
            onClose: onClose
        )
    }

    func presentSorting(
        openResizedLibrary: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    ) {
        // Sort & Resize needs the AVFoundation pipeline from phase 2.
    }

    func dismissComparison() {
        let request = comparison
        comparison = nil
        request?.onClose()
    }
}
```

If `SecondaryScreenPresenter` declares `canPresent` inside a `@MainActor`
protocol, `nonisolated` may not compile — follow the protocol, not this snippet,
and report what you had to change.

**A seam change is required here, and it is not optional.** Phase 3's
`canPresent` is a single flag gating both buttons. Setting it true to reveal
Compare would also reveal Sort, which does nothing on iPad — a dead button, and
a regression against phase 3 where both were correctly hidden.

Split the flag per screen. In `Sources/SkiVideoCore/SecondaryScreens.swift`,
replace `canPresent` with:

```swift
    var canPresentComparison: Bool { get }
    var canPresentSorting: Bool { get }
```

Then update the three sites:

- `MacSecondaryScreenPresenter` — both `true`. macOS behaviour must not change.
- `IOSSecondaryScreenPresenter` — `canPresentComparison` true,
  `canPresentSorting` false.
- `Shared/ContentView.swift` — the single `if secondaryScreens.canPresent`
  wrapping both toolbar items becomes two separate conditions, one per item.
  Keep the items in their existing order (Compare, then Sort) so the macOS
  toolbar is unchanged.

Update `Tests/SkiVideoCoreTests/SecondaryScreensTests.swift` and
`Tests/SkiVideoViewerTests/SecondaryScreenPresenterTests.swift`, which both
assert on `canPresent` today. Both flags must be constants, for the reason in
Step 1.

- [ ] **Step 3: Render the cover**

In `SkiVideoViewerApp_iOS.swift`, hold the presenter as a `@StateObject` and
attach the cover to `ContentView`:

```swift
            ContentView(
                model: model,
                initialDirectory: nil,
                secondaryScreens: secondaryScreens
            )
            .fullScreenCover(item: $secondaryScreens.comparison) { request in
                ComparisonView(
                    initialLeftVideo: request.initialLeftVideo,
                    openLibrary: request.openLibrary,
                    input: nil,
                    folderPicker: UIKitFolderPicker(),
                    closeWindow: { secondaryScreens.dismissComparison() }
                )
            }
```

Read `ComparisonView`'s actual initializer before writing this — phase 1 gave it
optional seam parameters with defaults, and the labels here are from memory.
Follow the source.

- [ ] **Step 4: Delete the placeholder presenter**

```bash
cd SkiVideoViewer && git rm Sources/SkiVideoViewer/iOS/NoSecondaryScreenPresenter.swift
```

- [ ] **Step 5: Build and smoke-test**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && xcodegen generate
cd .. && ./scripts/ipad-smoke.sh
```

Expected: `==> RUNNING`. **Read the screenshot yourself** and confirm the toolbar
now shows a Compare button.

- [ ] **Step 6: Verify Compare actually opens**

`simctl` has no input injection, so you cannot tap. Prove it another way and say
which you used: either add an XCUITest target (the phase 3 outcomes doc
recommends this and it is the durable answer), or use a temporary probe that
calls `presentComparison` on launch, screenshot the cover, and revert the probe
before committing. **If you use a probe, say so explicitly and confirm it is
reverted** — phase 3 had screenshots from throwaway builds and the provenance
had to be tracked by hand.

Whichever you choose, the screenshot must show: two video panes, the
side-by-side/overlay picker, and the synchronised controls.

- [ ] **Step 7: Run all gates**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test 2>&1 | tail -3
xcodebuild -scheme SkiVideoCore-iOS -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1
xcodebuild -scheme SkiVideoViewer-macOS -destination 'platform=macOS' build 2>&1 | tail -2
./build_app.sh
```

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Present the comparison screen on iPad as a full-screen cover"
```

---

### Task 4b: Unify the overlay on macOS — ONLY WITH HUMAN APPROVAL

**Do not run this task unless the human has explicitly approved it.** It changes
macOS rendering, and nothing in this environment can verify macOS rendering.

**Files:**
- Modify: `Sources/SkiVideoViewer/Shared/ComparisonView.swift`
- Delete: `Sources/SkiVideoViewer/macOS/OverlayPlayerView.swift`

- [ ] **Step 1: Confirm approval was given, in writing, in your task brief**

If it was not, stop and report BLOCKED. Do not infer approval.

- [ ] **Step 2: Remove the macOS-only overlay**

`ComparisonView` already uses `OverlayPlayerStack` after Task 3, on both
platforms, so `macOS/OverlayPlayerView.swift` should already be unreferenced.
Verify before deleting:

```bash
cd SkiVideoViewer && grep -rn "OverlayPlayerView" Sources/ Tests/
```

Expected: only its own definition. If anything else references it, stop and
report — Task 3 did not fully land.

```bash
git rm Sources/SkiVideoViewer/macOS/OverlayPlayerView.swift
```

- [ ] **Step 3: Build and test**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && xcodegen generate && swift test 2>&1 | tail -3
xcodebuild -scheme SkiVideoViewer-macOS -destination 'platform=macOS' build 2>&1 | tail -2
./build_app.sh
```

- [ ] **Step 4: Write the human check into your report**

State explicitly that the macOS overlay's rendering is unverified and needs a
human to open Compare, switch to Overlay, and check both Blend and Difference
against the previous build. Name the one known behavioural risk: the deleted
implementation used `CATransaction.setDisableActions(true)` so layer frames did
not animate during window resize; SwiftUI has no equivalent, so resizing the
comparison window may now lag or animate.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Use the SwiftUI overlay on macOS too and delete OverlayPlayerView"
```

---

## Phase 5 done when

- `ComparisonView` is in `Shared/`, `project.yml` has no `excludes:`, and
  `Shared/` contains exactly one file with an `#if os(...)` platform
  conditional for representables (`SinglePlayerView.swift`) plus the two
  pre-existing modifier conditionals in `ContentView` and `ComparisonView`.
- The iPad toolbar shows Compare, and tapping it opens the comparison screen —
  evidenced by a screenshot from a committed build or an XCUITest.
- Sort does not appear as a dead button on iPad.
- All six gates pass, with the suites having grown rather than shrunk.
- `macOS/OverlayPlayerView.swift` is untouched (Task 4) or deleted with the human
  check recorded (Task 4b).

## Carried forward

- **Phase 4** still owns touch and keyboard input; the comparison screen is
  driven only by its on-screen controls until then. Its synchronised
  play/pause and ±1s seek were bound to keys on macOS and have no iPad
  equivalent yet.
- **Sort on iPad** stays blocked on phase 2.
- If Task 4b was not taken, the overlay exists twice — SwiftUI on both
  platforms would be a later cleanup, worth doing when someone can watch a Mac
  screen.
