# iPadOS Phase 1: Extract SkiVideoCore — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract all platform-agnostic logic out of the macOS app into a
`SkiVideoCore` SwiftPM library, behind seam protocols, with the macOS app
building and behaving exactly as it does today.

**Architecture:** The package gains a `SkiVideoCore` library target alongside the
existing executable. Models move into the library one at a time; the AppKit code
they used (`NSOpenPanel`, `NSEvent`, `NSWorkspace`, `Process`) is replaced by
protocol dependencies whose macOS implementations live in the executable target.
No iOS code is written in this phase and no behaviour changes.

**Tech Stack:** Swift 6.1 (language mode 5), SwiftPM, AVFoundation, Combine,
XCTest. macOS 13+.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-31-ipados-support-design.md`.
- Package platforms: `.macOS(.v13), .iOS(.v17)`. Do not raise the macOS floor.
- `Sources/SkiVideoCore/` must never import `AppKit`, `UIKit`, or `SwiftUI`, and
  must never reference `Process`. Task 1 adds a test that enforces this.
- The macOS app must build and run after every task. `./build_app.sh` is the
  check.
- Swift language mode stays `.v5`. Do not migrate to Swift 6 strict concurrency
  in this phase.
- Every type or member the executable target uses must be `public`. Moving a
  file to `SkiVideoCore` without adding access modifiers will not compile.
- No behaviour changes. This phase is a pure refactor; any user-visible
  difference is a bug, except the one incidental fix in Task 3.
- **Every shell that runs `swift build` or `swift test` must first run
  `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.** The
  machine's active developer directory is the Command Line Tools, which ship no
  XCTest — without the export, `swift test` fails with
  `error: no such module 'XCTest'` before running a single test. Verified
  against this repo. The command blocks below include the export; keep it when
  adapting them.
- Baseline before any work: 10 tests, 0 failures. Any lower count is a
  regression, not a starting point.

## Deviation from the spec, deliberate

The spec sketches `PlaybackInputSource` with an `AsyncStream<PlaybackIntent>`.
This plan uses a synchronous callback (`onIntent`) instead. The tap/double-tap/
hold state machine is timing-sensitive, and a synchronous callback lets its tests
assert deterministically without async ordering. The seam boundary and the intent
vocabulary are unchanged, so nothing downstream is affected.

## File Structure

**Created**

| File | Responsibility |
|---|---|
| `Sources/SkiVideoCore/Seams.swift` | `PlaybackIntent`, `PlaybackInputSource`, `FolderPicker`, `OAuthPresenter`, `MediaPipeline` protocols and their value types |
| `Sources/SkiVideoViewer/Platform/AppKitInputSource.swift` | `NSEvent` monitor producing intents |
| `Sources/SkiVideoViewer/Platform/AppKitFolderPicker.swift` | `NSOpenPanel` implementation |
| `Sources/SkiVideoViewer/Platform/AppKitOAuthPresenter.swift` | Loopback callback server + `NSWorkspace.open` |
| `Sources/SkiVideoViewer/Platform/FFmpegMediaPipeline.swift` | The `Process`-based ffmpeg runner |
| `Tests/SkiVideoCoreTests/CorePurityTests.swift` | Guard against forbidden imports in core |
| `Tests/SkiVideoCoreTests/FakeSeams.swift` | Test doubles for every seam |
| `Tests/SkiVideoCoreTests/ViewerModelIntentTests.swift` | Tap / double-tap / hold coverage |

**Moved into `Sources/SkiVideoCore/`**

`VideoLibrary.swift`, `SortingLibrary.swift`, `ViewerModel.swift`,
`ComparisonModel.swift`, `SortingModel.swift`, `GoogleDriveSupport.swift`.

**Moved into `Tests/SkiVideoCoreTests/`**

`VideoLibraryTests.swift`, `ComparisonModelTests.swift`.

**Unchanged, stays in the executable target**

All SwiftUI views, `NativePlayerView.swift`, `OverlayPlayerView.swift`,
`ComparisonWindowController.swift`, `SortingWindowController.swift`,
`SkiVideoViewerApp.swift`.

---

### Task 1: Split the package into library and executable

**Files:**
- Modify: `SkiVideoViewer/Package.swift`
- Move: `Sources/SkiVideoViewer/VideoLibrary.swift` → `Sources/SkiVideoCore/VideoLibrary.swift`
- Move: `Sources/SkiVideoViewer/SortingLibrary.swift` → `Sources/SkiVideoCore/SortingLibrary.swift`
- Move: `Tests/SkiVideoViewerTests/VideoLibraryTests.swift` → `Tests/SkiVideoCoreTests/VideoLibraryTests.swift`
- Create: `Tests/SkiVideoCoreTests/CorePurityTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: target `SkiVideoCore`; `public enum VideoLibrary` with
  `public static func scan(_ root: URL) throws -> [AthleteGroup]` and
  `public static let supportedExtensions: Set<String>`;
  `public struct AthleteGroup: Identifiable, Equatable` with
  `public let id: String`, `public let name: String`, `public let videos: [URL]`,
  and `public init(id:name:videos:)`; `public enum ViewerError: LocalizedError`
  with cases `invalidDirectory(String)`, `cannotReadDirectory(String)`,
  `noVideos`; `public enum SortingLibrary` with its existing static members made
  public.

- [ ] **Step 1: Write the failing purity test**

Create `Tests/SkiVideoCoreTests/CorePurityTests.swift`:

```swift
import XCTest

final class CorePurityTests: XCTestCase {
    /// `Sources/SkiVideoCore` must stay portable. The iOS platform component is
    /// not installed on all dev machines, so we cannot rely on a cross-compile
    /// to catch AppKit or Process creeping in. This scans the sources instead.
    func testCoreSourcesAvoidPlatformSpecificAPIs() throws {
        let coreDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SkiVideoCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/SkiVideoCore", isDirectory: true)

        let forbidden = [
            "import AppKit",
            "import UIKit",
            "import SwiftUI",
            "Process(",
        ]

        let files = try FileManager.default
            .contentsOfDirectory(at: coreDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }

        XCTAssertFalse(files.isEmpty, "No sources found at \(coreDirectory.path)")

        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(
                    contents.contains(token),
                    "\(file.lastPathComponent) contains forbidden token '\(token)'"
                )
            }
        }
    }
}
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test
```

Expected: FAIL. The `SkiVideoCoreTests` target does not exist yet, so the build
errors out. That is the expected failure for this step.

- [ ] **Step 3: Rewrite Package.swift**

Replace `SkiVideoViewer/Package.swift` entirely:

```swift
// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "SkiVideoViewer",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
    ],
    products: [
        .library(name: "SkiVideoCore", targets: ["SkiVideoCore"]),
        .executable(name: "SkiVideoViewer", targets: ["SkiVideoViewer"]),
    ],
    targets: [
        .target(name: "SkiVideoCore"),
        .executableTarget(
            name: "SkiVideoViewer",
            dependencies: ["SkiVideoCore"]
        ),
        .testTarget(
            name: "SkiVideoCoreTests",
            dependencies: ["SkiVideoCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
```

- [ ] **Step 4: Move the two pure files and make them public**

```bash
cd SkiVideoViewer
mkdir -p Sources/SkiVideoCore Tests/SkiVideoCoreTests
git mv Sources/SkiVideoViewer/VideoLibrary.swift Sources/SkiVideoCore/VideoLibrary.swift
git mv Sources/SkiVideoViewer/SortingLibrary.swift Sources/SkiVideoCore/SortingLibrary.swift
git mv Tests/SkiVideoViewerTests/VideoLibraryTests.swift Tests/SkiVideoCoreTests/VideoLibraryTests.swift
```

In `Sources/SkiVideoCore/VideoLibrary.swift`, add `public` to every declaration
the app uses. The struct needs an explicit public initializer — the synthesized
memberwise init is internal:

```swift
public struct AthleteGroup: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let videos: [URL]

    public init(id: String, name: String, videos: [URL]) {
        self.id = id
        self.name = name
        self.videos = videos
    }
}

public enum VideoLibrary {
    public static let supportedExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "webm",
    ]

    public static func scan(_ root: URL) throws -> [AthleteGroup] {
        // body unchanged
    }
}

public enum ViewerError: LocalizedError {
    case invalidDirectory(String)
    case cannotReadDirectory(String)
    case noVideos

    public var errorDescription: String? {
        // body unchanged
    }
}
```

`scan` constructs `AthleteGroup(id:name:videos:)` at the end of its body; that
call site now resolves to the public initializer and needs no edit.

In `Sources/SkiVideoCore/SortingLibrary.swift`, mark `enum SortingLibrary`,
every `static func` on it, and the `SortingError` enum and its
`errorDescription` as `public`.

- [ ] **Step 5: Import the library from the executable**

Add `import SkiVideoCore` to the top of every file in
`Sources/SkiVideoViewer/` that references `AthleteGroup`, `VideoLibrary`,
`ViewerError`, `SortingLibrary`, or `SortingError`. Find them with:

```bash
cd SkiVideoViewer
grep -rln "AthleteGroup\|VideoLibrary\|ViewerError\|SortingLibrary\|SortingError" Sources/SkiVideoViewer/
```

Add `import SkiVideoCore` to `Tests/SkiVideoCoreTests/VideoLibraryTests.swift`
and change its `@testable import SkiVideoViewer` to `@testable import SkiVideoCore`.

- [ ] **Step 6: Run the tests**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test
```

Expected: PASS, including `testCoreSourcesAvoidPlatformSpecificAPIs` and all
existing `VideoLibraryTests`.

- [ ] **Step 7: Verify the app still builds**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && ./build_app.sh
```

Expected: prints the bundle path with no errors.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Split package into SkiVideoCore library and app executable"
```

---

### Task 2: Define the seam protocols

**Files:**
- Create: `Sources/SkiVideoCore/Seams.swift`
- Create: `Tests/SkiVideoCoreTests/FakeSeams.swift`

**Interfaces:**
- Consumes: Task 1's `SkiVideoCore` target.
- Produces: `public enum Step { case previous, next }`;
  `public enum ScrubDirection: Int { case backward = -1, forward = 1 }`;
  `public enum PlaybackIntent`; `public protocol PlaybackInputSource` with
  `var onIntent: ((PlaybackIntent) -> Void)? { get set }` and
  `func setEnabled(_ enabled: Bool)`; `public protocol FolderPicker` with
  `func pickFolder(startingAt: URL?) async -> URL?` and
  `func pickFile(ofType: UTType) async -> URL?`; `public protocol OAuthPresenter`
  with `func prepareRedirectURI() async throws -> String` and
  `func authorize(authorizationURL: URL, redirectURI: String) async throws -> URL`;
  `public protocol MediaPipeline` with
  `func writeMetadata(athlete: String, to url: URL) async throws` and
  `func resize(source: URL, destination: URL, athlete: String) async throws`.
  Test doubles `FakeInputSource`, `FakeFolderPicker`, `FakeMediaPipeline`,
  `TestClock`.

- [ ] **Step 1: Write the failing test**

Create `Tests/SkiVideoCoreTests/FakeSeams.swift`:

```swift
import Foundation
import UniformTypeIdentifiers
@testable import SkiVideoCore

@MainActor
final class FakeInputSource: PlaybackInputSource {
    var onIntent: ((PlaybackIntent) -> Void)?
    private(set) var isEnabled = true

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    /// Drives the model exactly as a real input source would.
    func emit(_ intent: PlaybackIntent) {
        onIntent?(intent)
    }
}

@MainActor
final class FakeFolderPicker: FolderPicker {
    var folderToReturn: URL?
    var fileToReturn: URL?
    private(set) var pickFolderCallCount = 0

    func pickFolder(startingAt: URL?) async -> URL? {
        pickFolderCallCount += 1
        return folderToReturn
    }

    func pickFile(ofType: UTType) async -> URL? {
        fileToReturn
    }
}

/// Deterministic replacement for `Date.init` so double-tap window tests do not
/// depend on wall-clock timing.
final class TestClock: @unchecked Sendable {
    private(set) var current = Date(timeIntervalSince1970: 1_000)

    func advance(by interval: TimeInterval) {
        current = current.addingTimeInterval(interval)
    }

    var now: () -> Date {
        { [self] in current }
    }
}

final class FakeMediaPipeline: MediaPipeline, @unchecked Sendable {
    private(set) var resizeCalls: [(source: URL, destination: URL, athlete: String)] = []
    private(set) var metadataCalls: [(athlete: String, url: URL)] = []
    var errorToThrow: Error?

    func writeMetadata(athlete: String, to url: URL) async throws {
        if let errorToThrow { throw errorToThrow }
        metadataCalls.append((athlete, url))
    }

    func resize(source: URL, destination: URL, athlete: String) async throws {
        if let errorToThrow { throw errorToThrow }
        resizeCalls.append((source, destination, athlete))
    }
}
```

Add to `Tests/SkiVideoCoreTests/CorePurityTests.swift`:

```swift
    func testSeamsAreReachableFromTests() {
        // Compile-time proof that the protocols exist and the fakes conform.
        let intents: [PlaybackIntent] = [
            .togglePlayback,
            .clip(.next),
            .athlete(.previous),
            .scrubBegan(.forward),
            .scrubEnded(.forward, performTap: true),
            .focusAthleteSearch,
            .openFolder,
        ]
        XCTAssertEqual(intents.count, 7)
        XCTAssertEqual(ScrubDirection.backward.rawValue, -1)
        XCTAssertEqual(ScrubDirection.forward.rawValue, 1)
    }
```

Add `@testable import SkiVideoCore` to the top of `CorePurityTests.swift`.

- [ ] **Step 2: Run it to confirm it fails**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test
```

Expected: FAIL — "cannot find type 'PlaybackInputSource' in scope" and similar
for each protocol.

- [ ] **Step 3: Write Seams.swift**

Create `Sources/SkiVideoCore/Seams.swift`:

```swift
import Foundation
import UniformTypeIdentifiers

// MARK: - Playback input

public enum Step: Sendable {
    case previous
    case next

    /// Offset applied to an index. Matches the `by:` arguments the models
    /// already take.
    public var offset: Int {
        switch self {
        case .previous: return -1
        case .next: return 1
        }
    }
}

public enum ScrubDirection: Int, Sendable {
    case backward = -1
    case forward = 1
}

public enum PlaybackIntent: Sendable {
    case togglePlayback
    case clip(Step)
    case athlete(Step)
    case scrubBegan(ScrubDirection)
    /// `performTap` is false when the scrub is being cancelled rather than
    /// released — for example when the app resigns active.
    case scrubEnded(ScrubDirection, performTap: Bool)
    case focusAthleteSearch
    case openFolder
}

/// Produces user intents from whatever input the platform offers: an `NSEvent`
/// monitor on macOS, gestures and key presses on iOS.
@MainActor
public protocol PlaybackInputSource: AnyObject {
    var onIntent: ((PlaybackIntent) -> Void)? { get set }
    func setEnabled(_ enabled: Bool)
}

// MARK: - File selection

@MainActor
public protocol FolderPicker: AnyObject {
    func pickFolder(startingAt: URL?) async -> URL?
    func pickFile(ofType: UTType) async -> URL?
}

// MARK: - OAuth

/// Runs the interactive part of the OAuth flow and returns the redirect URL
/// carrying the authorization code. The loopback server on macOS and
/// `ASWebAuthenticationSession` on iOS both satisfy this.
@MainActor
public protocol OAuthPresenter: AnyObject {
    /// Returns the redirect URI this presenter can receive on. macOS starts a
    /// loopback server and reports its port; iOS returns its custom scheme.
    /// Called before the authorization URL is built, because the URI is one of
    /// its query parameters.
    func prepareRedirectURI() async throws -> String

    func authorize(
        authorizationURL: URL,
        redirectURI: String
    ) async throws -> URL
}

// MARK: - Media

/// Transcoding operations. Backed by ffmpeg today, by AVFoundation in phase 2.
public protocol MediaPipeline: Sendable {
    func writeMetadata(athlete: String, to url: URL) async throws
    func resize(source: URL, destination: URL, athlete: String) async throws
}
```

- [ ] **Step 4: Run the tests**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add seam protocols and test doubles to SkiVideoCore"
```

---

### Task 3: Drive ViewerModel from intents

Keeps `ViewerModel.swift` in the executable target for now. Only its input
handling changes, so the diff stays reviewable.

**Files:**
- Modify: `Sources/SkiVideoViewer/ViewerModel.swift`
- Create: `Sources/SkiVideoViewer/Platform/AppKitInputSource.swift`
- Modify: `Sources/SkiVideoViewer/ContentView.swift:72`

**Interfaces:**
- Consumes: `PlaybackIntent`, `PlaybackInputSource`, `ScrubDirection`, `Step`.
- Produces: `ViewerModel.init(input: PlaybackInputSource, now: @escaping () -> Date = Date.init, holdThreshold: TimeInterval = 0.22)`;
  `ViewerModel.handle(_ intent: PlaybackIntent)`;
  `final class AppKitInputSource: PlaybackInputSource`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SkiVideoCoreTests/ViewerModelIntentTests.swift`. Note this file
lives in the core test target but tests a type still in the app target — it will
not compile until Task 6 moves `ViewerModel`. Create it now but keep it out of
the build by naming it `.swift.pending`:

```bash
cd SkiVideoViewer
mkdir -p Tests/SkiVideoCoreTests
touch Tests/SkiVideoCoreTests/ViewerModelIntentTests.swift.pending
```

Write this content into it. Task 6 renames it to `.swift`:

```swift
import AVFoundation
import XCTest
@testable import SkiVideoCore

@MainActor
final class ViewerModelIntentTests: XCTestCase {
    private var temporaryDirectory: URL!

    /// `VideoLibrary.scan` only inspects file extensions, so empty files are
    /// enough to populate the model. No playable media is required.
    private func makeLibrary() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let athlete = root.appendingPathComponent("Idun", isDirectory: true)
        try FileManager.default.createDirectory(at: athlete, withIntermediateDirectories: true)
        for name in ["a.mp4", "b.mp4"] {
            FileManager.default.createFile(
                atPath: athlete.appendingPathComponent(name).path,
                contents: Data()
            )
        }
        temporaryDirectory = root
        return root
    }

    override func tearDown() async throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    /// Task 4 adds the `folderPicker` parameter. This helper is written with it
    /// already present so the tests written here survive that task unchanged.
    private func makeModel() throws -> (ViewerModel, FakeInputSource, TestClock) {
        let input = FakeInputSource()
        let clock = TestClock()
        let model = ViewerModel(
            input: input,
            folderPicker: FakeFolderPicker(),
            now: clock.now,
            holdThreshold: 0.02
        )
        model.openDirectory(try makeLibrary())
        return (model, input, clock)
    }

    func testSingleTapSeeksOneSecond() throws {
        let (model, input, _) = try makeModel()

        input.emit(.scrubBegan(.forward))
        input.emit(.scrubEnded(.forward, performTap: true))

        XCTAssertEqual(model.lastSeekOffset ?? .nan, 1.0, accuracy: 0.0001)
        XCTAssertEqual(model.status, "Forward 1 seconds")
    }

    func testDoubleTapWithinWindowSeeksFiveSeconds() throws {
        let (model, input, clock) = try makeModel()

        input.emit(.scrubBegan(.forward))
        input.emit(.scrubEnded(.forward, performTap: true))

        clock.advance(by: 0.2)   // inside the 0.38s window

        input.emit(.scrubBegan(.forward))
        input.emit(.scrubEnded(.forward, performTap: true))

        XCTAssertEqual(model.lastSeekOffset ?? .nan, 5.0, accuracy: 0.0001)
        XCTAssertEqual(model.status, "Forward 5 seconds")
    }

    func testTapsOutsideWindowAreNotTreatedAsDoubleTap() throws {
        let (model, input, clock) = try makeModel()

        input.emit(.scrubBegan(.forward))
        input.emit(.scrubEnded(.forward, performTap: true))

        clock.advance(by: 0.5)   // outside the 0.38s window

        input.emit(.scrubBegan(.forward))
        input.emit(.scrubEnded(.forward, performTap: true))

        XCTAssertEqual(model.lastSeekOffset ?? .nan, 1.0, accuracy: 0.0001)
    }

    func testHoldEntersSlowScrub() async throws {
        let (model, input, _) = try makeModel()

        input.emit(.scrubBegan(.forward))
        try await Task.sleep(nanoseconds: 60_000_000)   // past the 0.02s threshold

        XCTAssertEqual(model.status, "Slow forward")
    }

    func testCancelledScrubDoesNotSeek() throws {
        let (model, input, _) = try makeModel()

        input.emit(.scrubBegan(.backward))
        input.emit(.scrubEnded(.backward, performTap: false))

        XCTAssertNil(model.lastSeekOffset)
    }

    func testClipIntentAdvancesVideoIndex() throws {
        let (model, input, _) = try makeModel()

        XCTAssertEqual(model.videoIndex, 0)
        input.emit(.clip(.next))
        XCTAssertEqual(model.videoIndex, 1)
        input.emit(.clip(.next))
        XCTAssertEqual(model.videoIndex, 0, "should wrap")
    }

    func testDisablingInputIsForwardedToTheSource() throws {
        let (model, input, _) = try makeModel()

        model.setKeyboardControlsEnabled(false)
        XCTAssertFalse(input.isEnabled)
    }
}
```

- [ ] **Step 2: Refactor ViewerModel to consume intents**

In `Sources/SkiVideoViewer/ViewerModel.swift`:

Add `import SkiVideoCore`. Delete the local `enum Direction` and replace every
use with `ScrubDirection`. Delete `startKeyboardMonitoring()`,
`handleKeyEvent(_:)`, the `keyboardMonitor` and `resignObserver` properties, and
the `NSEvent.removeMonitor` calls in `deinit`.

Add the injected dependencies and initializer:

```swift
    private let input: PlaybackInputSource
    private let now: () -> Date
    private let holdThreshold: TimeInterval

    /// Exposed so tests can assert on seeks without a playable asset.
    private(set) var lastSeekOffset: Double?

    public init(
        input: PlaybackInputSource,
        now: @escaping () -> Date = Date.init,
        holdThreshold: TimeInterval = 0.22
    ) {
        self.input = input
        self.now = now
        self.holdThreshold = holdThreshold
        driveFolderID = UserDefaults.standard.string(forKey: "driveFolderID") ?? ""
        clientSecretsPath = UserDefaults.standard.string(forKey: "driveClientSecretsPath") ?? ""
        self.input.onIntent = { [weak self] intent in
            self?.handle(intent)
        }
    }

    public func handle(_ intent: PlaybackIntent) {
        switch intent {
        case .togglePlayback:
            togglePlayback()
        case let .clip(step):
            changeVideo(by: step.offset)
        case let .athlete(step):
            changeAthlete(by: step.offset)
        case let .scrubBegan(direction):
            beginArrow(direction)
        case let .scrubEnded(_, performTap):
            endArrow(performTap: performTap)
        case .focusAthleteSearch, .openFolder:
            // Handled by the view layer, which owns focus and the picker.
            break
        }
    }
```

Change `setKeyboardControlsEnabled` to forward to the source:

```swift
    func setKeyboardControlsEnabled(_ enabled: Bool) {
        keyboardControlsEnabled = enabled
        input.setEnabled(enabled)
        if !enabled {
            endArrow(performTap: false)
        }
    }
```

Replace the hardcoded `0.22` in `beginArrow` with `holdThreshold`, and the
`Date()` calls in `performArrowTap` with `now()`.

Record seeks and fix the message inconsistency the spec calls out — the seek was
4.0 seconds while the status said 5:

```swift
    private func seek(seconds: Double) {
        lastSeekOffset = seconds
        guard player.currentItem != nil else { return }
        // rest of the body unchanged
    }

    private func performArrowTap(_ direction: ScrubDirection) {
        let timestamp = now()
        let isDoubleTap = lastTapDirection == direction
            && timestamp.timeIntervalSince(lastTapTime) <= 0.38
        let seconds = isDoubleTap ? 5.0 : 1.0
        seek(seconds: Double(direction.rawValue) * seconds)
        status = "\(direction == .forward ? "Forward" : "Back") \(isDoubleTap ? 5 : 1) seconds"
        lastTapDirection = isDoubleTap ? nil : direction
        lastTapTime = isDoubleTap ? .distantPast : timestamp
    }
```

Remove `startKeyboardMonitoring()` from `start(initialDirectory:)`; the input
source is wired up in `init` now.

- [ ] **Step 3: Write the AppKit input source**

Create `Sources/SkiVideoViewer/Platform/AppKitInputSource.swift`. It contains
exactly the key-code mapping deleted from `ViewerModel.handleKeyEvent`:

```swift
import AppKit
import SkiVideoCore

/// Translates the app's `NSEvent` stream into `PlaybackIntent`s. This is the
/// macOS half of the `PlaybackInputSource` seam.
@MainActor
final class AppKitInputSource: PlaybackInputSource {
    var onIntent: ((PlaybackIntent) -> Void)?

    private var monitor: Any?
    private var resignObserver: Any?
    private var isEnabled = true
    private var heldDirection: ScrubDirection?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cancelHold()
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { cancelHold() }
    }

    private func cancelHold() {
        guard let direction = heldDirection else { return }
        heldDirection = nil
        onIntent?(.scrubEnded(direction, performTap: false))
    }

    private func emit(_ intent: PlaybackIntent) {
        onIntent?(intent)
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard isEnabled else { return false }
        if event.window?.firstResponder is NSTextView { return false }
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            return false
        }

        if event.type == .keyUp {
            switch event.keyCode {
            case 123 where heldDirection == .backward:
                heldDirection = nil
                emit(.scrubEnded(.backward, performTap: true))
                return true
            case 124 where heldDirection == .forward:
                heldDirection = nil
                emit(.scrubEnded(.forward, performTap: true))
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
        case 123: // Left Arrow
            if !event.isARepeat {
                heldDirection = .backward
                emit(.scrubBegan(.backward))
            }
        case 124: // Right Arrow
            if !event.isARepeat {
                heldDirection = .forward
                emit(.scrubBegan(.forward))
            }
        default:
            return false
        }
        return true
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}
```

- [ ] **Step 4: Wire it up at the call site**

In `Sources/SkiVideoViewer/ContentView.swift`, change the model's construction.
`ContentView` receives the model from `SkiVideoViewerApp`, so edit
`Sources/SkiVideoViewer/SkiVideoViewerApp.swift:17`:

```swift
    @StateObject private var model = ViewerModel(input: AppKitInputSource())
```

- [ ] **Step 5: Build and smoke-test**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift build && ./build_app.sh && ./run.sh ~/Ski/Neuss2026
```

Expected: the app opens. Verify by hand: Space toggles playback, Up/Down change
clip, Page Up/Down change athlete, a Left/Right tap seeks 1 second, a quick
double-tap seeks 5 seconds, holding Left or Right enters slow scrub and releasing
restores the prior state, and typing in the athlete search box does not trigger
playback controls.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Drive ViewerModel from PlaybackIntent instead of NSEvent"
```

---

### Task 4: Put folder selection behind FolderPicker

**Files:**
- Modify: `Sources/SkiVideoViewer/ViewerModel.swift:106-138`
- Create: `Sources/SkiVideoViewer/Platform/AppKitFolderPicker.swift`
- Modify: `Sources/SkiVideoViewer/SkiVideoViewerApp.swift:17`

**Interfaces:**
- Consumes: `FolderPicker` from Task 2, `ViewerModel.init` from Task 3.
- Produces: `ViewerModel.init(input:folderPicker:now:holdThreshold:)`;
  `final class AppKitFolderPicker: FolderPicker`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/SkiVideoCoreTests/ViewerModelIntentTests.swift.pending`:

```swift
    func testChooseDirectoryOpensWhatThePickerReturns() async throws {
        let input = FakeInputSource()
        let picker = FakeFolderPicker()
        picker.folderToReturn = try makeLibrary()
        let model = ViewerModel(
            input: input,
            folderPicker: picker,
            now: Date.init,
            holdThreshold: 0.02
        )

        await model.chooseDirectory()

        XCTAssertEqual(picker.pickFolderCallCount, 1)
        XCTAssertEqual(model.athletes.count, 1)
        XCTAssertEqual(model.athletes.first?.name, "Idun")
    }

    func testChooseDirectoryDoesNothingWhenCancelled() async throws {
        let input = FakeInputSource()
        let picker = FakeFolderPicker()
        picker.folderToReturn = nil
        let model = ViewerModel(
            input: input,
            folderPicker: picker,
            now: Date.init,
            holdThreshold: 0.02
        )

        await model.chooseDirectory()

        XCTAssertEqual(picker.pickFolderCallCount, 1)
        XCTAssertTrue(model.athletes.isEmpty)
    }
```

- [ ] **Step 2: Replace the panels in ViewerModel**

Add the stored dependency and extend the initializer signature from Task 3:

```swift
    private let folderPicker: FolderPicker

    public init(
        input: PlaybackInputSource,
        folderPicker: FolderPicker,
        now: @escaping () -> Date = Date.init,
        holdThreshold: TimeInterval = 0.22
    ) {
        self.folderPicker = folderPicker
        // remaining body from Task 3, unchanged
    }
```

Replace `chooseDirectory()` (currently `ViewerModel.swift:106-117`) and
`chooseClientSecretsFile()` (`:126-138`) with:

```swift
    func chooseDirectory() async {
        guard let url = await folderPicker.pickFolder(startingAt: directory) else {
            return
        }
        openDirectory(url)
    }

    func chooseClientSecretsFile() async {
        guard let url = await folderPicker.pickFile(ofType: .json) else { return }
        clientSecretsPath = url.path
        UserDefaults.standard.set(clientSecretsPath, forKey: "driveClientSecretsPath")
    }
```

Add `import UniformTypeIdentifiers` for `.json`. In
`start(initialDirectory:)`, the auto-open branch becomes:

```swift
        } else if directory == nil {
            Task { [weak self] in
                await self?.chooseDirectory()
            }
        }
```

- [ ] **Step 3: Write the AppKit picker**

Create `Sources/SkiVideoViewer/Platform/AppKitFolderPicker.swift`:

```swift
import AppKit
import SkiVideoCore
import UniformTypeIdentifiers

@MainActor
final class AppKitFolderPicker: FolderPicker {
    func pickFolder(startingAt: URL?) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose organized video directory"
        panel.prompt = "Open"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = startingAt
        return panel.runModal() == .OK ? panel.url : nil
    }

    func pickFile(ofType type: UTType) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a file"
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [type]
        return panel.runModal() == .OK ? panel.url : nil
    }
}
```

- [ ] **Step 4: Update the call sites**

In `Sources/SkiVideoViewer/SkiVideoViewerApp.swift:17`:

```swift
    @StateObject private var model = ViewerModel(
        input: AppKitInputSource(),
        folderPicker: AppKitFolderPicker()
    )
```

`chooseDirectory` is now `async`, so wrap its three call sites in tasks —
`SkiVideoViewerApp.swift:37`, `ContentView.swift:66`, and any other hit from:

```bash
grep -rn "chooseDirectory\|chooseClientSecretsFile" Sources/SkiVideoViewer/
```

Each becomes `Task { await model.chooseDirectory() }`.

- [ ] **Step 5: Build and smoke-test**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift build && ./build_app.sh && ./run.sh
```

Expected: the open panel appears on launch, Cmd-O reopens it, and the Google
Drive sheet's client-secret chooser still works.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Put folder selection behind the FolderPicker seam"
```

---

### Task 5: Put OAuth presentation behind OAuthPresenter

**Files:**
- Modify: `Sources/SkiVideoViewer/GoogleDriveSupport.swift:221-284, 400-490`
- Create: `Sources/SkiVideoViewer/Platform/AppKitOAuthPresenter.swift`

**Interfaces:**
- Consumes: `OAuthPresenter` from Task 2.
- Produces: `GoogleDriveClient.connect(clientSecretsURL:presenter:)`;
  `final class AppKitOAuthPresenter: OAuthPresenter` containing the loopback
  server.

- [ ] **Step 1: Move the loopback server out of core's future path**

Cut the entire `OAuthCallbackServer` class and the `import Network` line from
`Sources/SkiVideoViewer/GoogleDriveSupport.swift` and paste them into a new
`Sources/SkiVideoViewer/Platform/AppKitOAuthPresenter.swift`, wrapped by the
presenter:

The file becomes the moved `OAuthCallbackServer` class plus this wrapper. The
two-phase API exists because the loopback port is not known until the server
starts, and the port is part of the redirect URI that goes into the
authorization URL.

```swift
import AppKit
import Foundation
import Network
import SkiVideoCore

/// macOS runs the OAuth redirect through a short-lived loopback HTTP server and
/// the system browser. iOS will use `ASWebAuthenticationSession` instead.
@MainActor
final class AppKitOAuthPresenter: OAuthPresenter {
    private var server: OAuthCallbackServer?

    func prepareRedirectURI() async throws -> String {
        let server = try OAuthCallbackServer()
        self.server = server
        let port = try await server.start()
        return "http://127.0.0.1:\(port)"
    }

    func authorize(authorizationURL: URL, redirectURI: String) async throws -> URL {
        guard let server else {
            throw DriveError.oauthCallback("Redirect URI was not prepared.")
        }
        NSWorkspace.shared.open(authorizationURL)
        return try await server.waitForCallback()
    }
}

// The full OAuthCallbackServer class, moved verbatim from
// GoogleDriveSupport.swift, goes below this line.
```

This matches the two-method `OAuthPresenter` defined in Task 2; no protocol
change is needed here.

- [ ] **Step 2: Thread the presenter through GoogleOAuth**

In `GoogleDriveSupport.swift`, change `GoogleOAuth.authorize` to take the
presenter and use it in place of the inline server and `NSWorkspace` call:

```swift
    static func authorize(
        client: GoogleOAuthClient.Details,
        presenter: OAuthPresenter
    ) async throws -> String {
        if let refreshToken = KeychainTokenStore.load(account: client.clientID) {
            do {
                return try await refreshAccessToken(refreshToken: refreshToken, client: client)
            } catch {
                KeychainTokenStore.remove(account: client.clientID)
            }
        }

        let redirectURI = try await presenter.prepareRedirectURI()
        let state = randomURLSafeString(byteCount: 24)
        let verifier = randomURLSafeString(byteCount: 48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        var components = URLComponents(string: client.authURI)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let authorizationURL = components.url else { throw DriveError.invalidClientSecrets }

        let callback = try await presenter.authorize(
            authorizationURL: authorizationURL,
            redirectURI: redirectURI
        )

        // remaining validation and token exchange unchanged
    }
```

Add the `presenter` parameter to `GoogleDriveClient.connect` at
`GoogleDriveSupport.swift:59` and pass it down.

- [ ] **Step 3: Update the caller**

In `ViewerModel.connectGoogleDrive()` (`ViewerModel.swift:158`), the client is
constructed. Add a stored `oauthPresenter: OAuthPresenter` dependency to
`ViewerModel`, initialized alongside the others, and pass it:

```swift
    let drive = try await GoogleDriveClient.connect(
        clientSecretsURL: clientSecretsURL,
        presenter: oauthPresenter
    )
```

Update `SkiVideoViewerApp.swift:17`:

```swift
    @StateObject private var model = ViewerModel(
        input: AppKitInputSource(),
        folderPicker: AppKitFolderPicker(),
        oauthPresenter: AppKitOAuthPresenter()
    )
```

- [ ] **Step 4: Verify GoogleDriveSupport is AppKit-free**

```bash
cd SkiVideoViewer && grep -n "AppKit\|NSWorkspace\|import Network" Sources/SkiVideoViewer/GoogleDriveSupport.swift
```

Expected: no output.

- [ ] **Step 5: Build and test the Drive flow**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift build && ./build_app.sh && ./run.sh
```

Expected: "Open Google Drive…" still completes a sign-in and lists athletes.
Because a cached refresh token skips the browser entirely, delete the Keychain
item first to exercise the full path:

```bash
security delete-generic-password -s "SkiVideoViewer.GoogleDrive" 2>/dev/null || true
```

Confirm the service name against `KeychainTokenStore` in
`GoogleDriveSupport.swift` before running this; adjust `-s` if it differs.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Put OAuth presentation behind the OAuthPresenter seam"
```

---

### Task 6: Move ViewerModel and Drive support into the core

**Files:**
- Move: `Sources/SkiVideoViewer/ViewerModel.swift` → `Sources/SkiVideoCore/ViewerModel.swift`
- Move: `Sources/SkiVideoViewer/GoogleDriveSupport.swift` → `Sources/SkiVideoCore/GoogleDriveSupport.swift`
- Rename: `Tests/SkiVideoCoreTests/ViewerModelIntentTests.swift.pending` → `.swift`

**Interfaces:**
- Consumes: Tasks 3, 4, 5.
- Produces: `public final class ViewerModel: ObservableObject` with all members
  the views touch made public.

- [ ] **Step 1: Move the files**

```bash
cd SkiVideoViewer
git mv Sources/SkiVideoViewer/ViewerModel.swift Sources/SkiVideoCore/ViewerModel.swift
git mv Sources/SkiVideoViewer/GoogleDriveSupport.swift Sources/SkiVideoCore/GoogleDriveSupport.swift
git mv Tests/SkiVideoCoreTests/ViewerModelIntentTests.swift.pending \
       Tests/SkiVideoCoreTests/ViewerModelIntentTests.swift
```

- [ ] **Step 2: Run the build to enumerate what must become public**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift build 2>&1 | grep -c "error:"
```

Expected: a non-zero count. Every error is an access-level violation in the app
target. This is the checklist for the next step, not a failure to debug.

- [ ] **Step 3: Add public access modifiers**

Mark `public` on `ViewerModel` and every member `ContentView`,
`GoogleDriveSheet`, `SkiVideoViewerApp`, and the window controllers reference.
From reading those views, that is at minimum: `directory`, `athletes`,
`selectedAthleteID`, `athleteQuery`, `driveFolderID`, `clientSecretsPath`,
`isConnectingToDrive`, `isUsingGoogleDrive`, `videoIndex`, `status`,
`errorMessage`, `player`, `currentAthlete`, `filteredAthletes`, `currentVideo`,
`currentPlaybackURL`, `comparisonLibrary`, `clipDescription`, `start`,
`chooseDirectory`, `setKeyboardControlsEnabled`, `chooseClientSecretsFile`,
`connectGoogleDrive`, `openDirectory`, `selectAthlete`, `changeVideo`,
`changeAthlete`, `selectFirstMatchingAthlete`, `togglePlayback`, `handle`.

`@Published` properties declared `private(set)` become `public private(set)`.

Also mark `public` on `DriveMedia`, `DriveError`, `GoogleDriveClient`, and
`ComparisonAthleteChoice` / `ComparisonVideoChoice` if the compiler asks —
those two live in `ComparisonModel.swift` and move in Task 7, so for now add
`public` in place.

Repeat `swift build` until the error count is zero.

- [ ] **Step 4: Run the tests**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test
```

Expected: PASS, including all of `ViewerModelIntentTests` and the purity test —
`ViewerModel.swift` no longer imports AppKit.

- [ ] **Step 5: Verify the app**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && ./build_app.sh && ./run.sh ~/Ski/Neuss2026
```

Expected: identical behaviour to before the refactor.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Move ViewerModel and Drive support into SkiVideoCore"
```

---

### Task 7: Move ComparisonModel into the core

**Files:**
- Modify: `Sources/SkiVideoViewer/ComparisonModel.swift:63, 259, 344`
- Move: `Sources/SkiVideoViewer/ComparisonModel.swift` → `Sources/SkiVideoCore/ComparisonModel.swift`
- Move: `Tests/SkiVideoViewerTests/ComparisonModelTests.swift` → `Tests/SkiVideoCoreTests/ComparisonModelTests.swift`
- Modify: `Sources/SkiVideoViewer/ComparisonWindowController.swift`

**Interfaces:**
- Consumes: `PlaybackInputSource`, `FolderPicker`, `AppKitInputSource`,
  `AppKitFolderPicker`.
- Produces: `public final class ComparisonModel` with
  `public init(initialLeftVideo:openLibrary:input:folderPicker:)`;
  `public enum ComparisonLayout`, `public enum OverlayBlend`,
  `public enum ComparisonSide`.

- [ ] **Step 1: Replace the NSOpenPanel**

`chooseVideo(side:)` at `ComparisonModel.swift:99-110` currently runs a panel and
calls `load(url, side:)`. Add a `folderPicker: FolderPicker` dependency and
replace the whole method with:

```swift
    func chooseVideo(side: ComparisonSide) async {
        guard let folderPicker else { return }
        guard let url = await folderPicker.pickFile(ofType: .movie) else { return }
        load(url, side: side)
    }
```

`UTType.movie` is the same content type the panel used at `:106`, so the set of
selectable files is unchanged. The panel's per-side title is lost; that is
acceptable, and the calling button already says which side it targets.

`chooseVideo` is now `async`. Wrap its call sites in `ComparisonView.swift` in
`Task { await ... }`; find them with:

```bash
grep -n "chooseVideo" Sources/SkiVideoViewer/ComparisonView.swift
```

- [ ] **Step 2: Replace the NSEvent monitor**

Delete `startKeyboardMonitoring()` (`ComparisonModel.swift:344`) and the
`NSEvent.removeMonitor` calls (`:259` and in `deinit`). Add an
`input: PlaybackInputSource` dependency wired in `init`, and a handler covering
the three keys the comparison window bound:

```swift
    private func handle(_ intent: PlaybackIntent) {
        switch intent {
        case .togglePlayback:
            if leftPlayer.rate == 0 && rightPlayer.rate == 0 {
                playSynced()
            } else {
                pauseBoth()
            }
        case .scrubBegan(.backward):
            seekSynced(by: -1)
        case .scrubBegan(.forward):
            seekSynced(by: 1)
        default:
            break
        }
    }
```

The comparison window never had hold-to-scrub, so acting on `.scrubBegan` and
ignoring `.scrubEnded` reproduces its existing behaviour exactly.

- [ ] **Step 3: Update ComparisonWindowController**

`ComparisonWindowController.show(...)` constructs `ComparisonView`, which
constructs `ComparisonModel`. Pass fresh seam instances through:

```swift
        let root = ComparisonView(
            initialLeftVideo: initialLeftVideo,
            openLibrary: openLibrary,
            input: AppKitInputSource(),
            folderPicker: AppKitFolderPicker(),
            closeWindow: { [weak self] in self?.close() }
        )
```

Add the two matching parameters to `ComparisonView.init` and forward them into
the `ComparisonModel` it builds in its `StateObject` wrapper.

- [ ] **Step 4: Move the files and make them public**

```bash
cd SkiVideoViewer
git mv Sources/SkiVideoViewer/ComparisonModel.swift Sources/SkiVideoCore/ComparisonModel.swift
git mv Tests/SkiVideoViewerTests/ComparisonModelTests.swift Tests/SkiVideoCoreTests/ComparisonModelTests.swift
swift build 2>&1 | grep "error:"
```

Add `public` to each type and member the error list names. Change the test file's
`@testable import SkiVideoViewer` to `@testable import SkiVideoCore`.

`ComparisonModelTests` calls `ComparisonModel()` with no arguments. Give the new
parameters defaults so those tests keep compiling unchanged:

```swift
    public init(
        initialLeftVideo: URL? = nil,
        openLibrary: [ComparisonAthleteChoice] = [],
        input: PlaybackInputSource? = nil,
        folderPicker: FolderPicker? = nil
    )
```

Store them as optionals and guard before use; a comparison window without an
input source simply has no keyboard control, which is correct for a unit test.

- [ ] **Step 5: Run the tests**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test
```

Expected: PASS, including the four existing `ComparisonModelTests` and the
purity test.

- [ ] **Step 6: Verify the comparison window**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && ./build_app.sh && ./run.sh ~/Ski/Neuss2026
```

Expected: "Compare Videos…" opens the window; both side-by-side and overlay
layouts work; the opacity slider and the Blend/Difference picker behave as
before; Space and Left/Right control synced playback.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Move ComparisonModel into SkiVideoCore"
```

---

### Task 8: Put ffmpeg behind MediaPipeline

**Files:**
- Modify: `Sources/SkiVideoViewer/SortingModel.swift:320-374`
- Create: `Sources/SkiVideoViewer/Platform/FFmpegMediaPipeline.swift`

**Interfaces:**
- Consumes: `MediaPipeline` from Task 2.
- Produces: `struct FFmpegMediaPipeline: MediaPipeline`;
  `SortingModel` gains a `mediaPipeline: MediaPipeline` dependency.

- [ ] **Step 1: Extract the ffmpeg runner verbatim**

Create `Sources/SkiVideoViewer/Platform/FFmpegMediaPipeline.swift`. Move
`writeAthleteMetadata`, `resize`, and `runFFmpeg` out of `SortingModel` with
their bodies and comments unchanged:

```swift
import Foundation
import SkiVideoCore

/// The macOS ffmpeg-backed pipeline. Phase 2 replaces this with an
/// AVFoundation implementation that also works on iOS.
struct FFmpegMediaPipeline: MediaPipeline {
    func writeMetadata(athlete: String, to source: URL) async throws {
        let temporary = source.deletingLastPathComponent().appendingPathComponent(
            ".metadata-\(UUID().uuidString).\(source.pathExtension)"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.runFFmpeg([
            "-i", source.path,
            // Camera files can contain telemetry/data tracks that MP4 cannot remux.
            // Preserve the playable streams and the container metadata, but omit
            // those proprietary tracks from the tagged copy.
            "-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0", "-c", "copy",
            "-metadata", "title=\(athlete)",
            "-metadata", "artist=\(athlete)",
            "-metadata", "comment=Athlete: \(athlete)",
            temporary.path,
        ])
        _ = try FileManager.default.replaceItemAt(source, withItemAt: temporary)
    }

    func resize(source: URL, destination: URL, athlete: String) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.runFFmpeg([
            "-i", source.path,
            "-vf", "scale=w=1920:h=1080:force_original_aspect_ratio=decrease",
            "-metadata", "title=\(athlete)",
            "-metadata", "artist=\(athlete)",
            "-metadata", "comment=Athlete: \(athlete)",
            destination.path,
        ])
    }

    private static func runFFmpeg(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"] + arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "SkiVideoViewer.Resize",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: message?.isEmpty == false
                        ? message! : "ffmpeg failed",
                ]
            )
        }
    }
}
```

- [ ] **Step 2: Call the pipeline from SortingModel**

Add a `private let mediaPipeline: MediaPipeline` dependency with an initializer
parameter.

`enqueueResize` (`SortingModel.swift:259-279`) currently calls the two static
ffmpeg methods synchronously inside an `OperationQueue` block. The pipeline
methods are `async`, and simply spawning a `Task` inside the operation would let
the operation return immediately, breaking the `maxConcurrentOperationCount = 1`
serialization that the UI copy promises ("Only one ffmpeg job runs at once").

Bridge with a semaphore so the operation stays alive for the whole job:

```swift
    private func enqueueResize(source: URL, destination: URL, athlete: String) {
        queuedResizes += 1
        let pipeline = mediaPipeline
        resizeQueue.addOperation { [weak self] in
            let semaphore = DispatchSemaphore(value: 0)
            let box = ResultBox()
            Task.detached {
                do {
                    try await pipeline.writeMetadata(athlete: athlete, to: source)
                    try await pipeline.resize(
                        source: source,
                        destination: destination,
                        athlete: athlete
                    )
                    box.result = .success(())
                } catch {
                    box.result = .failure(error)
                }
                semaphore.signal()
            }
            // Blocks this operation's thread, not the main thread, so the queue
            // still runs exactly one resize at a time.
            semaphore.wait()
            let result = box.result ?? .failure(ViewerError.noVideos)

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.completedResizes += 1
                if case let .failure(error) = result {
                    self.failedResizes.append(
                        "\(source.lastPathComponent): \(error.localizedDescription)"
                    )
                }
                self.completeIfPossible()
            }
        }
    }
```

Add the small box type at file scope, since the semaphore hand-off crosses a
concurrency domain:

```swift
private final class ResultBox: @unchecked Sendable {
    var result: Result<Void, Error>?
}
```

`completeIfPossible()` and the `queuedResizes` / `completedResizes` /
`failedResizes` bookkeeping are untouched.

- [ ] **Step 3: Update the construction site**

`SortingWindowController.show(...)` builds `SortingSheet`, which builds
`SortingModel`. Pass `FFmpegMediaPipeline()` through both, alongside the
`AppKitInputSource()` and `AppKitFolderPicker()` that Task 9 will need.

- [ ] **Step 4: Build and run a real sort**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift build && ./build_app.sh && ./run.sh
```

Open "Sort & Resize…", point it at a copy of a folder with two or three raw
clips, tag them, and confirm `organized/` and `organized_resize/` are produced
with the same contents as before. Use a copy — this moves files.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Put ffmpeg behind the MediaPipeline seam"
```

---

### Task 9: Move SortingModel into the core

**Files:**
- Modify: `Sources/SkiVideoViewer/SortingModel.swift:81-96, 215, 302-318, 376`
- Move: `Sources/SkiVideoViewer/SortingModel.swift` → `Sources/SkiVideoCore/SortingModel.swift`

**Interfaces:**
- Consumes: Tasks 2, 4, 8.
- Produces: `public final class SortingModel` with
  `public init(input:folderPicker:mediaPipeline:defaultNamesURL:)`.

- [ ] **Step 1: Replace the two NSOpenPanels**

`chooseSourceDirectory()` (`SortingModel.swift:81`) becomes:

```swift
    func chooseSourceDirectory() async {
        guard let url = await folderPicker.pickFolder(startingAt: nil) else { return }
        sourcePath = url.path
        if let firstVideo = try? SortingLibrary.rawVideos(in: url).first {
            eventDate = SortingLibrary.suggestedEventDate(from: firstVideo)
        }
    }
```

`chooseNamesFile()` (`:96`) becomes:

```swift
    func chooseNamesFile() async {
        guard let url = await folderPicker.pickFile(ofType: .plainText) else { return }
        namesPath = url.path
        reloadNames()
    }
```

Wrap both call sites in `SortingSheet.swift` in `Task { await ... }`.

- [ ] **Step 2: Replace the NSEvent monitor**

Delete `startKeyboardMonitoring()` (`:302-318`) and the `NSEvent.removeMonitor`
calls at `:215`, `:376`, and in `deinit`. Add an `input: PlaybackInputSource`
dependency and handle only what the sorting window bound — a ±5 second seek:

```swift
    private func handle(_ intent: PlaybackIntent) {
        guard isSorting else { return }
        switch intent {
        case .scrubBegan(.backward):
            seek(seconds: -5)
        case .scrubBegan(.forward):
            seek(seconds: 5)
        default:
            break
        }
    }
```

Replace the `startKeyboardMonitoring()` call in `beginSorting()` with
`input.setEnabled(true)`, and the teardown in `stopPlayback()` with
`input.setEnabled(false)`.

- [ ] **Step 3: Remove the home-directory default**

`SortingModel.init` (`:39-42`) reads `~/Ski/athletes.txt`. Inject it instead:

```swift
    public init(
        input: PlaybackInputSource,
        folderPicker: FolderPicker,
        mediaPipeline: MediaPipeline,
        defaultNamesURL: URL?
    ) {
        self.input = input
        self.folderPicker = folderPicker
        self.mediaPipeline = mediaPipeline
        namesPath = defaultNamesURL.map { url in
            FileManager.default.fileExists(atPath: url.path) ? url.path : ""
        } ?? ""
        reloadNames()
        self.input.onIntent = { [weak self] intent in
            self?.handle(intent)
        }
    }
```

In `SortingWindowController.show(...)`, pass the macOS default explicitly:

```swift
        defaultNamesURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Ski/athletes.txt")
```

`persistNewAthlete` writes to `namesPath`; it needs no change.

- [ ] **Step 4: Move the file and make it public**

```bash
cd SkiVideoViewer
git mv Sources/SkiVideoViewer/SortingModel.swift Sources/SkiVideoCore/SortingModel.swift
swift build 2>&1 | grep "error:"
```

Add `public` to each type and member the errors name.

- [ ] **Step 5: Run the full suite**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test
```

Expected: PASS. The purity test now covers six files in `SkiVideoCore` and
confirms none references AppKit or `Process`.

- [ ] **Step 6: Confirm the core is clean**

```bash
cd SkiVideoViewer && ls Sources/SkiVideoCore/ && grep -rn "AppKit\|UIKit\|SwiftUI\|Process(" Sources/SkiVideoCore/
```

Expected: the file listing, then no grep output.

- [ ] **Step 7: Full manual regression**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && ./build_app.sh && ./run.sh ~/Ski/Neuss2026
```

Walk the whole app: open a folder, switch athletes and clips by keyboard and by
mouse, tap and hold the arrows, open the comparison window in both layouts, run
a sort-and-resize over a copied folder, and connect to Google Drive. Behaviour
must be indistinguishable from the pre-refactor app.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Move SortingModel into SkiVideoCore, completing phase 1"
```

---

## Phase 1 done when

- `Sources/SkiVideoCore/` holds `VideoLibrary`, `SortingLibrary`, `Seams`,
  `ViewerModel`, `ComparisonModel`, `SortingModel`, `GoogleDriveSupport`, and
  imports no UI framework and no `Process`.
- `Sources/SkiVideoViewer/Platform/` holds the four AppKit seam
  implementations.
- `swift test` passes, including the purity test, the ported
  `VideoLibraryTests` and `ComparisonModelTests`, and the new
  `ViewerModelIntentTests`.
- `./build_app.sh` produces a working app with no behaviour change.

## Next phases

Each gets its own plan, written when its predecessor lands:

2. Replace `FFmpegMediaPipeline` with an AVFoundation implementation and move it
   into the core. Includes the export-preset spike.
3. Xcode project with a two-destination app target. **Blocked** until the iOS
   platform component is installed in Xcode.
4. iPad input — gestures then hardware keyboard. Includes the reverse-scrub
   performance spike, which should run as early as the iOS platform allows.
5. iPad secondary screens, the `OverlayPlayerView` UIKit counterpart, and layout
   adaptation. Includes the `CALayer.compositingFilter` spike.
6. `ASWebAuthenticationSession` Drive auth.
