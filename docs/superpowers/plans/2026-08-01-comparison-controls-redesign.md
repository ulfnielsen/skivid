# Comparison Controls Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the comparison screen its space back — one transport plus a target selector replacing three transports and eighteen buttons, on both macOS and iPadOS.

**Architecture:** `ComparisonModel` already routes per-side calls to synced behaviour when `isSynced`, so the per-side and "together" transports are the same controls twice. Adding one `target` property lets a single control bar drive either, and `ComparisonView` decomposes from a 290-line file holding seven sub-views into five files that each do one thing.

**Tech Stack:** Swift 6.1 (language mode 5), SwiftUI, SF Symbols, XCTest, XCUITest, XcodeGen, `xcrun simctl`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-01-comparison-controls-redesign.md`.
- **This deliberately changes macOS**, for the comparison screen only. Every other phase's "macOS behaviour must not change" rule still applies to the viewer, sorting, and Drive screens. macOS cannot be driven from this environment, so the phase ends with a human check.
- `Sources/SkiVideoCore/` must never import `AppKit`, `UIKit`, or `SwiftUI`, nor reference `Process`.
- `Sources/SkiVideoViewer/Shared/` must reference no `macOS/`-only type, and `Shared/SinglePlayerView.swift` must remain the ONLY file there importing AppKit or UIKit. `project.yml` must have no `excludes:`.
- Swift language mode `.v5`. Minimums macOS 13, iOS 17. Nothing `public` without a real consumer.
- **Touch targets are at least 44pt.** When the bar does not fit, it wraps to a second row — it never shrinks targets.
- **Every shell running `swift build`, `swift test`, `xcodebuild` or `xcrun` must first run `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.**
- Simulator runs expected. Do NOT launch the macOS app. **Do NOT point anything at `~/Ski` — the sorting flow MOVES files.**
- The Xcode project is generated — `xcodegen generate` from `SkiVideoViewer/` after source-layout changes.
- **Every UI test must dismiss the launch document picker first**, and fail loudly if it is absent. Its `PopoverDismissRegion` swallows taps while being invisible to the accessibility tree, so a test can find a button, be told it is hittable, tap it cleanly, and have nothing happen. `Tests/SkiVideoViewerUITests/CompareOnIPadUITests.swift` has the helper — reuse it.

**Baselines that must hold at every task boundary:**

| Command | Expected |
|---|---|
| `swift test` | 80 tests, 0 failures |
| `xcodebuild -scheme SkiVideoCore-iOS -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' test` | 48 tests, 0 failures |
| the iPad UI-test scheme | 4 tests, 0 failures |
| `xcodebuild -scheme SkiVideoViewer-macOS -destination 'platform=macOS' build` | BUILD SUCCEEDED |
| `xcodebuild -scheme SkiVideoViewer-iPad -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build` | BUILD SUCCEEDED |
| `./build_app.sh` | prints the shipping macOS bundle path |

## The model API this plan calls

Confirmed by reading `Sources/SkiVideoCore/ComparisonModel.swift`. Do not guess these:

```swift
public func chooseVideo(side: ComparisonSide) async
public func toggleIndividual(_ side: ComparisonSide)
public func playIndividual(_ side: ComparisonSide, rate: Float)
public func seek(_ side: ComparisonSide, by seconds: Double)
public func scrub(_ side: ComparisonSide, to seconds: Double)
public func setSyncPoints()
public func removeSync()
public func playSynced(rate: Float = 1)
public func pauseBoth()
public func seekSynced(by seconds: Double)
public func returnToSyncPoints()
public var hasTwoVideos: Bool
public var topLayerOpacity: Double
```

`playSynced` and `seekSynced` both open with
`guard isSynced else { status = "Set the sync points first."; return }`.

## File Structure

**Created** — all in `Sources/SkiVideoViewer/Shared/`:

| File | Responsibility |
|---|---|
| `ComparisonControlBar.swift` | Layout picker, target selector, transport, time, anchor |
| `ComparisonScrubber.swift` | The timeline for whatever is targeted |
| `ComparisonPane.swift` | One video, its filename, its empty-state Choose button |
| `OverlayBlendBar.swift` | Blend slider and mode; overlay only |

**Modified**

`Sources/SkiVideoCore/ComparisonModel.swift` (add `ComparisonTarget` and `target`),
`Sources/SkiVideoViewer/Shared/ComparisonView.swift` (recomposed to ~60 lines,
seven sub-views deleted).

**Deleted from `ComparisonView`:** `layoutPicker`, `overlayControls`,
`videoPane`, `paneHeader`, `paneTransport`, `synchronizedControls`, and the four
`@State` scrub properties at lines 6-9. `overlayLayout` survives in reduced form.

---

### Task 1: `ComparisonTarget` in the model

Pure model work, no UI. Doing it first means the bar in Task 2 has something real to drive.

**Files:**
- Modify: `Sources/SkiVideoCore/ComparisonModel.swift`
- Modify: `Tests/SkiVideoCoreTests/ComparisonModelTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public enum ComparisonTarget: String, CaseIterable, Identifiable, Sendable { case both, left, right }` with `public var id: String { rawValue }` and `public var title: String`; `@Published public var target: ComparisonTarget` on `ComparisonModel`; `public var availableTargets: [ComparisonTarget]`; `public func applyTransport(_ action: TransportAction)` where `public enum TransportAction { case back5, back1, playPause, forward1, forward5, slow }`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/SkiVideoCoreTests/ComparisonModelTests.swift`:

```swift
    func testTargetDefaultsToLeftWhileAligning() {
        let model = ComparisonModel()
        defer { model.close() }

        XCTAssertFalse(model.isSynced)
        XCTAssertEqual(model.target, .left)
    }

    func testBothIsNotOfferedUntilSyncPointsAreSet() {
        let model = ComparisonModel()
        defer { model.close() }

        XCTAssertEqual(model.availableTargets, [.left, .right],
                       "Both cannot work before sync: playSynced refuses")
    }

    func testTargetSwitchesToBothOnSync() throws {
        let model = try makeSyncedModel()
        defer { model.close() }

        XCTAssertTrue(model.isSynced)
        XCTAssertEqual(model.target, .both)
        XCTAssertEqual(model.availableTargets, [.both, .left, .right])
    }

    func testClearingSyncReturnsTargetToASide() throws {
        let model = try makeSyncedModel()
        defer { model.close() }

        model.removeSync()

        XCTAssertFalse(model.isSynced)
        XCTAssertNotEqual(model.target, .both,
                          "Both must not remain selected once it cannot work")
        XCTAssertEqual(model.availableTargets, [.left, .right])
    }

    func testTransportRoutesToTheTargetedSide() {
        let model = ComparisonModel()
        defer { model.close() }

        model.target = .right
        model.applyTransport(.back5)

        // With no media loaded the players cannot move, so assert on the
        // status text the model writes — it names which side acted.
        XCTAssertTrue(
            model.status.lowercased().contains("right"),
            "expected a right-side status, got \(model.status)"
        )
    }
```

`makeSyncedModel()` needs two loaded clips, because `setSyncPoints()` guards on
`hasTwoVideos`. Read how existing tests obtain a model, and add the helper
alongside them. If no existing test loads media, generate two one-second clips
with ffmpeg into a temp directory in `setUp`:

```swift
    private func makeFixtureClip(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=duration=1:size=320x180:rate=10",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", url.path,
        ]
        try process.run()
        process.waitUntilExit()
        return url
    }
```

**`Process` is macOS-only, and `ComparisonModelTests` runs on the iOS simulator
too** (it is in `SkiVideoCoreTests`, which the `SkiVideoCore-iOS` scheme runs).
So the fixture helper must be guarded with `#if os(macOS)` and the tests that
need real media skipped on iOS via `throw XCTSkip("needs ffmpeg fixtures")`.
State in your report which tests skip on iOS.

- [ ] **Step 2: Run them and watch them fail**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test 2>&1 | grep -E "error:|cannot find" | head -3
```

Expected: `cannot find type 'ComparisonTarget' in scope`.

- [ ] **Step 3: Add the target type and property**

In `Sources/SkiVideoCore/ComparisonModel.swift`:

```swift
/// Who the transport controls act on.
///
/// `both` is only meaningful once sync points are set — `playSynced` and
/// `seekSynced` both refuse otherwise — so `availableTargets` omits it while
/// aligning rather than offering a control that can only produce a nag.
public enum ComparisonTarget: String, CaseIterable, Identifiable, Sendable {
    case both, left, right

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .both: return "Both"
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}
```

On the model, beside the other `@Published` properties:

```swift
    @Published public var target: ComparisonTarget = .left

    public var availableTargets: [ComparisonTarget] {
        isSynced ? [.both, .left, .right] : [.left, .right]
    }
```

In `setSyncPoints()`, after `isSynced = true`, add `target = .both`.
In `removeSync()`, after `isSynced = false`, add
`if target == .both { target = .left }`.

- [ ] **Step 4: Add transport routing**

```swift
/// One transport action, routed by `target`.
public enum TransportAction: Sendable {
    case back5, back1, playPause, forward1, forward5, slow
}

extension ComparisonModel {
    public func applyTransport(_ action: TransportAction) {
        switch target {
        case .both:
            switch action {
            case .back5: seekSynced(by: -5)
            case .back1: seekSynced(by: -1)
            case .forward1: seekSynced(by: 1)
            case .forward5: seekSynced(by: 5)
            case .playPause:
                if leftPlayer.rate == 0 && rightPlayer.rate == 0 {
                    playSynced()
                } else {
                    pauseBoth()
                }
            case .slow: playSynced(rate: 0.25)
            }
        case .left, .right:
            let side: ComparisonSide = target == .left ? .left : .right
            switch action {
            case .back5: seek(side, by: -5)
            case .back1: seek(side, by: -1)
            case .forward1: seek(side, by: 1)
            case .forward5: seek(side, by: 5)
            case .playPause: toggleIndividual(side)
            case .slow: playIndividual(side, rate: 0.25)
            }
        }
    }
}
```

Put this in `ComparisonModel.swift` rather than a new file — it is six lines of
routing over existing methods, not a unit of its own.

- [ ] **Step 5: Run both suites**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test 2>&1 | tail -3
xcodebuild -scheme SkiVideoCore-iOS -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1
```

Expected: macOS up by five, iOS up by however many did not skip.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Route comparison transport actions by target"
```

---

### Task 2: The control bar and scrubber

**Files:**
- Create: `Sources/SkiVideoViewer/Shared/ComparisonControlBar.swift`
- Create: `Sources/SkiVideoViewer/Shared/ComparisonScrubber.swift`

**Interfaces:**
- Consumes: `ComparisonTarget`, `TransportAction`, `applyTransport(_:)`, `availableTargets` from Task 1; plus `layout`, `isSynced`, `hasTwoVideos`, `leftTime`, `rightTime`, `leftDuration`, `rightDuration`, `setSyncPoints()`, `returnToSyncPoints()`, `removeSync()`, `scrub(_:to:)`.
- Produces: `struct ComparisonControlBar: View` with `init(model: ComparisonModel)`; `struct ComparisonScrubber: View` with `init(model: ComparisonModel)`.

- [ ] **Step 1: Write the scrubber**

Create `Sources/SkiVideoViewer/Shared/ComparisonScrubber.swift`. It shows the
targeted clip's timeline; when the target is `.both`, dragging seeks both via
the model's synced path.

```swift
import SkiVideoCore
import SwiftUI

/// The timeline for whatever the control bar is targeting.
struct ComparisonScrubber: View {
    @ObservedObject var model: ComparisonModel

    @State private var scrubTime = 0.0
    @State private var isScrubbing = false

    private var side: ComparisonSide {
        model.target == .right ? .right : .left
    }

    private var duration: Double {
        side == .left ? model.leftDuration : model.rightDuration
    }

    private var currentTime: Double {
        isScrubbing ? scrubTime : (side == .left ? model.leftTime : model.rightTime)
    }

    var body: some View {
        Slider(
            value: Binding(
                get: { min(max(currentTime, 0), max(duration, 0.0001)) },
                set: { scrubTime = $0 }
            ),
            in: 0...max(duration, 0.0001),
            onEditingChanged: { editing in
                isScrubbing = editing
                if !editing { model.scrub(side, to: scrubTime) }
            }
        )
        .disabled(duration <= 0)
        .accessibilityLabel("Timeline")
    }
}
```

`scrub(_:to:)` already routes to synced behaviour when `isSynced`, so `.both`
needs no special case here — read the model to confirm before relying on it.

- [ ] **Step 2: Write the control bar**

Create `Sources/SkiVideoViewer/Shared/ComparisonControlBar.swift`.

```swift
import SkiVideoCore
import SwiftUI

/// Layout picker, target selector, transport, time and the sync anchor —
/// the one row that replaces the previous three transports.
struct ComparisonControlBar: View {
    @ObservedObject var model: ComparisonModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { controls }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) { layoutPicker; targetPicker; Spacer() }
                HStack(spacing: 16) { transport; Spacer(); timeLabel; anchorButton }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var controls: some View {
        layoutPicker
        targetPicker
        transport
        Spacer()
        timeLabel
        anchorButton
    }

    private var layoutPicker: some View {
        Picker("Layout", selection: $model.layout) {
            ForEach(ComparisonLayout.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 180)
    }

    private var targetPicker: some View {
        Picker("Controls", selection: $model.target) {
            ForEach(model.availableTargets) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: model.availableTargets.count == 3 ? 160 : 110)
    }

    private var transport: some View {
        HStack(spacing: 4) {
            transportButton("gobackward.5", "Back 5 seconds", .back5)
            transportButton("gobackward.minus", "Back 1 second", .back1)
            transportButton("playpause.fill", "Play or pause", .playPause)
            transportButton("goforward.plus", "Forward 1 second", .forward1)
            transportButton("goforward.5", "Forward 5 seconds", .forward5)
            transportButton("tortoise.fill", "Slow motion, quarter speed", .slow)
        }
    }

    private func transportButton(
        _ symbol: String,
        _ label: String,
        _ action: TransportAction
    ) -> some View {
        Button {
            model.applyTransport(action)
        } label: {
            Image(systemName: symbol)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
        .disabled(!model.hasTwoVideos)
    }

    private var timeLabel: some View {
        Text(Self.timecode(model.leftTime) + " / " + Self.timecode(model.leftDuration))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private var anchorButton: some View {
        Button {
            if model.isSynced { model.returnToSyncPoints() } else { model.setSyncPoints() }
        } label: {
            Image(systemName: model.isSynced ? "pin.fill" : "pin")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(model.isSynced ? "Return to sync points" : "Set sync points")
        .accessibilityLabel(model.isSynced ? "Return to sync points" : "Set sync points")
        .disabled(!model.hasTwoVideos)
        .contextMenu {
            if model.isSynced {
                Button("Clear sync", role: .destructive) { model.removeSync() }
            }
        }
    }

    private static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00.0" }
        let minutes = Int(seconds) / 60
        let remainder = seconds - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, remainder)
    }
}
```

`ViewThatFits` gives the spec's wrap-rather-than-shrink rule for free: the
single-row layout is tried first, and the two-row one is used when it does not
fit. Verify it behaves that way at 834pt in Task 4 — if `ViewThatFits` picks
badly, fall back to a width check via `GeometryReader` and say so.

`ComparisonTarget.title` comes from Task 1.

- [ ] **Step 3: Build both targets**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && xcodegen generate
xcodebuild -scheme SkiVideoViewer-macOS -destination 'platform=macOS' build 2>&1 | tail -2
xcodebuild -scheme SkiVideoViewer-iPad -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build 2>&1 | tail -2
```

Both new files are unreferenced until Task 3, so this only proves they compile.

- [ ] **Step 4: Confirm Shared/ stays clean**

```bash
cd SkiVideoViewer && grep -ln "import AppKit\|import UIKit" Sources/SkiVideoViewer/Shared/*.swift
```

Expected: only `SinglePlayerView.swift`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add the comparison control bar and scrubber"
```

---

### Task 3: The pane, the blend bar, and recomposing the view

**Files:**
- Create: `Sources/SkiVideoViewer/Shared/ComparisonPane.swift`
- Create: `Sources/SkiVideoViewer/Shared/OverlayBlendBar.swift`
- Modify: `Sources/SkiVideoViewer/Shared/ComparisonView.swift`

**Interfaces:**
- Consumes: everything from Tasks 1-2; `SinglePlayerView`, `OverlayPlayerStack`, `chooseVideo(side:)`, `leftName`, `rightName`.
- Produces: `struct ComparisonPane: View` with `init(model: ComparisonModel, side: ComparisonSide)`; `struct OverlayBlendBar: View` with `init(model: ComparisonModel)`.

- [ ] **Step 1: Write the pane**

The filename sits over the letterbox, costing no layout height; an empty pane
puts its Choose button in the middle of itself rather than in a header row.

```swift
import SkiVideoCore
import SwiftUI

/// One clip in side-by-side layout: the video, its name over the letterbox,
/// and — when empty — the control that loads it.
struct ComparisonPane: View {
    @ObservedObject var model: ComparisonModel
    let side: ComparisonSide

    private var name: String {
        side == .left ? model.leftName : model.rightName
    }

    private var isLoaded: Bool {
        (side == .left ? model.leftPlayer : model.rightPlayer).currentItem != nil
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            SinglePlayerView(player: side == .left ? model.leftPlayer : model.rightPlayer)

            if isLoaded {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(8)
                    .accessibilityLabel("\(side == .left ? "Left" : "Right") clip: \(name)")
            } else {
                Button("Choose Clip") { Task { await model.chooseVideo(side: side) } }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
```

Read `ComparisonModel` before trusting `leftName`/`rightName` and the
`currentItem` check — if the model exposes a cleaner "is this side loaded"
signal, use it and say so.

- [ ] **Step 2: Write the blend bar**

```swift
import SkiVideoCore
import SwiftUI

/// Overlay-only: how strongly the top clip is drawn, and in which mode.
struct OverlayBlendBar: View {
    @ObservedObject var model: ComparisonModel

    var body: some View {
        HStack(spacing: 16) {
            Text("Left").font(.caption).foregroundStyle(.secondary)
            Slider(value: $model.overlayOpacity, in: 0...1)
                .disabled(model.blend == .difference)
                .accessibilityLabel("Blend between left and right")
            Text("Right").font(.caption).foregroundStyle(.secondary)

            Picker("Blend mode", selection: $model.blend) {
                ForEach(OverlayBlend.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
        }
        .padding(.horizontal, 12)
    }
}
```

The slider is disabled in difference mode because `topLayerOpacity` forces 1.0
there — an enabled control that does nothing is exactly what this redesign is
removing.

- [ ] **Step 3: Recompose ComparisonView**

Replace the file's body with composition only. Delete `layoutPicker`,
`overlayControls`, `videoPane`, `paneHeader`, `paneTransport`,
`synchronizedControls`, and the four `@State` scrub properties. Keep the
existing `init(initialLeftVideo:openLibrary:input:folderPicker:closeWindow:)`
signature unchanged — `ComparisonWindowController` and the iPad presenter both
call it.

```swift
    var body: some View {
        VStack(spacing: 0) {
            switch model.layout {
            case .sideBySide:
                HStack(spacing: 1) {
                    ComparisonPane(model: model, side: .left)
                    Divider().frame(width: 1)
                    ComparisonPane(model: model, side: .right)
                }
            case .overlay:
                OverlayPlayerStack(
                    bottomPlayer: model.leftPlayer,
                    topPlayer: model.rightPlayer,
                    topOpacity: model.topLayerOpacity,
                    blend: model.blend
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if model.layout == .overlay {
                OverlayBlendBar(model: model)
            }
            ComparisonScrubber(model: model)
                .padding(.horizontal, 12)
            ComparisonControlBar(model: model)
        }
        #if os(macOS)
        .frame(minWidth: 1000, minHeight: 680)
        #endif
        .onDisappear { model.close() }
    }
```

`Divider().frame(width: 1)` is deliberate: the review of the previous layout
found a bare `Divider()` inside an `HStack` is vertically greedy and squeezes
the video. Constrain it.

**Close:** macOS drops it — the window has a close button. iPad needs one,
because a full-screen cover has no chrome of its own. Overlay it on the video
rather than giving it a row:

```swift
        #if os(iOS)
        .overlay(alignment: .topLeading) {
            Button {
                closeWindow()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
                    .background(.thinMaterial, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(12)
            .accessibilityLabel("Close comparison")
        }
        #endif
```

- [ ] **Step 4: Build, test, and count the rows**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && xcodegen generate && swift test 2>&1 | tail -3
xcodebuild -scheme SkiVideoViewer-macOS -destination 'platform=macOS' build 2>&1 | tail -2
xcodebuild -scheme SkiVideoViewer-iPad -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build 2>&1 | tail -2
./build_app.sh
```

- [ ] **Step 5: Confirm the file shrank**

```bash
cd SkiVideoViewer && wc -l Sources/SkiVideoViewer/Shared/ComparisonView.swift
```

Expected: roughly 60-80 lines, down from 290. If it is still over 120, something
did not move out — say which and why.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Recompose the comparison screen around one control bar"
```

---

### Task 4: Prove it on the simulator, at both widths

**Files:**
- Modify: `Tests/SkiVideoViewerUITests/CompareOnIPadUITests.swift` (or a sibling)

- [ ] **Step 1: Extend the UI tests**

Reuse the existing picker-dismissal helper from `CompareOnIPadUITests` — without
it these tests pass while doing nothing. Assert on accessibility labels, never
on pixel positions.

```swift
    func testTheControlBarOffersOnlyPerSideTargetsBeforeSyncing() throws {
        let app = launchPastTheFolderPicker()
        app.buttons["Compare Videos…"].tap()

        XCTAssertTrue(app.buttons["Left"].waitForExistence(timeout: 5),
                      "the target selector must offer Left while aligning")
        XCTAssertTrue(app.buttons["Right"].exists)
        XCTAssertFalse(app.buttons["Both"].exists,
                       "Both cannot work before sync points are set")
    }

    func testTheAnchorButtonAdvertisesSettingSyncPoints() throws {
        let app = launchPastTheFolderPicker()
        app.buttons["Compare Videos…"].tap()

        XCTAssertTrue(
            app.buttons["Set sync points"].waitForExistence(timeout: 5),
            "the anchor must say what it does before anything is synced"
        )
    }

    func testTheTransportIsPresentAndDisabledWithoutClips() throws {
        let app = launchPastTheFolderPicker()
        app.buttons["Compare Videos…"].tap()

        let playPause = app.buttons["Play or pause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        XCTAssertFalse(playPause.isEnabled,
                       "transport must be disabled until two clips are loaded")
    }
```

`launchPastTheFolderPicker()` is the existing helper's name — read
`CompareOnIPadUITests` and use whatever it is actually called. If loading two
clips from a UI test proves impractical, say so and note which assertions that
leaves uncovered rather than faking them.

- [ ] **Step 2: Screenshot at 834pt portrait**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd /Users/ulfnielsen/Ski/script && ./scripts/ipad-smoke.sh
```

Then drive to the comparison screen and capture. **Read the screenshot
yourself.** Confirm: the bar fits or wraps to exactly two rows, no control is
clipped, and every touch target looks at least 44pt.

- [ ] **Step 3: Screenshot at 744pt — iPad mini**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd /Users/ulfnielsen/Ski/script && ./scripts/ipad-smoke.sh "iPad mini (A17 Pro)"
```

Nothing narrower has been tested at any point in this project. If the bar breaks
here, fix it — do not declare success on the 11-inch alone.

- [ ] **Step 4: Count the chrome**

From the screenshots, count rows of chrome in both layouts. The spec's claim is
side-by-side ≤ 2 and overlay ≤ 3. Report the actual numbers. If they are higher,
say so plainly rather than rounding down.

- [ ] **Step 5: Run every gate**

All six from the Global Constraints table.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Cover the redesigned comparison controls end to end"
```

---

## Done when

- Side-by-side shows at most two rows of chrome; overlay at most three —
  measured from screenshots, not asserted.
- One transport drives whichever target is selected; `Both` appears only once
  sync points are set.
- `ComparisonView.swift` is under ~80 lines and the four new views each do one
  thing.
- `Shared/` still has `SinglePlayerView.swift` as its only AppKit/UIKit importer.
- All six gates pass, both unit suites having grown.
- Verified at 834pt and 744pt.

## Needs a human

**macOS is deliberately changed and cannot be driven from this environment.**
Before merging, someone must open Compare on the Mac and confirm: the bar reads
correctly, hover tooltips restore the words the icons replaced, ⌘Return still
sets sync points, the window close button is a sufficient replacement for the
deleted Close button, and Overlay's Blend and Difference modes still render.

## Coordination

The `landmark-align` worktree restructures the same comparison code. Decide
merge order before either lands — reconciling two independent restructurings
after the fact is materially harder than sequencing them.
