# Comparison Overlay Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a superimposed ("overlay") playback layout to the existing Compare Videos window so two ski clips can be watched drawn on top of each other, with an opacity blend and a difference blend.

**Architecture:** The overlay is a second *layout* over the existing `ComparisonModel` — the same two `AVPlayer`s, the same host-clock sync, the same file pickers and keyboard handling. Three additions: published layout/blend state on the model, a new `NSViewRepresentable` that stacks two `AVPlayerLayer`s in one view, and a split of `ComparisonView`'s pane into a reusable header and transport so both layouts share them.

**Tech Stack:** Swift 6.3 toolchain (language mode 5), SwiftPM, SwiftUI + AppKit + AVFoundation/AVKit + CoreImage, XCTest. macOS 13+ deployment target.

## Global Constraints

- Working directory for all commands: `/Users/ulfnielsen/Ski/script/SkiVideoViewer`.
- **Tests and builds MUST be run with `DEVELOPER_DIR` pointed at Xcode.** The machine's `xcode-select` points at `/Library/Developer/CommandLineTools`, which has no XCTest, so a bare `swift test` fails with `no such module 'XCTest'`. Always use:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
- The `SkiVideoViewer/` directory is currently **untracked** in git (repo root is `/Users/ulfnielsen/Ski/script`). Commit steps below therefore `git add` explicit file paths only — never `git add -A`, which would sweep the whole untracked app directory and unrelated modified Python files into the commit.
- Deployment target is macOS 13. Do not use APIs newer than macOS 13.
- No spatial alignment of any kind in this iteration: no anchor points, no pan, no zoom, no rotation. Both clips are drawn into the same rect and whatever registration results is what the user sees.
- Do not change any existing behaviour of the side-by-side layout, of sync points, of paired playback, or of the keyboard monitor.
- No force-unwrapping of `CIFilter(name:)`.

---

### Task 1: Layout and blend state on `ComparisonModel`

Adds the model state the overlay layout will read. Pure state — no rendering yet, so it is fully unit-testable.

**Files:**
- Modify: `Sources/SkiVideoViewer/ComparisonModel.swift` (add enums above `ComparisonModel`, add published properties near the other `@Published` declarations around lines 25-32)
- Create: `Tests/SkiVideoViewerTests/ComparisonModelTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks. Uses the existing `ComparisonModel.init(initialLeftVideo:openLibrary:)`, which has defaults for both parameters, so `ComparisonModel()` is valid.
- Produces, for Tasks 2 and 3:
  - `enum ComparisonLayout: String, CaseIterable, Identifiable { case sideBySide, overlay }` with `var id: String { rawValue }` and `var title: String` returning `"Side-by-side"` / `"Overlay"`
  - `enum OverlayBlend: String, CaseIterable, Identifiable { case blend, difference }` with `var id: String { rawValue }` and `var title: String` returning `"Blend"` / `"Difference"`
  - `ComparisonModel.layout: ComparisonLayout` (published, default `.sideBySide`)
  - `ComparisonModel.overlayOpacity: Double` (published, default `0.5`)
  - `ComparisonModel.blend: OverlayBlend` (published, default `.blend`)
  - `ComparisonModel.topLayerOpacity: Double` (computed, non-published)

- [ ] **Step 1: Write the failing test**

Create `Tests/SkiVideoViewerTests/ComparisonModelTests.swift` with exactly this content:

```swift
import XCTest
@testable import SkiVideoViewer

@MainActor
final class ComparisonModelTests: XCTestCase {
    private func makeModel() -> ComparisonModel {
        ComparisonModel()
    }

    func testDefaultsToSideBySideBlendAtHalfOpacity() {
        let model = makeModel()
        defer { model.close() }

        XCTAssertEqual(model.layout, .sideBySide)
        XCTAssertEqual(model.blend, .blend)
        XCTAssertEqual(model.overlayOpacity, 0.5, accuracy: 0.0001)
    }

    func testTopLayerOpacityFollowsSliderInBlendMode() {
        let model = makeModel()
        defer { model.close() }

        model.blend = .blend
        model.overlayOpacity = 0.25
        XCTAssertEqual(model.topLayerOpacity, 0.25, accuracy: 0.0001)

        model.overlayOpacity = 0.9
        XCTAssertEqual(model.topLayerOpacity, 0.9, accuracy: 0.0001)
    }

    func testTopLayerOpacityIsFullInDifferenceMode() {
        let model = makeModel()
        defer { model.close() }

        model.overlayOpacity = 0.25
        model.blend = .difference
        XCTAssertEqual(model.topLayerOpacity, 1.0, accuracy: 0.0001)

        model.overlayOpacity = 0.0
        XCTAssertEqual(model.topLayerOpacity, 1.0, accuracy: 0.0001)
    }

    func testSwitchingLayoutLeavesBlendAndOpacityUntouched() {
        let model = makeModel()
        defer { model.close() }

        model.overlayOpacity = 0.3
        model.blend = .difference
        model.layout = .overlay

        XCTAssertEqual(model.overlayOpacity, 0.3, accuracy: 0.0001)
        XCTAssertEqual(model.blend, .difference)

        model.layout = .sideBySide
        XCTAssertEqual(model.overlayOpacity, 0.3, accuracy: 0.0001)
        XCTAssertEqual(model.blend, .difference)
    }

    func testLayoutAndBlendTitles() {
        XCTAssertEqual(ComparisonLayout.sideBySide.title, "Side-by-side")
        XCTAssertEqual(ComparisonLayout.overlay.title, "Overlay")
        XCTAssertEqual(OverlayBlend.blend.title, "Blend")
        XCTAssertEqual(OverlayBlend.difference.title, "Difference")
    }
}
```

Note on style: these tests construct a real `ComparisonModel` with no media loaded and call `close()` in a `defer` so the model's `NSEvent` monitor and periodic time observers are torn down between tests. Constructing the model in the test process has been verified to work — it creates two idle `AVPlayer`s and installs a local event monitor, neither of which needs a running app.

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ComparisonModelTests
```

Expected: compile FAILURE, with errors like `cannot find 'ComparisonLayout' in scope` and `value of type 'ComparisonModel' has no member 'topLayerOpacity'`. A compile failure is the correct "red" here — the types do not exist yet.

- [ ] **Step 3: Write the minimal implementation**

In `Sources/SkiVideoViewer/ComparisonModel.swift`, add these two enums immediately after the existing `enum ComparisonSide { ... }` block near the top of the file:

```swift
enum ComparisonLayout: String, CaseIterable, Identifiable {
    case sideBySide
    case overlay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sideBySide: return "Side-by-side"
        case .overlay: return "Overlay"
        }
    }
}

enum OverlayBlend: String, CaseIterable, Identifiable {
    case blend
    case difference

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blend: return "Blend"
        case .difference: return "Difference"
        }
    }
}
```

Then, inside `ComparisonModel`, directly below the existing `@Published private(set) var status = ...` line, add:

```swift
    @Published var layout: ComparisonLayout = .sideBySide
    @Published var overlayOpacity: Double = 0.5
    @Published var blend: OverlayBlend = .blend
```

These three are deliberately *not* `private(set)` — the view binds to them directly.

Finally, add this computed property next to the existing `var hasTwoVideos: Bool` accessor:

```swift
    /// Difference blending only reads correctly at full opacity, so the slider
    /// is ignored (and disabled in the UI) while difference mode is active.
    var topLayerOpacity: Double {
        blend == .difference ? 1.0 : overlayOpacity
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected: PASS. The 5 pre-existing `VideoLibraryTests` plus the 5 new `ComparisonModelTests` all pass — 10 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/SkiVideoViewer/ComparisonModel.swift Tests/SkiVideoViewerTests/ComparisonModelTests.swift
git commit -m "Add overlay layout and blend state to ComparisonModel"
```

---

### Task 2: `OverlayPlayerView` — two stacked `AVPlayerLayer`s

The rendering primitive. An `NSView` hosting two `AVPlayerLayer`s in the same bounds, with the top one's opacity and compositing filter driven by the model state from Task 1.

**Files:**
- Create: `Sources/SkiVideoViewer/OverlayPlayerView.swift`

**Interfaces:**
- Consumes: `OverlayBlend` from Task 1 (`.blend` / `.difference`).
- Produces, for Task 3: `OverlayPlayerView(bottomPlayer: AVPlayer, topPlayer: AVPlayer, topOpacity: Double, blend: OverlayBlend)` — a SwiftUI `View`.

- [ ] **Step 1: Write the implementation**

There is no unit test for this task: it is pure AppKit/CoreAnimation view plumbing whose behaviour is the pixels on screen. It is verified by building and then by the manual run in Task 4. Do not invent a test that only asserts the initialiser stores its arguments — that tests nothing.

Create `Sources/SkiVideoViewer/OverlayPlayerView.swift` with exactly this content:

```swift
import AVFoundation
import AppKit
import CoreImage
import SwiftUI

/// Draws two players into the same rect: `bottomPlayer` underneath,
/// `topPlayer` on top. Both use aspect-fit so neither clip is cropped and
/// both occupy the same frame. There is deliberately no spatial alignment.
struct OverlayPlayerView: NSViewRepresentable {
    let bottomPlayer: AVPlayer
    let topPlayer: AVPlayer
    let topOpacity: Double
    let blend: OverlayBlend

    func makeNSView(context: Context) -> OverlayPlayerNSView {
        let view = OverlayPlayerNSView()
        view.attach(bottomPlayer: bottomPlayer, topPlayer: topPlayer)
        view.apply(topOpacity: topOpacity, blend: blend)
        return view
    }

    func updateNSView(_ view: OverlayPlayerNSView, context: Context) {
        view.attach(bottomPlayer: bottomPlayer, topPlayer: topPlayer)
        view.apply(topOpacity: topOpacity, blend: blend)
    }

    static func dismantleNSView(_ view: OverlayPlayerNSView, coordinator: ()) {
        view.detachPlayers()
    }
}

final class OverlayPlayerNSView: NSView {
    private let bottomLayer = AVPlayerLayer()
    private let topLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayers()
    }

    private func configureLayers() {
        wantsLayer = true
        let host = layer ?? CALayer()
        layer = host
        host.backgroundColor = NSColor.black.cgColor
        for playerLayer in [bottomLayer, topLayer] {
            playerLayer.videoGravity = .resizeAspect
            playerLayer.frame = bounds
            host.addSublayer(playerLayer)
        }
    }

    override func layout() {
        super.layout()
        // Layer frame changes are implicitly animated by default, which makes
        // window resizing lag the video. Apply them without animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bottomLayer.frame = bounds
        topLayer.frame = bounds
        CATransaction.commit()
    }

    func attach(bottomPlayer: AVPlayer, topPlayer: AVPlayer) {
        if bottomLayer.player !== bottomPlayer {
            bottomLayer.player = bottomPlayer
        }
        if topLayer.player !== topPlayer {
            topLayer.player = topPlayer
        }
    }

    func detachPlayers() {
        bottomLayer.player = nil
        topLayer.player = nil
    }

    func apply(topOpacity: Double, blend: OverlayBlend) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch blend {
        case .blend:
            topLayer.compositingFilter = nil
            topLayer.opacity = Float(max(0, min(1, topOpacity)))
        case .difference:
            // CIFilter(name:) is optional; if the filter is unavailable we fall
            // back to an ordinary full-opacity draw rather than crashing.
            topLayer.compositingFilter = CIFilter(name: "CIDifferenceBlendMode")
            topLayer.opacity = 1
        }
        CATransaction.commit()
    }
}
```

Why `AVPlayerLayer` rather than another `AVPlayerView`: `AVPlayerView` owns its own layer hierarchy and does not let you set a `compositingFilter` on the video layer, and it cannot be made transparent over a sibling. `AVPlayerLayer` is the layer `AVPlayerView` wraps, so this is the same decode path with no extra cost.

- [ ] **Step 2: Build to verify it compiles**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

Expected: `Build complete!` with no errors.

- [ ] **Step 3: Run the full test suite to verify nothing regressed**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected: PASS — 10 tests, 0 failures (5 `VideoLibraryTests` + 5 `ComparisonModelTests`).

- [ ] **Step 4: Commit**

```bash
git add Sources/SkiVideoViewer/OverlayPlayerView.swift
git commit -m "Add OverlayPlayerView stacking two AVPlayerLayers"
```

---

### Task 3: Wire the layout toggle into `ComparisonView`

Splits the existing pane into reusable header and transport builders, then composes both layouts. This is the task that makes the feature visible.

**Files:**
- Modify: `Sources/SkiVideoViewer/ComparisonView.swift` (replace `videoPane(side:)` at lines 38-127 and the `body` at lines 25-36)

**Interfaces:**
- Consumes: `ComparisonLayout`, `OverlayBlend`, `model.layout`, `model.overlayOpacity`, `model.blend`, `model.topLayerOpacity` from Task 1; `OverlayPlayerView(bottomPlayer:topPlayer:topOpacity:blend:)` from Task 2.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Split `videoPane` into reusable pieces**

In `Sources/SkiVideoViewer/ComparisonView.swift`, replace the whole `private func videoPane(side:)` function (lines 38-127) with the three functions below. The header and transport bodies are moved verbatim from the original — the only change is which container they sit in.

```swift
    private func videoPane(side: ComparisonSide) -> some View {
        let player = side == .left ? model.leftPlayer : model.rightPlayer

        return VStack(spacing: 0) {
            paneHeader(side: side)

            NativePlayerView(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            paneTransport(side: side)
        }
    }

    private func paneHeader(side: ComparisonSide) -> some View {
        let isLeft = side == .left
        let name = isLeft ? model.leftName : model.rightName

        return HStack {
            Text(isLeft ? "Left" : "Right")
                .font(.headline)
            Text(name)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer()
            if !model.openLibrary.isEmpty {
                Menu("From Open Folder…") {
                    ForEach(model.openLibrary) { athlete in
                        Menu(athlete.name) {
                            ForEach(athlete.videos) { video in
                                Button(video.name) {
                                    model.load(video, side: side)
                                }
                            }
                        }
                    }
                }
            }
            Button("Choose File…") { model.chooseVideo(side: side) }
        }
        .padding(12)
        .background(.bar)
    }

    private func paneTransport(side: ComparisonSide) -> some View {
        let isLeft = side == .left
        let time = isLeft ? model.leftTime : model.rightTime
        let duration = isLeft ? model.leftDuration : model.rightDuration
        let scrubTime = isLeft ? leftScrubTime : rightScrubTime
        let isScrubbing = isLeft ? isScrubbingLeft : isScrubbingRight
        let displayedTime = isScrubbing ? scrubTime : time

        return VStack(spacing: 9) {
            Slider(
                value: Binding(
                    get: {
                        min(displayedTime, max(duration, 0))
                    },
                    set: {
                        if isLeft {
                            leftScrubTime = $0
                        } else {
                            rightScrubTime = $0
                        }
                        model.scrub(side, to: $0)
                    }
                ),
                in: 0...max(duration, 0.1),
                onEditingChanged: { editing in
                    if isLeft {
                        if editing {
                            leftScrubTime = time
                            isScrubbingLeft = true
                        } else {
                            isScrubbingLeft = false
                        }
                    } else if editing {
                        rightScrubTime = time
                        isScrubbingRight = true
                    } else {
                        isScrubbingRight = false
                    }
                }
            )
            .disabled(duration <= 0)

            HStack {
                Text("\(ComparisonModel.timecode(displayedTime)) / \(ComparisonModel.timecode(duration))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("−5s") { model.seek(side, by: -5) }
                Button("−1s") { model.seek(side, by: -1) }
                Button("Play / Pause") { model.toggleIndividual(side) }
                Button("Slow 0.25×") { model.playIndividual(side, rate: 0.25) }
                Button("+1s") { model.seek(side, by: 1) }
                Button("+5s") { model.seek(side, by: 5) }
            }
        }
        .padding(12)
        .background(.bar)
    }
```

- [ ] **Step 2: Build to verify the refactor compiles and side-by-side is unchanged**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

Expected: `Build complete!` with no errors. At this point the app behaves exactly as before — the refactor is behaviour-preserving.

- [ ] **Step 3: Commit the refactor on its own**

```bash
git add Sources/SkiVideoViewer/ComparisonView.swift
git commit -m "Split comparison pane into reusable header and transport"
```

- [ ] **Step 4: Add the layout picker, overlay layout, and overlay controls**

In the same file, replace the `body` property (lines 25-36 in the original) with:

```swift
    var body: some View {
        VStack(spacing: 0) {
            layoutPicker

            switch model.layout {
            case .sideBySide:
                HStack(spacing: 1) {
                    videoPane(side: .left)
                    Divider()
                    videoPane(side: .right)
                }
            case .overlay:
                overlayLayout
            }

            synchronizedControls
        }
        .frame(minWidth: 1000, minHeight: 680)
        .onDisappear { model.close() }
    }

    private var layoutPicker: some View {
        HStack {
            Picker("", selection: $model.layout) {
                ForEach(ComparisonLayout.allCases) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var overlayLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                paneHeader(side: .left)
                Divider()
                paneHeader(side: .right)
            }

            OverlayPlayerView(
                bottomPlayer: model.leftPlayer,
                topPlayer: model.rightPlayer,
                topOpacity: model.topLayerOpacity,
                blend: model.blend
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            overlayControls

            HStack(spacing: 1) {
                paneTransport(side: .left)
                Divider()
                paneTransport(side: .right)
            }
        }
    }

    private var overlayControls: some View {
        HStack(spacing: 14) {
            Text("Left")
                .foregroundStyle(.secondary)
            Slider(value: $model.overlayOpacity, in: 0...1)
                .frame(minWidth: 180)
                .disabled(model.blend == .difference)
            Text("Right")
                .foregroundStyle(.secondary)

            Picker("", selection: $model.blend) {
                ForEach(OverlayBlend.allCases) { blend in
                    Text(blend.title).tag(blend)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

            Text(
                model.blend == .difference
                    ? "Difference blending uses full opacity · black where the clips match"
                    : "Right video drawn over left · drag toward a side to favour that clip"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .background(.bar)
    }
```

Note: `$model.layout`, `$model.overlayOpacity`, and `$model.blend` require those three properties to be settable from outside the model — Task 1 declared them without `private(set)` for exactly this reason.

- [ ] **Step 5: Build to verify it compiles**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

Expected: `Build complete!` with no errors.

- [ ] **Step 6: Run the full test suite**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected: PASS — 10 tests, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add Sources/SkiVideoViewer/ComparisonView.swift
git commit -m "Add overlay layout to the comparison window"
```

---

### Task 4: Manual verification and documentation

The pixels are the deliverable, so this task runs the real app against two clips and records the result. It also updates the README section that describes Compare Videos.

**Files:**
- Modify: `../README.md` (the "Viewing Organized Videos" section, in the paragraph beginning "Use **Compare Videos…**")

**Interfaces:**
- Consumes: the finished feature from Tasks 1-3.
- Produces: nothing.

- [ ] **Step 1: Launch the app against a folder of clips**

Run (adjust the path to a real organized/resized library on this machine, e.g. the ones under `~/Ski/`):

```bash
./run.sh ~/Ski/Neuss2026/organized_resize
```

If no such library exists, run `./run.sh` with no argument and use the folder picker, or point it at `../testvid`.

- [ ] **Step 2: Walk through the overlay checklist**

In the app: select a clip, click **Compare Videos…**, load a second clip into the right pane, then verify each of the following and note the result:

1. The **Side-by-side / Overlay** segmented picker appears at the top of the window and switching between the two layouts does not stop playback or reset either clip's position.
2. In Overlay, both clips are visible superimposed, aspect-fit, neither cropped.
3. The opacity slider at 0 shows only the left clip; at 1 only the right; in the middle both are ghosted.
4. Both per-side scrubbers and their ±1s/±5s buttons still move each clip independently while in Overlay.
5. **Set Sync Points** followed by **Play Together** (and Space) plays both clips in step while superimposed.
6. Switching to **Difference** turns matching pixels black and disables the opacity slider.
7. Resizing the window keeps both video layers filling the frame with no lag or drift between them.

If any of 1-7 fails, stop and fix it before continuing — that is a bug in Tasks 1-3, not an acceptable outcome.

- [ ] **Step 3: Record how difference mode actually looked**

The spec predicts difference mode will read as noise unless the two clips were shot from a near-identical camera position. Write down which it was — usable, or noise. This is the finding that decides whether the follow-up is manual pan/zoom, anchor points, or nothing.

- [ ] **Step 4: Update the README**

In `../README.md`, find the paragraph in the "Viewing Organized Videos" section that begins "Use **Compare Videos…** to open a maximized side-by-side review window." Append this sentence to the end of that paragraph:

```
Switch the layout picker to **Overlay** to draw the two clips superimposed in one frame: the opacity slider fades between left and right, and **Difference** mode renders matching pixels black so divergence stands out. Overlay keeps both per-side scrubbers, so you can still align the clips in time and set sync points while watching them stacked. The clips are drawn into the same rect with no spatial alignment, so difference mode is only readable when both runs were filmed from about the same camera position.
```

- [ ] **Step 5: Commit**

```bash
git add ../README.md
git commit -m "Document comparison overlay mode"
```

---

## Verification

The feature is complete when all of the following hold, each confirmed by running the command and reading its output:

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` → `Build complete!`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` → 10 tests, 0 failures
- All seven checks in Task 4 Step 2 pass in the running app
- `git log --oneline -5` shows the five commits from Tasks 1-4
