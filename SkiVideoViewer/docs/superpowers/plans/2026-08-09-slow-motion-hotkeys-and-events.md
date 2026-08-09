# Cmd+Arrow Slow Motion, Matching Comparison Hotkeys, and Event Grouping — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move slow motion from long-press onto ⌘+Arrow, give the comparison window the same arrow hotkeys as the viewer, and group a multi-event folder by event instead of merging athletes across events.

**Architecture:** A new `SlowMotionHold` in `SkiVideoCore` owns held slow playback over one or more `AVPlayer`s and is driven by both `ViewerModel` and `ComparisonModel`. The `PlaybackIntent` vocabulary swaps `.scrubBegan`/`.scrubEnded` for `.seek`/`.slowMotionBegan`/`.slowMotionEnded`. A new `LibraryGrouping` turns `(video, athlete, event)` triples into `AthleteGroup`s and is shared by the local scan and the Google Drive scan, so the two cannot disagree about what an athlete is.

**Tech Stack:** Swift 6.1 toolchain, `swiftLanguageModes: [.v5]`, SwiftPM, AVFoundation, AppKit (macOS seam), SwiftUI, XCTest.

## Global Constraints

- Platforms: `.macOS(.v13)`, `.iOS(.v17)`. `SkiVideoCore` must stay platform-agnostic — `CorePurityTests` fails the build if a core source names AppKit or UIKit.
- Access levels stay narrow: `public` marks only what the app target touches. Anything used solely inside `SkiVideoCore` or by tests stays internal and is reached with `@testable import SkiVideoCore`.
- Slow-motion rate: `0.35` forward, `-0.35` reverse. Reverse fallback step: `0.08` s.
- Double-tap window: `0.38` s. Double-tap seek: `5.0` s. Single seek: `1.0` s.
- Status strings are asserted on by tests; keep the existing wording exactly — `"Forward 1 seconds"`, `"Forward 5 seconds"`, `"Slow forward"`, `"Slow backward"`, `"Playing"`, `"Paused"`.
- **Test command.** A bare `swift test` fails on this machine with `no such module 'XCTest'` — `xcode-select -p` points at `/Library/Developer/CommandLineTools`, which ships no XCTest. Always run:
  ```bash
  swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  ```
  Filtered runs need the same prefix: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter <Suite>`. A full run is ~145 s and the baseline is **406 tests, 0 failures, 2 skipped**. Every task ends green before its commit.
- Commit messages: imperative mood, no `feat:`/`fix:` prefixes — match the existing log (`Let Drive import share the library's format list`). End each with:
  ```
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  ```

## File Structure

**Create:**
- `Sources/SkiVideoCore/SlowMotionHold.swift` — held slow playback over a set of players. Rate, reverse fallback, restore-on-release. No status strings, no model state.
- `Sources/SkiVideoCore/LibraryGrouping.swift` — pure `(video, athlete, event) → [AthleteGroup]`. Owns the id scheme, the folding rule, and the sort order.
- `Tests/SkiVideoCoreTests/SlowMotionHoldTests.swift`
- `Tests/SkiVideoCoreTests/LibraryGroupingTests.swift`

**Modify:**
- `Sources/SkiVideoCore/Seams.swift` — the intent vocabulary.
- `Sources/SkiVideoCore/ViewerModel.swift` — drop the hold state machine, adopt `SlowMotionHold`, add `events`, teach `clipDescription` and `comparisonLibrary` about events.
- `Sources/SkiVideoCore/ComparisonModel.swift` — adopt `SlowMotionHold`, handle the new intents.
- `Sources/SkiVideoCore/SortingModel.swift` — rename two intent cases.
- `Sources/SkiVideoCore/VideoLibrary.swift` — `AthleteGroup.event`, scan through `LibraryGrouping`.
- `Sources/SkiVideoCore/GoogleDriveSupport.swift` — scan through `LibraryGrouping`.
- `Sources/SkiVideoViewer/macOS/AppKitInputSource.swift` — ⌘ gating, `.seek` on key-down, hold begin/end.
- `Sources/SkiVideoViewer/Shared/ContentView.swift` — sectioned sidebar.
- Tests: `AppKitInputSourceTests`, `AppKitInputToModelTests`, `ViewerModelIntentTests`, `CorePurityTests`, `ComparisonModelTests`, `VideoLibraryTests`.

**Note on the ⌘ key-up risk.** The spec flagged that AppKit withholds `keyUp` while ⌘ is down. This plan removes it as a gate rather than answering it first: Task 4 wires **both** end paths (arrow key-up *and* `flagsChanged` dropping ⌘), so the hold always ends when ⌘ is released even if key-up never arrives. The only degraded case would be releasing the arrow while holding ⌘ down. Task 9 is a manual check in the real app that settles which path actually fires.

---

### Task 1: `SlowMotionHold`

A self-contained unit with no callers yet. Nothing else changes, so this task is safe to review in isolation.

**Files:**
- Create: `Sources/SkiVideoCore/SlowMotionHold.swift`
- Test: `Tests/SkiVideoCoreTests/SlowMotionHoldTests.swift`

**Interfaces:**
- Consumes: `ScrubDirection` from `Sources/SkiVideoCore/Seams.swift` (already exists, unchanged).
- Produces: `SlowMotionHold` (internal, `@MainActor`, `final class`) with `init()`, `func begin(_ direction: ScrubDirection, players: [AVPlayer])`, `func end()`, `var isActive: Bool { get }`. Tasks 3 and 4 drive exactly these.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SkiVideoCoreTests/SlowMotionHoldTests.swift`:

```swift
import AVFoundation
import XCTest
@testable import SkiVideoCore

/// `SlowMotionHold` against real media. `canPlayReverse` is only meaningful on
/// an item that actually loaded, so the reversible-path test needs a real clip
/// — a zero-byte file reports `false` forever, which is the *fallback* path and
/// is tested separately with exactly such a file.
@MainActor
final class SlowMotionHoldTests: XCTestCase {
    private var temporaryDirectory: URL?

    override func tearDown() {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        super.tearDown()
    }

    private func makeDirectory() throws -> URL {
        if let temporaryDirectory { return temporaryDirectory }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryDirectory = root
        return root
    }

    /// A player holding a real, seekable clip.
    private func makeRealPlayer(seconds: Double = 20) throws -> AVPlayer {
        let url = try makeRealVideoFile(
            in: try makeDirectory(),
            name: "\(UUID().uuidString).mov",
            seconds: seconds
        )
        let player = AVPlayer(url: url)
        waitUntil("the item must become ready") {
            player.currentItem?.status == .readyToPlay
        }
        return player
    }

    /// A player whose item can never load, so `canPlayReverse` stays false.
    private func makeUnloadablePlayer() throws -> AVPlayer {
        let url = try makeDirectory().appendingPathComponent("\(UUID().uuidString).mov")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return AVPlayer(url: url)
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 20, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), message)
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testForwardPlaysAtTheSlowRate() throws {
        let player = try makeRealPlayer()
        let hold = SlowMotionHold()

        hold.begin(.forward, players: [player])

        XCTAssertTrue(hold.isActive)
        XCTAssertEqual(player.rate, 0.35, accuracy: 0.001)
    }

    func testForwardDrivesEveryPlayerItIsGiven() throws {
        let left = try makeRealPlayer()
        let right = try makeRealPlayer()
        let hold = SlowMotionHold()

        hold.begin(.forward, players: [left, right])

        XCTAssertEqual(left.rate, 0.35, accuracy: 0.001)
        XCTAssertEqual(right.rate, 0.35, accuracy: 0.001)
    }

    func testBackwardPlaysInReverseWhenTheItemAllowsIt() throws {
        let player = try makeRealPlayer()
        waitUntil("the fixture must be reversible, or this test proves nothing") {
            player.currentItem?.canPlayReverse == true
        }
        let hold = SlowMotionHold()

        hold.begin(.backward, players: [player])

        XCTAssertEqual(player.rate, -0.35, accuracy: 0.001)
    }

    /// The fallback the viewer has always had: pause, and step the playhead
    /// back on a timer. Asserting on the rate alone would pass with the timer
    /// never scheduled, so this asserts the playhead actually moved.
    func testBackwardStepsThePlayheadWhenTheItemCannotPlayInReverse() throws {
        let player = try makeUnloadablePlayer()
        XCTAssertNotEqual(player.currentItem?.canPlayReverse, true,
                          "premise: this item must not be reversible")
        let hold = SlowMotionHold()

        hold.begin(.backward, players: [player])

        XCTAssertEqual(player.rate, 0, "the fallback must leave the player paused")
        XCTAssertTrue(hold.isActive)
        pump(0.3)
        XCTAssertNotNil(hold.lastFallbackTarget,
                        "the timer must have fired and asked for a target")
    }

    func testEndRestoresThePriorRate() throws {
        let player = try makeRealPlayer()
        player.playImmediately(atRate: 1)
        let hold = SlowMotionHold()

        hold.begin(.forward, players: [player])
        XCTAssertEqual(player.rate, 0.35, accuracy: 0.001)
        hold.end()

        XCTAssertEqual(player.rate, 1, accuracy: 0.001)
        XCTAssertFalse(hold.isActive)
    }

    func testEndLeavesAPausedPlayerPaused() throws {
        let player = try makeRealPlayer()
        let hold = SlowMotionHold()

        hold.begin(.forward, players: [player])
        hold.end()

        XCTAssertEqual(player.rate, 0, "a player that was paused must not start playing")
    }

    /// `end()` is called from app-resign, window close and clip change as well
    /// as from the key-up, so it must tolerate being called when nothing is
    /// held and twice in a row.
    func testEndIsIdempotent() throws {
        let player = try makeRealPlayer()
        let hold = SlowMotionHold()

        hold.end()
        hold.begin(.forward, players: [player])
        hold.end()
        hold.end()

        XCTAssertEqual(player.rate, 0)
        XCTAssertFalse(hold.isActive)
    }

    /// Auto-repeat delivers more than one begin for one physical press. A
    /// second begin must not overwrite the captured rate, or `end()` would
    /// restore 0.35 instead of the rate the operator was watching at.
    func testASecondBeginIsIgnoredWhileAHoldIsActive() throws {
        let player = try makeRealPlayer()
        player.playImmediately(atRate: 1)
        let hold = SlowMotionHold()

        hold.begin(.forward, players: [player])
        hold.begin(.backward, players: [player])
        XCTAssertEqual(player.rate, 0.35, accuracy: 0.001,
                       "the second begin must not change direction")
        hold.end()

        XCTAssertEqual(player.rate, 1, accuracy: 0.001,
                       "the captured rate must survive the second begin")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SlowMotionHoldTests`
Expected: FAIL to compile — `cannot find 'SlowMotionHold' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/SkiVideoCore/SlowMotionHold.swift`:

```swift
import AVFoundation

/// One direction of held slow playback over a set of players.
///
/// Internal, and deliberately ignorant of both models: it takes the players as
/// an argument to `begin` rather than holding a reference, so the comparison
/// window can hand it one side, the other, or the locked pair from a single
/// call site. It sets no status strings either — the two models word theirs
/// differently, and a shared unit that owned the wording would have to know
/// which model it was serving.
///
/// This is `ViewerModel`'s former `startHold`/`resumeHeldPlayback`/`endArrow`
/// machinery, lifted so `ComparisonModel` can have the same behaviour rather
/// than a second, subtly different copy of it.
@MainActor
final class SlowMotionHold {
    /// Matches the rate the viewer's long-press has always used.
    static let rate: Float = 0.35

    /// Both the timer period and the distance stepped, so the fallback moves at
    /// roughly 1× in reverse — which is what makes it read as playback rather
    /// than as a series of jumps.
    private static let stepInterval: TimeInterval = 0.08

    private var players: [AVPlayer] = []
    private var ratesBeforeHold: [Float] = []
    private var reverseTimer: Timer?

    /// The last target the reverse fallback asked for. Exposed so a test can
    /// prove the timer fired without racing a real seek's completion, and nil
    /// until the fallback path runs at least once.
    private(set) var lastFallbackTarget: Double?

    var isActive: Bool { !players.isEmpty }

    /// A second `begin` while a hold is active is ignored. Auto-repeat delivers
    /// several key-downs for one physical press, and overwriting
    /// `ratesBeforeHold` with the slow rate would make `end()` restore 0.35×
    /// instead of the rate the operator was watching at.
    func begin(_ direction: ScrubDirection, players: [AVPlayer]) {
        guard !isActive, !players.isEmpty else { return }
        self.players = players
        ratesBeforeHold = players.map(\.rate)

        switch direction {
        case .forward:
            for player in players {
                player.playImmediately(atRate: Self.rate)
            }
        case .backward:
            // All-or-nothing. A synced pair with one side running natively in
            // reverse and the other stepping on a timer would drift apart,
            // which is the one thing the comparison window exists to prevent.
            let everyItemCanReverse = players.allSatisfy {
                $0.currentItem?.canPlayReverse == true
            }
            if everyItemCanReverse {
                for player in players {
                    player.playImmediately(atRate: -Self.rate)
                }
            } else {
                for player in players {
                    player.pause()
                }
                let timer = Timer(timeInterval: Self.stepInterval, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.stepBack()
                    }
                }
                reverseTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }

    /// Idempotent: the key-up is not the only caller. App-resign, window close
    /// and every library change call this too, and a hold may well not be
    /// running when they do.
    func end() {
        guard isActive else { return }
        reverseTimer?.invalidate()
        reverseTimer = nil
        for (player, rate) in zip(players, ratesBeforeHold) {
            player.pause()
            if rate != 0 {
                player.playImmediately(atRate: rate)
            }
        }
        players = []
        ratesBeforeHold = []
    }

    private func stepBack() {
        for player in players {
            let current = player.currentTime().seconds
            let safeCurrent = current.isFinite ? current : 0
            let target = max(0, safeCurrent - Self.stepInterval)
            lastFallbackTarget = target
            player.seek(
                to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SlowMotionHoldTests`
Expected: PASS, 9 tests.

- [ ] **Step 5: Run the whole suite and commit**

```bash
swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
git add Sources/SkiVideoCore/SlowMotionHold.swift Tests/SkiVideoCoreTests/SlowMotionHoldTests.swift
git commit -m "Extract held slow playback into a unit both screens can drive

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Swap the intent vocabulary

`PlaybackIntent`'s cases and all four consumers change together — Swift will not compile a partial rename, and a reviewer would reject or accept the vocabulary as one decision. Behaviour is deliberately unchanged in this task: `ViewerModel` keeps its existing hold machinery and simply reaches it from the new cases. Task 3 replaces the machinery; Task 4 wires the ⌘ keys.

**Files:**
- Modify: `Sources/SkiVideoCore/Seams.swift:25-35`
- Modify: `Sources/SkiVideoCore/ViewerModel.swift:103-119`
- Modify: `Sources/SkiVideoCore/ComparisonModel.swift:325-336`
- Modify: `Sources/SkiVideoCore/SortingModel.swift:150-156`
- Modify: `Sources/SkiVideoViewer/macOS/AppKitInputSource.swift`
- Modify: `Sources/SkiVideoViewer/macOS/SortingWindowController.swift:39`
- Test: `Tests/SkiVideoCoreTests/CorePurityTests.swift:43-51`, `Tests/SkiVideoCoreTests/ViewerModelIntentTests.swift`, `Tests/SkiVideoViewerTests/AppKitInputSourceTests.swift`, `Tests/SkiVideoCoreTests/ComparisonModelTests.swift`, `Tests/SkiVideoViewerTests/AppKitInputToModelTests.swift`

**Every existing use of the removed API, found by grep — the compiler will point at all of these:**

| File | What |
| --- | --- |
| `Tests/SkiVideoCoreTests/ComparisonModelTests.swift` | 8 `.scrubBegan`/`.scrubEnded` emissions at lines 187, 200, 203, 212, 215, 246, 247, 265 |
| `Tests/SkiVideoViewerTests/AppKitInputToModelTests.swift:62` | `holdThreshold: 60` |
| `Tests/SkiVideoCoreTests/ViewerTransportTests.swift` | 4 direct `model.beginArrow`/`model.endArrow` calls — **left alone in this task**, because `beginArrow`/`endArrow` still exist until Task 3. Task 3 owns them. |

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `PlaybackIntent.seek(ScrubDirection)`, `.slowMotionBegan(ScrubDirection)`, `.slowMotionEnded`. `.scrubBegan`/`.scrubEnded` no longer exist. Tasks 3 and 4 handle exactly these three.

- [ ] **Step 1: Update the intent enum**

In `Sources/SkiVideoCore/Seams.swift`, replace the two scrub cases:

```swift
public enum PlaybackIntent: Sendable {
    case togglePlayback
    case clip(Step)
    case athlete(Step)
    /// A discrete jump, emitted on key-down. The models decide how far — the
    /// viewer's `performArrowTap` reads ±1s or ±5s out of its double-tap
    /// window, the sorting window always seeks ±5s.
    case seek(ScrubDirection)
    /// Slow playback for as long as the keys are held.
    ///
    /// No direction on the end and no `performTap`: releasing a hold is one
    /// action with one meaning. `.scrubEnded` carried `performTap` only to tell
    /// a release (which should seek) from a cancellation (which should not),
    /// and seeks are now their own intent.
    case slowMotionBegan(ScrubDirection)
    case slowMotionEnded
    case focusAthleteSearch
    case openFolder
}
```

- [ ] **Step 2: Point the three models at the new cases**

`Sources/SkiVideoCore/ViewerModel.swift`, in `handle(_:)`:

```swift
        case let .seek(direction):
            endArrow(performTap: false)
            performArrowTap(direction)
        case let .slowMotionBegan(direction):
            beginArrow(direction)
        case .slowMotionEnded:
            endArrow(performTap: false)
```

`beginArrow` keeps its `holdWorkItem`/`holdThreshold` body for now, but change the two `DispatchQueue`-scheduled lines so a hold starts immediately rather than after the threshold — a ⌘ press is unambiguous, there is nothing to wait to disambiguate:

```swift
    func beginArrow(_ direction: ScrubDirection) {
        guard currentVideo != nil, heldDirection == nil else { return }
        heldDirection = direction
        holdStarted = false
        startHold()
    }
```

Delete `holdWorkItem`, its cancellation in `endArrow`, the `holdThreshold` stored property **and** the `holdThreshold:` initializer parameter. Step 4 fixes the two `ViewerModel(...)` call sites in `ViewerModelIntentTests` that pass it. Do not leave an unused parameter behind.

`Sources/SkiVideoCore/ComparisonModel.swift`, in `handle(_:)`:

```swift
    func handle(_ intent: PlaybackIntent) {
        switch intent {
        case .togglePlayback:
            applyTransport(.playPause)
        case .seek(.backward):
            applyTransport(.back1)
        case .seek(.forward):
            applyTransport(.forward1)
        default:
            break
        }
    }
```

`Sources/SkiVideoCore/SortingModel.swift`, in `handle(_:)`: rename `case .scrubBegan(.backward)` → `case .seek(.backward)` and `case .scrubBegan(.forward)` → `case .seek(.forward)`. Update the doc comment above it to say the window acts on `.seek` and ignores the slow-motion pair.

- [ ] **Step 3: Point the input source at the new cases**

In `Sources/SkiVideoViewer/macOS/AppKitInputSource.swift`, keep the existing key handling shape and swap the emitted intents. Bare arrows now fire on key-down and emit nothing on key-up:

```swift
        if event.type == .keyUp {
            switch event.keyCode {
            case 123 where heldDirection == .backward,
                 124 where heldDirection == .forward:
                heldDirection = nil
                emit(.slowMotionEnded)
                return true
            default:
                return false
            }
        }
```

```swift
        case 123: // Left Arrow
            emit(.seek(.backward))
        case 124: // Right Arrow
            emit(.seek(.forward))
```

Delete the `heldDirection` branches from those two cases, but **keep `arrowsRepeat`** — see the correction below.

> **Corrected 2026-08-09, after Task 2's review.** This plan originally said to delete `arrowsRepeat` on the reasoning that "a repeat is just another key-down, so its effect is now automatic". That holds for the sorting window, whose `SortingModel.seek(±5)` is stateless. It is wrong for the viewer, whose `performArrowTap` is stateful: its 0.38 s double-tap detector cannot tell an auto-repeat from a deliberate second press, and consecutive repeats arrive ~90 ms apart — so a held arrow alternates +1 s / +5 s indefinitely, moving ~31 s of media per 1.3 s held with the status line strobing. Measured by simulating `performArrowTap` at the system repeat rate (0.375 s initial delay, 0.090 s thereafter).
>
> `arrowsRepeat` therefore stays, defaulting to false, still gating auto-repeat on keyCodes 123/124 only. `SortingWindowController` keeps `input.arrowsRepeat = true`; the viewer and the comparison window stay at the default, so a held arrow seeks once and goes quiet. Its doc comment must be rewritten rather than restored — the old text justified the flag by the hold state machine that `.scrubBegan` armed, which no longer exists. The reason now is `performArrowTap`'s statefulness, with the numbers above.
>
> Coverage: one test proving a default source stays silent on arrow repeats (the runaway's regression guard), one proving an opted-in source emits a `.seek` per repeat (the sorting window's fast-scan).

Update `cancelHold()` to emit `.slowMotionEnded` instead of `.scrubEnded`.

- [ ] **Step 4: Update the tests to the new vocabulary**

`Tests/SkiVideoCoreTests/CorePurityTests.swift`, in `testSeamsAreReachableFromTests`:

```swift
        let intents: [PlaybackIntent] = [
            .togglePlayback,
            .clip(.next),
            .athlete(.previous),
            .seek(.forward),
            .slowMotionBegan(.forward),
            .slowMotionEnded,
            .focusAthleteSearch,
            .openFolder,
        ]
        XCTAssertEqual(intents.count, 8)
```

`Tests/SkiVideoCoreTests/ViewerModelIntentTests.swift`:
- Drop `holdThreshold: 0.02` from both `ViewerModel(...)` constructions.
- Replace the scrub pairs with single `.seek` emissions:

```swift
    func testSingleTapSeeksOneSecond() throws {
        let (model, input, _) = try makeModel()

        input.emit(.seek(.forward))

        XCTAssertEqual(model.lastSeekOffset ?? .nan, 1.0, accuracy: 0.0001)
        XCTAssertEqual(model.status, "Forward 1 seconds")
    }

    func testDoubleTapWithinWindowSeeksFiveSeconds() throws {
        let (model, input, clock) = try makeModel()

        input.emit(.seek(.forward))
        clock.advance(by: 0.2)   // inside the 0.38s window
        input.emit(.seek(.forward))

        XCTAssertEqual(model.lastSeekOffset ?? .nan, 5.0, accuracy: 0.0001)
        XCTAssertEqual(model.status, "Forward 5 seconds")
    }

    func testTapsOutsideWindowAreNotTreatedAsDoubleTap() throws {
        let (model, input, clock) = try makeModel()

        input.emit(.seek(.forward))
        clock.advance(by: 0.5)   // outside the 0.38s window
        input.emit(.seek(.forward))

        XCTAssertEqual(model.lastSeekOffset ?? .nan, 1.0, accuracy: 0.0001)
        XCTAssertEqual(model.status, "Forward 1 seconds")
    }
```

- Replace `testHoldEntersSlowScrub` — no sleeping, because the hold now starts on the intent rather than after a threshold:

```swift
    func testSlowMotionBeganEntersSlowPlaybackImmediately() throws {
        let (model, input, _) = try makeModel()

        input.emit(.slowMotionBegan(.forward))

        XCTAssertEqual(model.status, "Slow forward")
    }
```

- Delete `testCancelledScrubDoesNotSeek`; `.slowMotionEnded` cannot seek, so there is nothing left to assert. Replace it with:

```swift
    func testSlowMotionEndedDoesNotSeek() throws {
        let (model, input, _) = try makeModel()

        input.emit(.slowMotionBegan(.backward))
        input.emit(.slowMotionEnded)

        XCTAssertNil(model.lastSeekOffset, "releasing a hold must not seek")
    }
```

`Tests/SkiVideoViewerTests/AppKitInputSourceTests.swift`:
- Replace `testArrowDownThenUpEmitsScrubPairWithTap` with:

```swift
    func testBareArrowSeeksOnKeyDownAndIsSilentOnKeyUp() {
        let source = AppKitInputSource()
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }

        XCTAssertTrue(source.handle(key(124)))
        XCTAssertEqual(captured.count, 1)
        guard case let .seek(direction) = captured[0] else {
            return XCTFail("expected a seek, got \(captured)")
        }
        XCTAssertEqual(direction, .forward)

        XCTAssertFalse(
            source.handle(key(124, type: .keyUp)),
            "a bare arrow's release is not ours to consume"
        )
        XCTAssertEqual(captured.count, 1)
    }
```

**Delete** these five, all of which assert on the bare-arrow hold that no longer exists. Task 4 restores equivalent coverage against the ⌘ keys:
`testDisablingMidHoldCancelsWithoutTap`, `testSecondArrowPressedMidHoldNeitherStartsNorEndsAScrub`, `testOptedInSourceDeliversArrowsThroughAFocusedTextField`, `testOptedInSourceEmitsAScrubBeganForEveryArrowRepeat`, `testDefaultSourceStillSuppressesArrowRepeats`.

**Keep unchanged:** `testSpaceEmitsTogglePlayback`, `testArrowsEmitClipSteps`, `testPageKeysEmitAthleteSteps`, `testFocusedTextFieldSwallowsEverythingByDefault`, `testOptedInSourceStillLetsEveryOtherKeyReachAFocusedTextField`, `testOptedInSourceBehavesNormallyWithoutTextFieldFocus`, `testKeyUpWithoutMatchingKeyDownEmitsNothing`, `testModifiedKeysAreIgnored`, `testAutorepeatDoesNotRetrigger`, `testDisabledSourceEmitsNothing`, `testSourceDeallocatesSoItsTeardownIsReached`, `testUnhandledKeyIsNotConsumed`.

**Keep with one edit:** `testArrowRepeatOptInDoesNotUnlockRepeatsForAnyOtherKey` — drop its `source.arrowsRepeat = true` line; the rest still holds.

**Add** these two. The first is the sorting window's bypass, which still needs proving now that it carries seeks instead of scrubs:

```swift
    func testOptedInSourceDeliversArrowSeeksThroughAFocusedTextField() {
        let window = makeWindowWithFocusedTextView()
        let source = AppKitInputSource()
        source.arrowsBypassTextFieldFocus = true
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }

        XCTAssertTrue(source.handle(key(123, windowNumber: window.windowNumber)))
        XCTAssertTrue(source.handle(key(124, windowNumber: window.windowNumber)))

        XCTAssertEqual(captured.count, 2)
        guard captured.count == 2,
              case let .seek(first) = captured[0],
              case let .seek(second) = captured[1]
        else {
            return XCTFail("expected two seeks, got \(captured)")
        }
        XCTAssertEqual(first, .backward)
        XCTAssertEqual(second, .forward)
    }
```

- And the repeat behaviour the sorting window depends on, now without a flag:

```swift
    /// The sorting window fast-scans a clip by holding an arrow. That used to
    /// need an `arrowsRepeat` opt-in because the arrows armed a hold; now that
    /// a bare arrow seeks on key-down, a repeat is just another key-down and
    /// the behaviour falls out. This pins that it really does.
    func testHeldArrowRepeatsSeek() {
        let source = AppKitInputSource()
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }

        XCTAssertTrue(source.handle(key(124)))
        XCTAssertTrue(source.handle(key(124, isARepeat: true)))
        XCTAssertTrue(source.handle(key(124, isARepeat: true)))

        XCTAssertEqual(captured.count, 3, "each repeat is another seek: \(captured)")
    }
```

- [ ] **Step 5: Update `ComparisonModelTests` to the new vocabulary**

Five call sites in `Tests/SkiVideoCoreTests/ComparisonModelTests.swift`. `.seek` carries the same meaning `.scrubBegan` did for this model, so these are renames plus one deletion:

| Test | Change |
| --- | --- |
| `testScrubKeysFollowTheTargetWhileAligning` (line 187) | `.scrubBegan(.forward)` → `.seek(.forward)`; rename the test to `testSeekKeysFollowTheTargetWhileAligning` |
| `testScrubBeganIntentsSeekBothPlayersOneSecondInTheEmittedDirection` (lines 200, 203) | both `.scrubBegan(x)` → `.seek(x)`; rename to `testSeekIntentsMoveBothPlayersOneSecondInTheEmittedDirection` |
| `testScrubEndedIsIgnoredBecauseTheWindowNeverHadHoldToScrub` (lines 212, 215) | **Delete.** It asserts that a release does not seek a second time; `.scrubEnded` no longer exists and `.seek` has no release. Task 4 gives `.slowMotionEnded` its own coverage. |
| `testScrubIntentsDoNotTrapWithNoVideosLoaded` (lines 246, 247) | both → `.seek(x)`; rename to `testSeekIntentsDoNotTrapWithNoVideosLoaded` |
| `testClosingDetachesTheInputSource` (line 265) | `.scrubBegan(.forward)` → `.seek(.forward)` |

- [ ] **Step 6: Update `AppKitInputToModelTests` and check nothing else references the old API**

Run: `swift build --build-tests 2>&1 | grep -i "error" | head -30`

In `Tests/SkiVideoViewerTests/AppKitInputToModelTests.swift`: drop `holdThreshold: 60` from the `ViewerModel(...)` at line 62, and delete `testReleasingASecondArrowMidHoldDoesNotEndTheScrub` — Task 4 replaces it with the ⌘ equivalent. Translate any other reported reference to the new vocabulary.

`Tests/SkiVideoCoreTests/ViewerTransportTests.swift` still calls `model.beginArrow`/`model.endArrow` in three tests. Those methods still exist in this task, so **leave that file alone** — Task 3 owns it. If the compiler reports it, something in Step 2 went further than it should have.

- [ ] **Step 7: Run the suite**

Run: `swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add -A Sources Tests
git commit -m "Split the arrow intent into a seek and a slow-motion hold

Hold coverage in AppKitInputSourceTests is thinner until the Cmd
bindings land; the next commit restores it against the real keys.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `ViewerModel` adopts `SlowMotionHold`

A pure refactor: the hold behaviour is already reachable from `.slowMotionBegan`, and this replaces the implementation behind it. Task 1's tests pin the extracted unit; `ViewerModelIntentTests` pins the model's side.

**Files:**
- Modify: `Sources/SkiVideoCore/ViewerModel.swift`
- Test: `Tests/SkiVideoCoreTests/ViewerModelIntentTests.swift`
- Test: `Tests/SkiVideoCoreTests/ViewerTransportTests.swift` — three tests call `model.beginArrow`/`model.endArrow` directly and stop compiling when Step 3 deletes them. Step 3b converts them.

**Interfaces:**
- Consumes: `SlowMotionHold.begin(_:players:)`, `.end()`, `.isActive` from Task 1; `PlaybackIntent.slowMotionBegan/.slowMotionEnded` from Task 2.
- Produces: nothing new. `ViewerModel.endArrow`, `beginArrow`, `startHold`, `resumeHeldPlayback` and `pauseHeldPlayback` cease to exist.

- [ ] **Step 1: Write the failing test**

Add to `Tests/SkiVideoCoreTests/ViewerModelIntentTests.swift`:

```swift
    /// The hold is a held key now, so Space during one is an ordinary
    /// play/pause rather than a steering control for the hold. Pinning it
    /// because the old model had a dedicated branch in `togglePlayback` that
    /// paused and resumed the hold in place, and that branch is gone.
    func testSpaceDuringAHoldIsAnOrdinaryPlayPause() throws {
        let (model, input, _) = try makeModel()

        input.emit(.slowMotionBegan(.forward))
        XCTAssertEqual(model.status, "Slow forward")

        input.emit(.togglePlayback)

        XCTAssertNotEqual(model.status, "Slow forward paused",
                          "the hold's own pause branch must be gone")
    }

    /// Every library change used to clear the hold through
    /// `endArrow(performTap: false)`. The replacement must keep doing it, or a
    /// hold survives into a clip it was never started on.
    func testChangingClipEndsAnActiveHold() throws {
        let (model, input, _) = try makeModel()

        input.emit(.slowMotionBegan(.forward))
        input.emit(.clip(.next))

        XCTAssertEqual(model.player.rate, 0, "the hold must not survive a clip change")
    }
```

- [ ] **Step 2: Run to see which of the two fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ViewerModelIntentTests`

Expected: `testSpaceDuringAHoldIsAnOrdinaryPlayPause` FAILs with status `"Slow forward paused"` — that is `togglePlayback`'s hold branch, which Step 3 deletes.

`testChangingClipEndsAnActiveHold` is expected to **pass already**: `changeVideo` calls `endArrow(performTap: false)`, which pauses. It is written as a regression guard on the teardown wiring that Step 3 rewrites, not as a failing test. Do not treat its passing as a reason to skip it.

- [ ] **Step 3: Replace the hold machinery**

In `Sources/SkiVideoCore/ViewerModel.swift`:

Delete these stored properties: `heldDirection`, `reverseTimer`, `holdStarted`, `holdPausedManually`, `wasPlayingBeforeHold`, `rateBeforeHold`. Add:

```swift
    private let hold = SlowMotionHold()
```

Delete the methods `beginArrow`, `endArrow`, `startHold`, `resumeHeldPlayback`, `pauseHeldPlayback`.

In `handle(_:)`:

```swift
        case let .seek(direction):
            hold.end()
            performArrowTap(direction)
        case let .slowMotionBegan(direction):
            guard currentVideo != nil else { return }
            hold.begin(direction, players: [player])
            status = direction == .forward ? "Slow forward" : "Slow backward"
        case .slowMotionEnded:
            endSlowMotion()
```

Add:

```swift
    /// The single teardown. Every library change and every transport action
    /// routes here, because a hold left running into a clip it was not started
    /// on is the defect this replaces.
    private func endSlowMotion() {
        guard hold.isActive else { return }
        hold.end()
        status = player.rate == 0 ? "Paused" : "Playing"
    }
```

Replace every remaining `endArrow(performTap: false)` call with `endSlowMotion()` — in `applyTransport`, `scrub(to:)`, `selectAthlete`, `changeVideo`, `openDirectory`, `connectGoogleDrive` and `setKeyboardControlsEnabled`.

In `togglePlayback`, delete the leading hold branch so the body starts at the plain rate check:

```swift
    public func togglePlayback() {
        guard currentVideo != nil else { return }
        endSlowMotion()
        if player.rate == 0 {
            player.playImmediately(atRate: 1)
            status = "Playing"
        } else {
            player.pause()
            status = "Paused"
        }
    }
```

Update `applyTransport`'s comment about `endArrow` to name `endSlowMotion`, and update the `isPlaying` doc comment at `ViewerModel.swift:32-36`, which lists `startHold`/`resumeHeldPlayback`/`pauseHeldPlayback`/`endArrow` by name.

- [ ] **Step 3b: Convert `ViewerTransportTests` to the intents**

Deleting `beginArrow`/`endArrow` breaks three tests in `Tests/SkiVideoCoreTests/ViewerTransportTests.swift`. They test real behaviour worth keeping, so convert rather than delete: `model.beginArrow(d)` → `model.handle(.slowMotionBegan(d))`, and `model.endArrow(performTap: false)` → `model.handle(.slowMotionEnded)`. `handle` is internal and the file already uses `@testable import`.

- `testIsPlayingFollowsAHoldStartedFromAPausedClip` (lines ~217, ~225) — substitution only; every assertion still holds.
- `testIsPlayingSurvivesAHoldTakenDuringPlayback` (lines ~246, ~251) — substitution only. Its doc comment names `endArrow`'s `player.pause()` before restoring `rateBeforeHold`; reword to name `SlowMotionHold.end()`, which does the same two things.
- `testATransportPressCancelsAnArrowHold` (lines ~97, ~117) — substitution, **plus** a rewrite of its middle section. The test currently waits 0.3 s to prove an uncancelled hold would have *started on its own* after `holdThreshold`. There is no threshold any more: the hold starts on the intent, so an uncancelled hold is already running at 0.35 when `applyTransport` is called. Replace that block and its comment with:

```swift
        model.handle(.slowMotionBegan(.forward))
        waitUntil("precondition: the hold must be running before the transport press") {
            abs(model.player.rate - 0.35) < 0.01
        }
        model.applyTransport(.forward5)
        settle(model)

        // The hold must be cancelled outright, not left running. Without
        // `endSlowMotion` in `applyTransport` the player keeps creeping
        // forward at 0.35 after the press, and the hold's state also strands
        // `SlowMotionHold.isActive`, so `begin` refuses every later hold.
        XCTAssertEqual(model.player.rate, 0, accuracy: 0.01,
                       "a transport press must cancel the hold, not leave it running")

        // Assert on an effect the *second* hold produces, not on
        // `lastSeekOffset`: `applyTransport(.forward5)` already sets that, so an
        // assertion on it would pass whether or not the hold was cancelled.
        model.handle(.slowMotionBegan(.forward))
        waitUntil("a hold after a transport press must be accepted and start") {
            abs(model.player.rate - 0.35) < 0.01
        }
```

- [ ] **Step 4: Run the tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ViewerModelIntentTests && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ViewerTransportTests`
Expected: PASS.

- [ ] **Step 5: Run the suite and commit**

```bash
swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
git add -A Sources Tests
git commit -m "Give the viewer's hold to SlowMotionHold

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Bind ⌘+Arrow, and give the comparison window the hold

The keys and the comparison model land together: the ⌘ bindings are what make `ComparisonModel`'s new branch reachable, and testing either without the other means asserting on a path nothing drives.

**Files:**
- Modify: `Sources/SkiVideoViewer/macOS/AppKitInputSource.swift`
- Modify: `Sources/SkiVideoCore/ComparisonModel.swift`
- Test: `Tests/SkiVideoViewerTests/AppKitInputSourceTests.swift`, `Tests/SkiVideoCoreTests/ComparisonModelTests.swift`

**Interfaces:**
- Consumes: `SlowMotionHold` (Task 1), the three intents (Task 2).
- Produces: `AppKitInputSource.handle(_:)` emitting `.slowMotionBegan`/`.slowMotionEnded` for ⌘+123/124; `ComparisonModel` handling both.

- [ ] **Step 1: Write the failing input-source tests**

Add to `Tests/SkiVideoViewerTests/AppKitInputSourceTests.swift`:

```swift
    // MARK: - Cmd+Arrow slow motion

    func testCommandArrowBeginsAndEndsSlowMotion() {
        let source = AppKitInputSource()
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }

        XCTAssertTrue(source.handle(key(124, modifiers: .command)))
        XCTAssertTrue(source.handle(key(124, type: .keyUp, modifiers: .command)))

        XCTAssertEqual(captured.count, 2)
        guard captured.count == 2,
              case let .slowMotionBegan(direction) = captured[0],
              case .slowMotionEnded = captured[1]
        else {
            return XCTFail("expected a slow-motion pair, got \(captured)")
        }
        XCTAssertEqual(direction, .forward)
    }

    /// AppKit may withhold `keyUp` while Command is down, and an operator can
    /// lift Command before the arrow in any case. Dropping the modifier must
    /// end the hold on its own.
    func testReleasingCommandEndsTheHold() {
        let source = AppKitInputSource()
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }

        XCTAssertTrue(source.handle(key(123, modifiers: .command)))
        XCTAssertFalse(
            source.handle(flagsChanged(modifiers: [])),
            "the hold ends, but the flags change still belongs to AppKit"
        )

        XCTAssertEqual(captured.count, 2)
        guard case .slowMotionEnded = captured[1] else {
            return XCTFail("expected slowMotionEnded, got \(captured)")
        }
    }

    /// And the release that follows must not end it a second time — a doubled
    /// end would restore the pre-hold rate twice, and the second restore reads
    /// a rate the hold itself set.
    func testTheHoldEndsExactlyOnceWhenCommandIsReleasedFirst() {
        let source = AppKitInputSource()
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }

        _ = source.handle(key(123, modifiers: .command))
        _ = source.handle(flagsChanged(modifiers: []))
        XCTAssertFalse(
            source.handle(key(123, type: .keyUp)),
            "the hold is already over; this release is not ours"
        )

        XCTAssertEqual(captured.count, 2, "exactly one begin and one end: \(captured)")
    }

    func testCommandArrowRepeatsDoNotRebeginTheHold() {
        let source = AppKitInputSource()
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }

        _ = source.handle(key(124, modifiers: .command))
        _ = source.handle(key(124, modifiers: .command, isARepeat: true))
        _ = source.handle(key(124, modifiers: .command, isARepeat: true))

        XCTAssertEqual(captured.count, 1, "one physical press is one hold: \(captured)")
    }

    /// A second arrow pressed mid-hold must not steal the hold, or its release
    /// ends a hold it never began and the real held arrow's release does
    /// nothing. This is the Cmd-era replacement for the guard the bare arrows
    /// used to need.
    func testASecondCommandArrowMidHoldNeitherBeginsNorEnds() {
        let source = AppKitInputSource()
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }

        _ = source.handle(key(123, modifiers: .command))
        XCTAssertEqual(captured.count, 1)

        _ = source.handle(key(124, modifiers: .command))
        XCTAssertEqual(captured.count, 1, "the second arrow must not begin a hold")

        XCTAssertFalse(
            source.handle(key(124, type: .keyUp, modifiers: .command)),
            "releasing the second arrow is not ours to consume"
        )
        XCTAssertEqual(captured.count, 1)

        _ = source.handle(key(123, type: .keyUp, modifiers: .command))
        XCTAssertEqual(captured.count, 2)
        guard case .slowMotionEnded = captured[1] else {
            return XCTFail("the held arrow's release ends the hold, got \(captured)")
        }
    }

    func testDisablingMidHoldEndsIt() {
        let source = AppKitInputSource()
        var captured: [PlaybackIntent] = []
        source.onIntent = { captured.append($0) }

        _ = source.handle(key(123, modifiers: .command))
        source.setEnabled(false)

        XCTAssertEqual(captured.count, 2)
        guard case .slowMotionEnded = captured[1] else {
            return XCTFail("expected a cancelling slowMotionEnded, got \(captured)")
        }
    }

    /// Command is meaningful on the two arrows only. Cmd-O and Cmd-F belong to
    /// the menu, and Cmd-Space to the system.
    func testCommandIsIgnoredOnEveryOtherKey() {
        for code in [UInt16(49), 126, 125, 116, 121] {
            XCTAssertTrue(
                capture([key(code, modifiers: .command)]).isEmpty,
                "keyCode \(code) must not act under Command"
            )
        }
    }

    func testControlAndOptionAreStillRefusedOnTheArrows() {
        XCTAssertTrue(capture([key(124, modifiers: .control)]).isEmpty)
        XCTAssertTrue(capture([key(124, modifiers: .option)]).isEmpty)
        XCTAssertTrue(capture([key(124, modifiers: [.command, .option])]).isEmpty)
    }
```

Add the `flagsChanged` event builder next to `key(_:)` in the same file:

```swift
    private func flagsChanged(
        modifiers: NSEvent.ModifierFlags,
        windowNumber: Int = 0
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 55   // Left Command
        )!
    }
```

Also update `testModifiedKeysAreIgnored`, which asserts `key(124, modifiers: .control)` is ignored — that stays true — but drop its now-wrong premise comment about Cmd.

- [ ] **Step 2: Run to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AppKitInputSourceTests`
Expected: FAIL — ⌘ events are still refused by the modifier gate, so every new test sees no intents.

- [ ] **Step 3: Implement the ⌘ bindings**

In `Sources/SkiVideoViewer/macOS/AppKitInputSource.swift`:

Add `.flagsChanged` to the monitor's mask:

```swift
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
```

Rewrite `handle(_:)`'s gate and arrow handling:

```swift
    /// The two arrows are the only keys Command means anything on. Control and
    /// Option are refused everywhere, and Command anywhere else belongs to the
    /// menu (⌘O, ⌘F) or to the system.
    private func isSlowMotionArrow(_ event: NSEvent) -> Bool {
        (event.keyCode == 123 || event.keyCode == 124)
            && event.modifierFlags.intersection([.command, .control, .option]) == [.command]
    }

    func handle(_ event: NSEvent) -> Bool {
        guard isEnabled else { return false }

        // A dropped Command ends the hold on its own. AppKit may withhold
        // `keyUp` while Command is down, and an operator can lift the modifier
        // first regardless — either way the hold must not outlive the chord.
        //
        // Never consumed. A flags change is how AppKit tracks modifier state
        // app-wide; swallowing it would leave menus and every other responder
        // believing Command is still down. This reads the event and lets it
        // through.
        if event.type == .flagsChanged {
            if heldDirection != nil, !event.modifierFlags.contains(.command) {
                cancelHold()
            }
            return false
        }

        if event.window?.firstResponder is NSTextView, !bypassesTextFieldFocus(event) {
            return false
        }
        if !isSlowMotionArrow(event),
           !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            return false
        }

        // Keyed off the keyCode alone, never the modifier: by the time the
        // release arrives the operator may already have lifted Command, so the
        // key-up carries no flag to match on.
        if event.type == .keyUp {
            switch event.keyCode {
            case 123 where heldDirection == .backward,
                 124 where heldDirection == .forward:
                heldDirection = nil
                emit(.slowMotionEnded)
                return true
            default:
                return false
            }
        }

        switch event.keyCode {
        case 49: // Space
            if !event.isARepeat { emit(.togglePlayback) }
        case 126: // Up Arrow
            if !event.isARepeat { emit(.clip(.previous)) }
        case 125: // Down Arrow
            if !event.isARepeat { emit(.clip(.next)) }
        case 116: // Page Up
            if !event.isARepeat { emit(.athlete(.previous)) }
        case 121: // Page Down
            if !event.isARepeat { emit(.athlete(.next)) }
        // A repeat under Command is the same physical press, so it must not
        // re-begin the hold. A second *arrow* mid-hold must not steal it either
        // — its release would then end a hold it never began, and the real held
        // arrow's release would do nothing.
        case 123 where isSlowMotionArrow(event):
            if !event.isARepeat, heldDirection == nil {
                heldDirection = .backward
                emit(.slowMotionBegan(.backward))
            }
        case 124 where isSlowMotionArrow(event):
            if !event.isARepeat, heldDirection == nil {
                heldDirection = .forward
                emit(.slowMotionBegan(.forward))
            }
        case 123: // Left Arrow, unmodified
            emit(.seek(.backward))
        case 124: // Right Arrow, unmodified
            emit(.seek(.forward))
        default:
            return false
        }
        return true
    }
```

Update `bypassesTextFieldFocus`'s documentation: it now exempts the sorting window's seeks, and the flag's name is still accurate.

- [ ] **Step 4: Run the input-source tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AppKitInputSourceTests`
Expected: PASS.

- [ ] **Step 5: Write the failing comparison tests**

Add to `Tests/SkiVideoCoreTests/ComparisonModelTests.swift`:

```swift
    // MARK: - Slow motion

    func testSlowMotionRunsTheTargetedSideWhileAligning() throws {
        let input = FakeInputSource()
        let model = try makeAlignedModel(input: input)
        model.target = .left

        input.emit(.slowMotionBegan(.forward))

        XCTAssertEqual(model.leftPlayer.rate, 0.35, accuracy: 0.001)
        XCTAssertEqual(model.rightPlayer.rate, 0, "the untargeted side must stay put")
    }

    func testSlowMotionRunsBothSidesWhenBothAreTargeted() throws {
        let input = FakeInputSource()
        let model = try makeSyncedModel(input: input)
        model.target = .both

        input.emit(.slowMotionBegan(.forward))

        XCTAssertEqual(model.leftPlayer.rate, 0.35, accuracy: 0.001)
        XCTAssertEqual(model.rightPlayer.rate, 0.35, accuracy: 0.001)
    }

    /// A per-side hold on a locked pair drives the pair, matching
    /// `playIndividual` — running one clip alone would desync exactly what the
    /// operator just aligned.
    func testSlowMotionOnOneSideOfASyncedPairDrivesBoth() throws {
        let input = FakeInputSource()
        let model = try makeSyncedModel(input: input)
        model.target = .left

        input.emit(.slowMotionBegan(.forward))

        XCTAssertEqual(model.leftPlayer.rate, 0.35, accuracy: 0.001)
        XCTAssertEqual(model.rightPlayer.rate, 0.35, accuracy: 0.001)
    }

    func testEndingSlowMotionStopsThePlayers() throws {
        let input = FakeInputSource()
        let model = try makeAlignedModel(input: input)
        model.target = .right

        input.emit(.slowMotionBegan(.forward))
        input.emit(.slowMotionEnded)

        XCTAssertEqual(model.rightPlayer.rate, 0)
    }

    func testClosingEndsAnActiveHold() throws {
        let input = FakeInputSource()
        let model = try makeAlignedModel(input: input)
        model.target = .left

        input.emit(.slowMotionBegan(.forward))
        model.close()

        XCTAssertEqual(model.leftPlayer.rate, 0)
    }
```

- [ ] **Step 6: Run to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ComparisonModelTests`
Expected: FAIL — `handle`'s `default: break` swallows both intents, so every rate stays 0.

- [ ] **Step 7: Implement the comparison side**

In `Sources/SkiVideoCore/ComparisonModel.swift`, add the stored property beside the other private state:

```swift
    private let hold = SlowMotionHold()
```

Extend `handle(_:)`:

```swift
    func handle(_ intent: PlaybackIntent) {
        switch intent {
        case .togglePlayback:
            applyTransport(.playPause)
        case .seek(.backward):
            applyTransport(.back1)
        case .seek(.forward):
            applyTransport(.forward1)
        case let .slowMotionBegan(direction):
            beginSlowMotion(direction)
        case .slowMotionEnded:
            hold.end()
        default:
            break
        }
    }

    /// Which players a hold drives, by the same rule the rest of the model
    /// follows: `both` is the pair, a side is that side — except on a locked
    /// pair, where a per-side hold drives both, matching `playIndividual`.
    /// Running one clip alone would desync exactly what was just aligned.
    private func beginSlowMotion(_ direction: ScrubDirection) {
        let players: [AVPlayer]
        switch target {
        case .both:
            players = [leftPlayer, rightPlayer]
        case .left, .right:
            let side: ComparisonSide = target == .left ? .left : .right
            noteTouched(side)
            players = isSynced ? [leftPlayer, rightPlayer] : [player(for: side)]
        }
        hold.begin(direction, players: players)
        status = direction == .forward ? "Slow forward" : "Slow backward"
    }
```

In `pauseBoth()` and `close()`, add `hold.end()` as the first statement.

- [ ] **Step 8: Run the tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ComparisonModelTests`
Expected: PASS.

- [ ] **Step 9: Run the suite and commit**

```bash
swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
git add -A Sources Tests
git commit -m "Bind Cmd+Arrow to slow motion on both screens

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: `LibraryGrouping` and `AthleteGroup.event`

**Files:**
- Create: `Sources/SkiVideoCore/LibraryGrouping.swift`
- Modify: `Sources/SkiVideoCore/VideoLibrary.swift`
- Test: `Tests/SkiVideoCoreTests/LibraryGroupingTests.swift`, `Tests/SkiVideoCoreTests/VideoLibraryTests.swift`

**Interfaces:**
- Consumes: `AthleteGroup` (gains a field in this task).
- Produces: `AthleteGroup.event: String?` and its new `init(id:name:event:videos:)`; `LibraryGrouping.Entry(video:athlete:event:)` and `LibraryGrouping.group(_: [Entry]) -> [AthleteGroup]`. Task 6 reads `AthleteGroup.event`; Task 8 calls `LibraryGrouping.group`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SkiVideoCoreTests/LibraryGroupingTests.swift`:

```swift
import Foundation
import XCTest
@testable import SkiVideoCore

/// The grouping rules, tested on triples rather than on a directory tree, so
/// the same rules can be proven for the Google Drive scan — which walks folder
/// ids, not paths, and could never be exercised through `VideoLibrary.scan`.
final class LibraryGroupingTests: XCTestCase {
    private func video(_ name: String) -> URL {
        URL(fileURLWithPath: "/library/\(name)")
    }

    func testSameAthleteAtTwoEventsStaysTwoGroups() {
        let groups = LibraryGrouping.group([
            .init(video: video("a.mp4"), athlete: "Alice", event: "event-one"),
            .init(video: video("b.mp4"), athlete: "alice", event: "event-two"),
        ])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(Set(groups.map(\.event)), ["event-one", "event-two"])
    }

    func testSameAthleteWithinOneEventMergesAcrossCasingAndDiacritics() {
        let groups = LibraryGrouping.group([
            .init(video: video("a.mp4"), athlete: "Sofie", event: "neuss"),
            .init(video: video("b.mp4"), athlete: "sofié", event: "neuss"),
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "Sofie", "the first spelling seen wins")
        XCTAssertEqual(groups[0].videos.count, 2)
    }

    func testEventsSortDescendingSoTheNewestDateIsFirst() {
        let groups = LibraryGrouping.group([
            .init(video: video("a.mp4"), athlete: "Alice", event: "2026-07-16_Neuss"),
            .init(video: video("b.mp4"), athlete: "Alice", event: "2026-08-02_Oberhof"),
        ])

        XCTAssertEqual(groups.map(\.event), ["2026-08-02_Oberhof", "2026-07-16_Neuss"])
    }

    func testAthletesSortAlphabeticallyWithinAnEvent() {
        let groups = LibraryGrouping.group([
            .init(video: video("c.mp4"), athlete: "Chris", event: "neuss"),
            .init(video: video("a.mp4"), athlete: "Alice", event: "neuss"),
            .init(video: video("b.mp4"), athlete: "Bob", event: "neuss"),
        ])

        XCTAssertEqual(groups.map(\.name), ["Alice", "Bob", "Chris"])
    }

    func testEventlessGroupsSortLast() {
        let groups = LibraryGrouping.group([
            .init(video: video("a.mp4"), athlete: "Alice", event: nil),
            .init(video: video("b.mp4"), athlete: "Bob", event: "2026-08-02_Oberhof"),
        ])

        XCTAssertEqual(groups.map(\.name), ["Bob", "Alice"])
        XCTAssertNil(groups[1].event)
    }

    func testIdsAreEventScopedSoTwoSameNamedAthletesAreSelectableApart() {
        let groups = LibraryGrouping.group([
            .init(video: video("a.mp4"), athlete: "Alice", event: "one"),
            .init(video: video("b.mp4"), athlete: "Alice", event: "two"),
        ])

        XCTAssertEqual(Set(groups.map(\.id)).count, 2, "ids must not collide")
    }

    func testVideosWithinAGroupSortByPath() {
        let groups = LibraryGrouping.group([
            .init(video: video("C0002.mp4"), athlete: "Alice", event: "one"),
            .init(video: video("C0001.mp4"), athlete: "Alice", event: "one"),
        ])

        XCTAssertEqual(
            groups[0].videos.map(\.lastPathComponent),
            ["C0001.mp4", "C0002.mp4"]
        )
    }

    func testAnEmptyInputProducesNoGroups() {
        XCTAssertTrue(LibraryGrouping.group([]).isEmpty)
    }
}
```

Rewrite `Tests/SkiVideoCoreTests/VideoLibraryTests.swift:29-47` — the merge test becomes a split test — and add the depth cases:

```swift
    func testSplitsTheSameAthleteAcrossEvents() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("event-one/Alice")
        let second = root.appendingPathComponent("event-two/alice")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data().write(to: first.appendingPathComponent("first.mp4"))
        try Data().write(to: second.appendingPathComponent("second.mp4"))

        let athletes = try VideoLibrary.scan(root)

        XCTAssertEqual(athletes.count, 2, "an athlete at two events is two entries")
        XCTAssertEqual(athletes.map(\.event), ["event-two", "event-one"])
        XCTAssertEqual(athletes[0].videos.map(\.lastPathComponent), ["second.mp4"])
        XCTAssertEqual(athletes[1].videos.map(\.lastPathComponent), ["first.mp4"])
    }

    func testAnAthleteFolderDirectlyUnderTheRootHasNoEvent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let alice = root.appendingPathComponent("Alice")
        try FileManager.default.createDirectory(at: alice, withIntermediateDirectories: true)
        try Data().write(to: alice.appendingPathComponent("run.mp4"))

        let athletes = try VideoLibrary.scan(root)

        XCTAssertEqual(athletes.count, 1)
        XCTAssertNil(athletes[0].event)
        XCTAssertEqual(athletes[0].name, "Alice")
    }

    /// The event is the folder directly above the athlete, not the first
    /// component under the root. Taking the first component would call this
    /// athlete's event "2026", which is a season, not an event.
    func testTheEventIsTheFolderDirectlyAboveTheAthlete() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let alice = root.appendingPathComponent("2026/2026-08-02_Oberhof/Alice")
        try FileManager.default.createDirectory(at: alice, withIntermediateDirectories: true)
        try Data().write(to: alice.appendingPathComponent("run.mp4"))

        let athletes = try VideoLibrary.scan(root)

        XCTAssertEqual(athletes.count, 1)
        XCTAssertEqual(athletes[0].event, "2026-08-02_Oberhof")
        XCTAssertEqual(athletes[0].name, "Alice")
    }

    func testAMixedDepthTreeGroupsEachAthleteByItsOwnParent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = root.appendingPathComponent("2026-08-02_Oberhof/Alice")
        let loose = root.appendingPathComponent("Bob")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("a.mp4"))
        try Data().write(to: loose.appendingPathComponent("b.mp4"))

        let athletes = try VideoLibrary.scan(root)

        XCTAssertEqual(athletes.map(\.name), ["Alice", "Bob"])
        XCTAssertEqual(athletes[0].event, "2026-08-02_Oberhof")
        XCTAssertNil(athletes[1].event, "the event-less group sorts last")
    }
```

Also update `testGroupsNestedVideosByAthleteFolder` to assert the event it now carries:

```swift
        XCTAssertEqual(athletes.map(\.event), ["2026-07-16_Neuss", "2026-07-16_Neuss"])
```

- [ ] **Step 2: Run to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter LibraryGroupingTests`
Expected: FAIL to compile — `cannot find 'LibraryGrouping' in scope`.

- [ ] **Step 3: Implement `LibraryGrouping`**

Create `Sources/SkiVideoCore/LibraryGrouping.swift`:

```swift
import Foundation

/// Turns flat `(video, athlete, event)` triples into the sidebar's groups.
///
/// A separate unit rather than a method on `VideoLibrary` because two scanners
/// need it and only one of them walks a filesystem: the Google Drive client
/// recurses folder ids over the network, so a rule that lived in the local
/// scan could only ever be *reimplemented* there. The two disagreed about the
/// supported-extension list until 2026-08-08 for exactly that reason; the
/// grouping rule is not going the same way.
enum LibraryGrouping {
    struct Entry {
        let video: URL
        let athlete: String
        /// The event the athlete's folder sat in, or nil when there was none —
        /// an athlete folder directly under the chosen root.
        let event: String?

        init(video: URL, athlete: String, event: String?) {
            self.video = video
            self.athlete = athlete
            self.event = event
        }
    }

    /// Groups on the folded `(event, athlete)` pair, so `Alice` and `alice` at
    /// one event are one athlete while `Alice` at two events is two — each
    /// holding only that event's clips.
    ///
    /// Events sort descending: the folders are date-prefixed in practice, so
    /// that puts the most recent event at the top of the sidebar. Athletes sort
    /// alphabetically within an event, and groups with no event collect at the
    /// end.
    static func group(_ entries: [Entry]) -> [AthleteGroup] {
        struct Key: Hashable {
            let event: String?
            let athlete: String
        }

        var eventNames: [String: String] = [:]
        var athleteNames: [Key: String] = [:]
        var videos: [Key: [URL]] = [:]
        var order: [Key] = []

        for entry in entries {
            let eventKey = entry.event.map(fold)
            let key = Key(event: eventKey, athlete: fold(entry.athlete))
            if let eventKey, let event = entry.event {
                eventNames[eventKey] = eventNames[eventKey] ?? event
            }
            if videos[key] == nil {
                order.append(key)
                athleteNames[key] = entry.athlete
            }
            videos[key, default: []].append(entry.video)
        }

        return order
            .sorted { left, right in
                switch (left.event, right.event) {
                case let (lhs?, rhs?) where lhs != rhs:
                    let lhsName = eventNames[lhs] ?? lhs
                    let rhsName = eventNames[rhs] ?? rhs
                    return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedDescending
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                default:
                    let lhsName = athleteNames[left] ?? left.athlete
                    let rhsName = athleteNames[right] ?? right.athlete
                    return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
                }
            }
            .map { key in
                AthleteGroup(
                    id: "\(key.event ?? "")/\(key.athlete)",
                    name: athleteNames[key] ?? key.athlete,
                    event: key.event.flatMap { eventNames[$0] },
                    videos: (videos[key] ?? []).sorted {
                        $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
                    }
                )
            }
    }

    private static func fold(_ name: String) -> String {
        name.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }
}
```

- [ ] **Step 4: Add the field and rewrite the scan**

In `Sources/SkiVideoCore/VideoLibrary.swift`, extend `AthleteGroup`:

```swift
public struct AthleteGroup: Identifiable, Equatable {
    public let id: String
    public let name: String
    /// The event folder this athlete's clips sat in, or nil when the athlete
    /// folder was directly under the chosen root. The sidebar groups by it; the
    /// clip caption and the comparison picker spell it out where there is no
    /// section header to carry it.
    public let event: String?
    public let videos: [URL]

    public init(id: String, name: String, event: String? = nil, videos: [URL]) {
        self.id = id
        self.name = name
        self.event = event
        self.videos = videos
    }
}
```

Replace the tail of `VideoLibrary.scan` (everything after the `videos.append(fileURL)` loop) with:

```swift
        return LibraryGrouping.group(
            videos.map { video in
                let athleteFolder = video.deletingLastPathComponent()
                let eventFolder = athleteFolder.deletingLastPathComponent()
                // The event is the folder *directly above* the athlete, and
                // only when there is one inside the chosen root. Taking the
                // first component under the root instead would name a season
                // rather than an event in a `root/2026/Event/Athlete` tree, and
                // would mistake the athlete's own folder for an event in a
                // `root/Athlete` one.
                let hasEvent = eventFolder.standardizedFileURL.path != root.standardizedFileURL.path
                return LibraryGrouping.Entry(
                    video: video,
                    athlete: athleteFolder.lastPathComponent,
                    event: hasEvent ? eventFolder.lastPathComponent : nil
                )
            }
        )
```

Delete the now-unused `videos.sort`, `names`, `grouped` block — `LibraryGrouping` owns all of it.

- [ ] **Step 5: Run the tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter LibraryGroupingTests && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter VideoLibraryTests`
Expected: PASS.

- [ ] **Step 6: Run the suite and commit**

```bash
swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
git add -A Sources Tests
git commit -m "Group the library by event as well as athlete

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Sectioned sidebar

**Files:**
- Modify: `Sources/SkiVideoCore/ViewerModel.swift`
- Modify: `Sources/SkiVideoViewer/Shared/ContentView.swift:172-181`
- Test: `Tests/SkiVideoCoreTests/ViewerModelIntentTests.swift`

**Interfaces:**
- Consumes: `AthleteGroup.event` from Task 5.
- Produces: `public struct EventGroup: Identifiable` with `id: String`, `name: String?`, `athletes: [AthleteGroup]`; `ViewerModel.events: [EventGroup]` (public, computed from `filteredAthletes`).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/SkiVideoCoreTests/ViewerModelIntentTests.swift`. First extend the fixture builder so it can make an event tree — add this beside `makeLibrary`:

```swift
    /// A tree of `root/<event>/<athlete>/a.mp4`, for the sectioned sidebar.
    private func makeEventLibrary(_ events: [String: [String]]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        for (event, athleteNames) in events {
            for athleteName in athleteNames {
                let athlete = root
                    .appendingPathComponent(event, isDirectory: true)
                    .appendingPathComponent(athleteName, isDirectory: true)
                try FileManager.default.createDirectory(at: athlete, withIntermediateDirectories: true)
                FileManager.default.createFile(
                    atPath: athlete.appendingPathComponent("a.mp4").path,
                    contents: Data()
                )
            }
        }
        temporaryDirectory = root
        return root
    }

    private func makeEventModel(_ events: [String: [String]]) throws -> ViewerModel {
        let model = ViewerModel(
            input: FakeInputSource(),
            folderPicker: FakeFolderPicker(),
            oauthPresenter: FakeOAuthPresenter()
        )
        model.openDirectory(try makeEventLibrary(events))
        return model
    }
```

Then the tests:

```swift
    func testEventsSectionTheAthleteList() throws {
        let model = try makeEventModel([
            "2026-07-16_Neuss": ["Alice", "Bob"],
            "2026-08-02_Oberhof": ["Alice"],
        ])

        XCTAssertEqual(model.events.map(\.name), ["2026-08-02_Oberhof", "2026-07-16_Neuss"])
        XCTAssertEqual(model.events[0].athletes.map(\.name), ["Alice"])
        XCTAssertEqual(model.events[1].athletes.map(\.name), ["Alice", "Bob"])
    }

    /// The flat list and the sections are two readings of one array, so they
    /// cannot disagree — and PageUp/PageDown, which walk the flat list, step
    /// through the sections in the order they are drawn.
    func testTheFlatListIsTheSectionsConcatenated() throws {
        let model = try makeEventModel([
            "2026-07-16_Neuss": ["Alice", "Bob"],
            "2026-08-02_Oberhof": ["Alice"],
        ])

        XCTAssertEqual(
            model.events.flatMap { $0.athletes.map(\.id) },
            model.athletes.map(\.id)
        )
    }

    /// A library with no event folders must render exactly as it did before
    /// this feature: one unnamed section holding everything.
    func testAnEventlessLibraryIsASingleUnnamedSection() throws {
        let (model, _, _) = try makeModel(athletes: ["Alma", "Idun"])

        XCTAssertEqual(model.events.count, 1)
        XCTAssertNil(model.events[0].name)
        XCTAssertEqual(model.events[0].athletes.map(\.name), ["Alma", "Idun"])
    }

    func testSearchingAnEventNameNarrowsToThatEvent() throws {
        let model = try makeEventModel([
            "2026-07-16_Neuss": ["Alice", "Bob"],
            "2026-08-02_Oberhof": ["Chris"],
        ])

        model.athleteQuery = "Oberhof"

        XCTAssertEqual(model.events.map(\.name), ["2026-08-02_Oberhof"])
        XCTAssertEqual(model.events[0].athletes.map(\.name), ["Chris"])
    }

    func testSearchingAnAthleteNameStillWorksAcrossEvents() throws {
        let model = try makeEventModel([
            "2026-07-16_Neuss": ["Alice", "Bob"],
            "2026-08-02_Oberhof": ["Alice"],
        ])

        model.athleteQuery = "Alice"

        XCTAssertEqual(model.events.count, 2)
        XCTAssertEqual(model.events.flatMap { $0.athletes.map(\.name) }, ["Alice", "Alice"])
    }

    func testASectionEmptiedByTheSearchIsDropped() throws {
        let model = try makeEventModel([
            "2026-07-16_Neuss": ["Alice"],
            "2026-08-02_Oberhof": ["Chris"],
        ])

        model.athleteQuery = "Chris"

        XCTAssertEqual(model.events.count, 1, "the empty section must not be drawn")
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ViewerModelIntentTests`
Expected: FAIL to compile — `value of type 'ViewerModel' has no member 'events'`.

- [ ] **Step 3: Implement `events` and the search**

In `Sources/SkiVideoCore/VideoLibrary.swift`, beside `AthleteGroup`:

```swift
/// One sidebar section: the athletes that shared an event folder.
///
/// A derived reading of `ViewerModel.athletes`, never a second store — the flat
/// array stays the source of truth because selection-by-id, `changeAthlete` and
/// the Page keys all run on it, and a section list that could drift from it
/// would put the keyboard and the sidebar on different orders.
public struct EventGroup: Identifiable, Equatable {
    /// The folded event name, or the empty string for the event-less section.
    public let id: String
    /// nil for the trailing section holding athletes that had no event folder.
    public let name: String?
    public let athletes: [AthleteGroup]

    public init(id: String, name: String?, athletes: [AthleteGroup]) {
        self.id = id
        self.name = name
        self.athletes = athletes
    }
}
```

In `Sources/SkiVideoCore/ViewerModel.swift`, extend the filter to match events and add the sections:

```swift
    public var filteredAthletes: [AthleteGroup] {
        let query = normalizedName(athleteQuery)
        guard !query.isEmpty else { return athletes }
        return athletes.filter {
            normalizedName($0.name).contains(query)
                || normalizedName($0.event ?? "").contains(query)
        }
    }

    /// `filteredAthletes` in sidebar sections. Built by walking the array in
    /// order and starting a section wherever the event changes — the grouping
    /// already sorted every event's athletes together, so one pass is enough
    /// and the sections come out in the same order as the flat list.
    public var events: [EventGroup] {
        var sections: [EventGroup] = []
        for athlete in filteredAthletes {
            if let last = sections.last, last.name == athlete.event {
                sections[sections.count - 1] = EventGroup(
                    id: last.id,
                    name: last.name,
                    athletes: last.athletes + [athlete]
                )
            } else {
                sections.append(
                    EventGroup(
                        id: athlete.event ?? "",
                        name: athlete.event,
                        athletes: [athlete]
                    )
                )
            }
        }
        return sections
    }
```

- [ ] **Step 4: Run the tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ViewerModelIntentTests`
Expected: PASS.

- [ ] **Step 5: Draw the sections**

In `Sources/SkiVideoViewer/Shared/ContentView.swift`, replace the `List` at lines 172-181:

```swift
            List(selection: $model.selectedAthleteID) {
                ForEach(model.events) { event in
                    // A `Section` without a header renders as a plain run of
                    // rows, so a library with no event folders looks exactly as
                    // it did before events existed.
                    Section {
                        ForEach(event.athletes) { athlete in
                            HStack {
                                Text(athlete.name)
                                Spacer()
                                Text("\(athlete.videos.count)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .tag(athlete.id)
                        }
                    } header: {
                        if let name = event.name {
                            Text(name)
                        }
                    }
                }
            }
```

- [ ] **Step 6: Build and commit**

```bash
swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
git add -A Sources Tests
git commit -m "Section the sidebar by event

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Spell the event out where there is no section header

**Files:**
- Modify: `Sources/SkiVideoCore/ViewerModel.swift:146-165`
- Test: `Tests/SkiVideoCoreTests/ViewerModelIntentTests.swift`

**Interfaces:**
- Consumes: `AthleteGroup.event` (Task 5), `makeEventModel` (Task 6).
- Produces: no new API — `clipDescription` and `comparisonLibrary` change what they return.

- [ ] **Step 1: Write the failing tests**

```swift
    func testClipDescriptionNamesTheEvent() throws {
        let model = try makeEventModel(["2026-08-02_Oberhof": ["Alice"]])

        XCTAssertEqual(model.clipDescription, "Clip 1 of 1 · 2026-08-02_Oberhof · a.mp4")
    }

    func testClipDescriptionOmitsAMissingEvent() throws {
        let (model, _, _) = try makeModel()

        XCTAssertEqual(model.clipDescription, "Clip 1 of 2 · a.mp4")
    }

    /// Two same-named athletes at different events are two entries in the
    /// comparison picker, and the picker has no section headers — so the names
    /// have to carry the event or the operator cannot tell them apart.
    func testComparisonLibraryDistinguishesSameNamedAthletesByEvent() throws {
        let model = try makeEventModel([
            "2026-07-16_Neuss": ["Alice"],
            "2026-08-02_Oberhof": ["Alice"],
        ])

        XCTAssertEqual(
            model.comparisonLibrary.map(\.name),
            ["Alice — 2026-08-02_Oberhof", "Alice — 2026-07-16_Neuss"]
        )
    }

    func testComparisonLibraryLeavesAnEventlessAthleteNameAlone() throws {
        let (model, _, _) = try makeModel()

        XCTAssertEqual(model.comparisonLibrary.map(\.name), ["Idun"])
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ViewerModelIntentTests`
Expected: FAIL — `clipDescription` returns `"Clip 1 of 1 · a.mp4"` and the picker names are both `"Alice"`.

- [ ] **Step 3: Implement**

In `Sources/SkiVideoCore/ViewerModel.swift`:

```swift
    public var comparisonLibrary: [ComparisonAthleteChoice] {
        athletes.map { athlete in
            ComparisonAthleteChoice(
                id: athlete.id,
                // The picker draws a flat menu with no section headers, so two
                // Alices from two events would be indistinguishable without
                // this. Left alone when there is no event, so a single-event
                // library reads exactly as it always has.
                name: athlete.event.map { "\(athlete.name) — \($0)" } ?? athlete.name,
                videos: athlete.videos.map { video in
                    ComparisonVideoChoice(
                        id: "\(athlete.id)|\(video.absoluteString)",
                        name: video.lastPathComponent,
                        playbackURL: driveMediaByURL[video]?.streamingURL ?? video
                    )
                }
            )
        }
    }

    public var clipDescription: String {
        guard let athlete = currentAthlete, let currentVideo else { return "" }
        let position = "Clip \(videoIndex + 1) of \(athlete.videos.count)"
        guard let event = athlete.event else {
            return "\(position) · \(currentVideo.lastPathComponent)"
        }
        return "\(position) · \(event) · \(currentVideo.lastPathComponent)"
    }
```

- [ ] **Step 4: Run and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ViewerModelIntentTests
swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
git add -A Sources Tests
git commit -m "Name the event where no section header carries it

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Google Drive scans through `LibraryGrouping`

**Files:**
- Modify: `Sources/SkiVideoCore/GoogleDriveSupport.swift:71-131`

**Interfaces:**
- Consumes: `LibraryGrouping.Entry`, `LibraryGrouping.group` (Task 5).
- Produces: no new API. `scanSharedDrive` returns `AthleteGroup`s carrying events.

There is no test here: `scanSharedDrive` recurses over live network calls and the repo has no Drive fake. The grouping rules it now shares are pinned by `LibraryGroupingTests`, which is the whole reason that unit exists — this task is the wiring that makes those tests cover Drive too. Task 9's manual check exercises the local path only; a Drive smoke test needs credentials and is out of scope.

- [ ] **Step 1: Thread the grandparent through the recursion**

In `Sources/SkiVideoCore/GoogleDriveSupport.swift`, replace the body of `scanSharedDrive` up to and including the `athletes` construction:

```swift
    func scanSharedDrive(folderID: String) async throws -> DriveLibrary {
        var entries: [LibraryGrouping.Entry] = []
        var mediaByURL: [URL: DriveMedia] = [:]

        // Both names are carried, not just the athlete's: the event is the
        // folder directly above the athlete, so the recursion has to remember
        // one more level than it used to. `VideoLibrary.scan` reads the same
        // two components out of the path — the rule is one rule, applied to
        // whatever each scanner can see.
        func scan(folderID: String, parentName: String?, grandparentName: String?) async throws {
            for file in try await listChildren(of: folderID) {
                if file.mimeType == Self.folderMimeType {
                    try await scan(
                        folderID: file.id,
                        parentName: file.name,
                        grandparentName: parentName
                    )
                    continue
                }
                // The same list the local library uses, deliberately not a copy.
                // Drive kept its own set until 2026-08-08, still naming avi, mkv
                // and webm after the local one dropped them — so Drive offered
                // files that `AVPlayer` cannot open and the sidebar would not
                // have listed. One source of truth cannot drift like that.
                guard file.canDownload,
                      VideoLibrary.supportedExtensions
                          .contains(URL(fileURLWithPath: file.name).pathExtension.lowercased())
                else {
                    continue
                }

                let streamURL = URL(string: "drivevideo://\(file.id)")!
                    .appendingPathComponent(file.name)
                mediaByURL[streamURL] = DriveMedia(
                    fileID: file.id,
                    name: file.name,
                    mimeType: file.mimeType,
                    size: Int64(file.size ?? "") ?? 0,
                    accessToken: accessToken
                )
                entries.append(
                    LibraryGrouping.Entry(
                        video: streamURL,
                        athlete: parentName ?? "Unsorted",
                        // A file loose in the chosen root has neither an athlete
                        // folder nor an event; one in `root/Athlete` has an
                        // athlete but no event, exactly as locally.
                        event: parentName == nil ? nil : grandparentName
                    )
                )
            }
        }

        try await scan(folderID: folderID, parentName: nil, grandparentName: nil)
        return DriveLibrary(
            athletes: LibraryGrouping.group(entries),
            mediaByURL: mediaByURL
        )
    }
```

- [ ] **Step 2: Build and run the suite**

Run: `swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: PASS — nothing in the suite drives this path, so this proves only that it compiles and that nothing else regressed.

- [ ] **Step 3: Commit**

```bash
git add Sources/SkiVideoCore/GoogleDriveSupport.swift
git commit -m "Let the Drive scan share the library's grouping rule

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Manual check in the real app

Everything above is unit-tested against fakes and synthesized `NSEvent`s. Two things only the real app can answer: whether AppKit delivers `keyUp` for a ⌘-modified arrow through a local monitor, and whether the sectioned sidebar reads correctly.

**Files:** none — this task changes nothing unless it finds a defect.

- [ ] **Step 1: Build and launch**

```bash
./run.sh
```

- [ ] **Step 2: Check the viewer's keys**

Open a folder laid out as `<parent>/<event>/<athlete>/*.mp4`. Then, with a clip loaded:

| Do | Expect |
| --- | --- |
| Press `→` once | jumps forward 1 s, status `Forward 1 seconds` |
| Press `→` twice quickly | jumps 5 s, status `Forward 5 seconds` |
| Hold `⌘→` for ~2 s, release | plays slowly forward while held; stops on release |
| Hold `⌘←` for ~2 s, release | plays slowly backward while held; stops on release |
| Hold `⌘→`, release **⌘ first**, then the arrow | stops the moment ⌘ comes up, and does not seek |
| Hold `⌘→`, release **the arrow first**, keep ⌘ down | records which happens: stops on the arrow release (key-up is delivered) or keeps running until ⌘ comes up |
| Hold `⌘→`, then ⌘-Tab away | stops |

The second-to-last row is the open question from the spec. Report the result. If the hold keeps running, the fallback is already in place and the behaviour is merely degraded, not broken — decide with the user whether to add a key-repeat watchdog.

- [ ] **Step 3: Check the sidebar and the comparison window**

| Do | Expect |
| --- | --- |
| Look at the sidebar | one section per event, newest first, athletes alphabetical inside |
| Type an event name in the search field | only that section remains |
| Press PageDown repeatedly | walks every athlete top to bottom, across section boundaries |
| Read the clip caption | `Clip n of m · <event> · <file>` |
| Open Compare, open a clip menu | same-named athletes from two events are distinguishable |
| In Compare, press `→` / hold `⌘→` | ±1 s / slow motion, on whichever side the target picker names |
| In Compare, sync two clips, target one side, hold `⌘→` | both clips run together, still in sync on release |

- [ ] **Step 4: Report**

Write up what happened, especially Step 2's open question. Nothing is committed in this task unless a defect turns up and is fixed.

---

## Self-Review

**Spec coverage.** Every section maps to a task: `SlowMotionHold` → 1; intent vocabulary → 2; `AppKitInputSource` → 2 and 4; `ViewerModel` hotkeys → 2 and 3; `ComparisonModel` → 4; the ⌘ key-up risk → 4 (both end paths) and 9 (measurement); grouping rule and `AthleteGroup.event` → 5; ordering and sidebar → 6; `clipDescription` and `comparisonLibrary` → 7; Google Drive → 8; "untouched: SortingLibrary/SortingModel" → nothing beyond the case rename in 2.

**Deviations from the spec, both deliberate:**
- The spec made the ⌘ key-up spike a blocking first step. This plan implements both end paths instead — which the spec already specified — so the question degrades to a measurement in Task 9 rather than gating the work.
- The spec asked for "Drive scan coverage mirroring the local grouping rule". `scanSharedDrive` is unmockable without a network fake, so the coverage lives in `LibraryGroupingTests` against the shared unit and Task 8 is wiring only. Task 8 says so explicitly rather than implying Drive is tested.

**One removal the spec did not name — later withdrawn.** Task 2 originally deleted `AppKitInputSource.arrowsRepeat` and its `SortingWindowController` call site, reasoning that with a bare arrow seeking on key-down a repeat is just another key-down. Task 2's review measured that this makes a held arrow in the viewer alternate +1 s / +5 s forever, because `performArrowTap`'s double-tap detector counts repeats as taps. The flag is kept; see the correction note in Task 2, Step 3.
