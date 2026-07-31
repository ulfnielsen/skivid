# iPadOS Phase 3: Xcode Project and iPad Target — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An iPad app that launches on the simulator, picks a video folder through the document picker, lists athletes, and plays a clip — with the macOS app unchanged.

**Architecture:** XcodeGen turns a reviewable `project.yml` into an `.xcodeproj` with two app targets, `SkiVideoViewer-macOS` and `SkiVideoViewer-iPad`. Both depend on the existing `SkiVideoCore` package and compile the same platform-free SwiftUI views; each takes only its own platform directory, so no `#if os(...)` guards are needed inside files. The one shared view that still reaches into AppKit — `ContentView`, via two `NSWindow` controllers — is decoupled behind a `SecondaryScreenPresenter` seam first.

**Tech Stack:** Swift 6.1 (language mode 5), SwiftPM, XcodeGen 2.45.4, UIKit, AVKit, XCTest, `xcrun simctl`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-31-ipados-support-design.md`. Phase 1 outcomes and carried-forward items: `docs/superpowers/specs/2026-07-31-ipados-phase1-outcomes.md`.
- **The macOS app's behaviour must not change.** Phase 3 adds a platform; it does not alter the existing one.
- `Sources/SkiVideoCore/` must never import `AppKit`, `UIKit`, or `SwiftUI`, nor reference `Process`. `CorePurityTests` enforces the text scan; the `SkiVideoCore-iOS` scheme enforces it by real compilation.
- Swift language mode stays `.v5`. Do not migrate to Swift 6 strict concurrency.
- Minimum versions: macOS 13, iOS 17. Do not raise either.
- **Every shell running `swift build`, `swift test`, `xcodebuild` or `xcrun` must first run
  `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.** The machine's active developer directory is the Command Line Tools, which ship no XCTest and no `simctl`.
- Baselines that must not regress: `swift test` = 72 tests, 0 failures. `xcodebuild -scheme SkiVideoCore-iOS -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' test` = 44 tests, 0 failures.
- Verification is automated. On iOS this now includes real UI verification via `xcrun simctl` — install, launch, screenshot. Use it; do not fall back to "it compiles".
- Do NOT perform a real Google sign-in, open a browser, touch the Keychain, or make network calls to Google. Drive remains out of scope until phase 6.
- **Do NOT run any sorting flow against `~/Ski` — it MOVES files.** Temp directories only.
- Nothing becomes `public` without a real consumer. Verify by grep.

## Out of scope, deliberately

Touch gestures and hardware-keyboard input (phase 4), Compare and Sort on iPad (phase 5), Drive auth (phase 6), AVFoundation replacing ffmpeg (phase 2). The iPad's `PlaybackInputSource` in this phase is an inert stub; the app is driven by the on-screen list and transport buttons that already exist in `ContentView`.

## File Structure

**Reorganised (Task 1)** — `Sources/SkiVideoViewer/` gains three directories:

| Path | Contents | Targets |
|---|---|---|
| `Shared/` | `ContentView`, `ComparisonView`, `GoogleDriveSheet`, `SortingSheet` | both |
| `macOS/` | `SkiVideoViewerApp`, `NativePlayerView`, `OverlayPlayerView`, `ComparisonWindowController`, `SortingWindowController`, `AppKitInputSource`, `AppKitFolderPicker`, `AppKitOAuthPresenter`, `FFmpegMediaPipeline`, `MacSecondaryScreenPresenter` | macOS only |
| `iOS/` | `SkiVideoViewerApp_iOS`, `NativePlayerView` (UIKit), `UIKitFolderPicker`, `InertInputSource`, `UnavailableOAuthPresenter`, `NoSecondaryScreenPresenter` | iPad only |

**Created**

| File | Responsibility |
|---|---|
| `SkiVideoViewer/project.yml` | XcodeGen spec — the source of truth for both app targets |
| `Sources/SkiVideoCore/SecondaryScreens.swift` | `SecondaryScreenPresenter` protocol and its payload types |
| `Sources/SkiVideoViewer/macOS/MacSecondaryScreenPresenter.swift` | Wraps the two existing `NSWindow` controllers |
| `Sources/SkiVideoViewer/iOS/*` | The iPad shell listed above |
| `Tests/SkiVideoViewerTests/SecondaryScreenPresenterTests.swift` | Covers the seam on macOS |
| `Tests/SkiVideoCoreTests/SecondaryScreensTests.swift` | Covers `canPresent` gating, runs on iOS too |
| `scripts/ipad-smoke.sh` | Boots a simulator, installs, launches, screenshots — the phase's UI gate |

**Generated, not committed:** `SkiVideoViewer.xcodeproj` — `project.yml` is the source of truth. Task 3 adds it to `.gitignore`.

---

### Task 1: Reorganise sources by platform

Pure file moves plus a `Package.swift` exclusion. No behaviour change, no new types.

**Files:**
- Modify: `SkiVideoViewer/Package.swift`
- Move: 4 view files into `Sources/SkiVideoViewer/Shared/`
- Move: 9 files into `Sources/SkiVideoViewer/macOS/`

**Interfaces:**
- Consumes: nothing.
- Produces: the directory layout every later task depends on. No API change — all moved types keep their names and access levels.

- [ ] **Step 1: Move the platform-free views**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer/Sources/SkiVideoViewer
mkdir -p Shared macOS iOS
git mv ContentView.swift ComparisonView.swift GoogleDriveSheet.swift SortingSheet.swift Shared/
```

- [ ] **Step 2: Move the macOS-only files**

```bash
cd SkiVideoViewer/Sources/SkiVideoViewer
git mv SkiVideoViewerApp.swift NativePlayerView.swift OverlayPlayerView.swift \
       ComparisonWindowController.swift SortingWindowController.swift macOS/
git mv Platform/AppKitInputSource.swift Platform/AppKitFolderPicker.swift \
       Platform/AppKitOAuthPresenter.swift Platform/FFmpegMediaPipeline.swift macOS/
rmdir Platform
```

- [ ] **Step 3: Exclude the iOS directory from the SwiftPM macOS target**

`Sources/SkiVideoViewer/iOS/` will hold UIKit code that cannot compile on macOS. SwiftPM includes subdirectories recursively, so it must be excluded explicitly. In `SkiVideoViewer/Package.swift`, change the executable target to:

```swift
        .executableTarget(
            name: "SkiVideoViewer",
            dependencies: ["SkiVideoCore"],
            // The iPad shell is built by the Xcode project, not by SwiftPM.
            // SwiftPM would otherwise try to compile UIKit sources for macOS.
            exclude: ["iOS"]
        ),
```

Create a placeholder so the directory survives the commit and the exclusion is exercised:

```bash
cd SkiVideoViewer/Sources/SkiVideoViewer/iOS
printf '// iPad shell lives here. Built by SkiVideoViewer.xcodeproj, excluded from SwiftPM.\n' > README.swift
```

- [ ] **Step 4: Verify nothing broke**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test 2>&1 | tail -3 && ./build_app.sh
```

Expected: 72 tests, 0 failures, and the bundle path printed. Swift does not care which directory a file lives in, so this is a pure move.

- [ ] **Step 5: Confirm the core scheme still passes on iOS**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer
xcodebuild -scheme SkiVideoCore-iOS \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' test 2>&1 \
  | grep -E "Executed [0-9]+ test|TEST (SUCCEEDED|FAILED)" | tail -3
```

Expected: 44 tests, 0 failures, `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Reorganise app sources into Shared, macOS and iOS directories"
```

---

### Task 2: Decouple ContentView from the AppKit window controllers

`ContentView` is otherwise platform-free but holds `@StateObject` `SortingWindowController` and `ComparisonWindowController` (`Shared/ContentView.swift:9-10`) and calls `.show(...)` on them (`:24`, `:38`). This is the only thing stopping a shared view from compiling for iOS, and the fix is the `SecondaryPresenter` seam the spec already calls for.

**Files:**
- Create: `Sources/SkiVideoCore/SecondaryScreens.swift`
- Create: `Sources/SkiVideoViewer/macOS/MacSecondaryScreenPresenter.swift`
- Modify: `Sources/SkiVideoViewer/Shared/ContentView.swift:9-10, 20-48`
- Modify: `Sources/SkiVideoViewer/macOS/SkiVideoViewerApp.swift`
- Create: `Tests/SkiVideoCoreTests/SecondaryScreensTests.swift`
- Create: `Tests/SkiVideoViewerTests/SecondaryScreenPresenterTests.swift`

**Interfaces:**
- Consumes: `ComparisonAthleteChoice` from `Sources/SkiVideoCore/ComparisonChoices.swift`.
- Produces: `public protocol SecondaryScreenPresenter` with `var canPresent: Bool { get }`, `func presentComparison(initialLeftVideo: URL?, openLibrary: [ComparisonAthleteChoice], onClose: @escaping () -> Void)`, `func presentSorting(openResizedLibrary: @escaping (URL) -> Void, onClose: @escaping () -> Void)`; `final class MacSecondaryScreenPresenter: SecondaryScreenPresenter`; `ContentView.init(model:initialDirectory:secondaryScreens:)`.

- [ ] **Step 1: Write the failing test for the protocol's gating contract**

Create `Tests/SkiVideoCoreTests/SecondaryScreensTests.swift`:

```swift
import XCTest
@testable import SkiVideoCore

@MainActor
final class SecondaryScreensTests: XCTestCase {
    /// Stands in for the iPad's phase-3 presenter, which cannot show anything yet.
    private final class UnavailablePresenter: SecondaryScreenPresenter {
        var canPresent: Bool { false }
        private(set) var comparisonCalls = 0
        private(set) var sortingCalls = 0

        func presentComparison(
            initialLeftVideo: URL?,
            openLibrary: [ComparisonAthleteChoice],
            onClose: @escaping () -> Void
        ) {
            comparisonCalls += 1
        }

        func presentSorting(
            openResizedLibrary: @escaping (URL) -> Void,
            onClose: @escaping () -> Void
        ) {
            sortingCalls += 1
        }
    }

    func testCanPresentGatesTheUI() {
        let presenter = UnavailablePresenter()
        XCTAssertFalse(
            presenter.canPresent,
            "a presenter that cannot show screens must say so, so the view hides its buttons"
        )
    }

    func testAPresenterThatCannotPresentIsStillSafeToCall() {
        // The view hides the buttons, but a stray call must not trap.
        let presenter = UnavailablePresenter()
        presenter.presentComparison(initialLeftVideo: nil, openLibrary: []) {}
        presenter.presentSorting(openResizedLibrary: { _ in }) {}
        XCTAssertEqual(presenter.comparisonCalls, 1)
        XCTAssertEqual(presenter.sortingCalls, 1)
    }
}
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test 2>&1 | grep -E "error:|cannot find" | head -3
```

Expected: `cannot find type 'SecondaryScreenPresenter' in scope`.

- [ ] **Step 3: Define the protocol**

Create `Sources/SkiVideoCore/SecondaryScreens.swift`:

```swift
import Foundation

/// Presents the Compare and Sort screens. macOS opens real `NSWindow`s; iPadOS
/// will use full-screen covers in a later phase. `ContentView` consults
/// `canPresent` so a platform that cannot yet show them simply hides the
/// buttons rather than offering a dead control.
@MainActor
public protocol SecondaryScreenPresenter: AnyObject {
    var canPresent: Bool { get }

    func presentComparison(
        initialLeftVideo: URL?,
        openLibrary: [ComparisonAthleteChoice],
        onClose: @escaping () -> Void
    )

    func presentSorting(
        openResizedLibrary: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    )
}
```

- [ ] **Step 4: Run the core tests**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test 2>&1 | tail -3
```

Expected: 74 tests, 0 failures.

- [ ] **Step 5: Write the macOS implementation**

Create `Sources/SkiVideoViewer/macOS/MacSecondaryScreenPresenter.swift`. It owns the two existing controllers, whose behaviour is unchanged:

```swift
import SkiVideoCore
import SwiftUI

@MainActor
final class MacSecondaryScreenPresenter: SecondaryScreenPresenter {
    var canPresent: Bool { true }

    private let comparisonWindow = ComparisonWindowController()
    private let sortingWindow = SortingWindowController()

    func presentComparison(
        initialLeftVideo: URL?,
        openLibrary: [ComparisonAthleteChoice],
        onClose: @escaping () -> Void
    ) {
        comparisonWindow.show(
            initialLeftVideo: initialLeftVideo,
            openLibrary: openLibrary,
            onClose: onClose
        )
    }

    func presentSorting(
        openResizedLibrary: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    ) {
        sortingWindow.show(
            openResizedLibrary: openResizedLibrary,
            onClose: onClose
        )
    }
}
```

Read `macOS/ComparisonWindowController.swift` and `macOS/SortingWindowController.swift` first and match their real `show(...)` signatures exactly. If either differs from the above, follow the source, not this snippet, and say so in your report.

- [ ] **Step 6: Rewire ContentView**

In `Sources/SkiVideoViewer/Shared/ContentView.swift`, delete the two `@StateObject` window controllers at lines 9-10 and add a stored dependency:

```swift
    private let secondaryScreens: SecondaryScreenPresenter
```

Add it to the initializer alongside `model` and `initialDirectory`. Replace the two toolbar actions so they call the presenter, and wrap both `ToolbarItem`s so they disappear when the platform cannot present them:

```swift
            if secondaryScreens.canPresent {
                ToolbarItem {
                    Button {
                        model.setKeyboardControlsEnabled(false)
                        secondaryScreens.presentComparison(
                            initialLeftVideo: model.currentPlaybackURL,
                            openLibrary: model.comparisonLibrary,
                            onClose: { model.setKeyboardControlsEnabled(true) }
                        )
                    } label: {
                        Label("Compare Videos…", systemImage: "rectangle.split.2x1")
                    }
                }
                ToolbarItem {
                    Button {
                        model.setKeyboardControlsEnabled(false)
                        secondaryScreens.presentSorting(
                            openResizedLibrary: { outputDirectory in
                                model.openDirectory(outputDirectory)
                            },
                            onClose: { model.setKeyboardControlsEnabled(true) }
                        )
                    } label: {
                        Label("Sort & Resize…", systemImage: "tag")
                    }
                }
            }
```

The `setKeyboardControlsEnabled(false)` / `onClose` pairing is load-bearing — it is what re-enables the viewer's keyboard when a secondary window closes. Preserve it exactly.

In `macOS/SkiVideoViewerApp.swift`, pass the presenter into `ContentView`.

- [ ] **Step 7: Verify ContentView is free of AppKit**

```bash
cd SkiVideoViewer
grep -n "WindowController\|AppKit\|NS[A-Z]" Sources/SkiVideoViewer/Shared/*.swift
```

Expected: no output. All four shared views are now platform-free.

- [ ] **Step 8: Add the macOS seam test**

Create `Tests/SkiVideoViewerTests/SecondaryScreenPresenterTests.swift`:

```swift
import SkiVideoCore
import XCTest
@testable import SkiVideoViewer

@MainActor
final class SecondaryScreenPresenterTests: XCTestCase {
    func testMacPresenterReportsItCanPresent() {
        XCTAssertTrue(
            MacSecondaryScreenPresenter().canPresent,
            "macOS has real windows, so ContentView must show the buttons"
        )
    }

    func testMacPresenterConformsToTheSeam() {
        // Compile-time proof the concrete type satisfies the protocol the
        // shared view depends on.
        let presenter: any SecondaryScreenPresenter = MacSecondaryScreenPresenter()
        XCTAssertTrue(presenter.canPresent)
    }
}
```

Do NOT call `presentComparison` or `presentSorting` in a test — they open real `NSWindow`s and would leave windows behind in the test run.

- [ ] **Step 9: Run everything**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test 2>&1 | tail -3 && ./build_app.sh
```

Expected: 76 tests, 0 failures, bundle built.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "Put Compare and Sort presentation behind the SecondaryScreenPresenter seam"
```

---

### Task 3: Generate the Xcode project with the macOS target

macOS first, so the project file is proven against a known-good target before an iPad target is added on top.

**Files:**
- Create: `SkiVideoViewer/project.yml`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: the directory layout from Task 1.
- Produces: `SkiVideoViewer.xcodeproj` with scheme `SkiVideoViewer-macOS`.

- [ ] **Step 1: Write the XcodeGen spec**

Create `SkiVideoViewer/project.yml`:

```yaml
name: SkiVideoViewer
options:
  bundleIdPrefix: ch.ski
  deploymentTarget:
    macOS: "13.0"
    iOS: "17.0"
  createIntermediateGroups: true

packages:
  SkiVideoCore:
    path: .

targets:
  SkiVideoViewer-macOS:
    type: application
    platform: macOS
    sources:
      - path: Sources/SkiVideoViewer/Shared
      - path: Sources/SkiVideoViewer/macOS
    dependencies:
      - package: SkiVideoCore
        product: SkiVideoCore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: ch.ski.video-viewer
        PRODUCT_NAME: SkiVideoViewer
        SWIFT_VERSION: "5.0"
        MARKETING_VERSION: "1.0"
        CURRENT_PROJECT_VERSION: "8"
        INFOPLIST_KEY_NSHumanReadableCopyright: ""
        GENERATE_INFOPLIST_FILE: true
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGNING_REQUIRED: false
```

`SWIFT_VERSION: "5.0"` is the language mode, matching the package's `swiftLanguageModes: [.v5]`. It is not the toolchain version.

- [ ] **Step 2: Generate and inspect**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && xcodegen generate && xcodebuild -list | sed -n '/Schemes:/,$p'
```

Expected: the schemes list includes `SkiVideoViewer-macOS`.

- [ ] **Step 3: Build the macOS app through Xcode**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer
xcodebuild -scheme SkiVideoViewer-macOS -destination 'platform=macOS' build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`. If it fails on a missing Info.plist key, add it under `settings.base` as `INFOPLIST_KEY_*` rather than adding a plist file — `GENERATE_INFOPLIST_FILE` is on.

- [ ] **Step 4: Ignore the generated project**

Append to `.gitignore`:

```
# Generated by XcodeGen from SkiVideoViewer/project.yml
SkiVideoViewer/SkiVideoViewer.xcodeproj/
```

- [ ] **Step 5: Confirm SwiftPM still works**

The SwiftPM path stays alive this phase so `swift test` keeps running the suite.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test 2>&1 | tail -3
```

Expected: 76 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Generate the Xcode project from project.yml with the macOS target"
```

---

### Task 4: Add the iPad target and its shell

**Files:**
- Modify: `SkiVideoViewer/project.yml`
- Create: `Sources/SkiVideoViewer/iOS/SkiVideoViewerApp_iOS.swift`
- Create: `Sources/SkiVideoViewer/iOS/NativePlayerView.swift`
- Create: `Sources/SkiVideoViewer/iOS/InertInputSource.swift`
- Create: `Sources/SkiVideoViewer/iOS/UnavailableOAuthPresenter.swift`
- Create: `Sources/SkiVideoViewer/iOS/NoSecondaryScreenPresenter.swift`
- Delete: `Sources/SkiVideoViewer/iOS/README.swift`

**Interfaces:**
- Consumes: `SecondaryScreenPresenter` (Task 2); `PlaybackInputSource`, `PlaybackIntent`, `OAuthPresenter`, `FolderPicker` from `Sources/SkiVideoCore/Seams.swift`; `ViewerModel.init(input:folderPicker:oauthPresenter:now:holdThreshold:)`.
- Produces: target `SkiVideoViewer-iPad`; `struct NativePlayerView: UIViewControllerRepresentable` (same name and `init(player:)` as the macOS one, so `ContentView` is unchanged); `final class InertInputSource: PlaybackInputSource`; `final class UnavailableOAuthPresenter: OAuthPresenter`; `final class NoSecondaryScreenPresenter: SecondaryScreenPresenter`.

- [ ] **Step 1: Write the iPad player view**

`ContentView` refers to `NativePlayerView(player:)`. The iOS file must expose exactly that name and initializer so the shared view needs no change. Create `Sources/SkiVideoViewer/iOS/NativePlayerView.swift`:

```swift
import AVKit
import SwiftUI

/// iPad counterpart of the macOS `NativePlayerView`. Same name and the same
/// `init(player:)`, so `ContentView` is identical on both platforms.
/// Controls are hidden because the app supplies its own transport row.
struct NativePlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspectFill
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}
```

`videoGravity = .resizeAspectFill` matches the macOS view's setting exactly.

- [ ] **Step 2: Write the three inert seam implementations**

`ViewerModel.init` requires all three dependencies, so the iPad needs something for each even though phases 4 and 6 supply the real ones.

`Sources/SkiVideoViewer/iOS/InertInputSource.swift`:

```swift
import SkiVideoCore

/// Phase 3 has no iPad input source. Touch gestures and hardware-keyboard
/// support arrive in phase 4; until then the app is driven entirely by the
/// on-screen list and transport buttons, and this emits nothing.
@MainActor
final class InertInputSource: PlaybackInputSource {
    var onIntent: ((PlaybackIntent) -> Void)?
    func setEnabled(_ enabled: Bool) {}
}
```

`Sources/SkiVideoViewer/iOS/UnavailableOAuthPresenter.swift`:

```swift
import Foundation
import SkiVideoCore

/// Google Drive is out of scope until phase 6, which replaces the loopback
/// flow with ASWebAuthenticationSession. Throwing here surfaces a normal
/// sign-in failure rather than pretending the flow succeeded.
@MainActor
final class UnavailableOAuthPresenter: OAuthPresenter {
    private struct Unavailable: LocalizedError {
        var errorDescription: String? {
            "Google Drive sign-in is not available on iPad yet."
        }
    }

    func prepareRedirectURI() async throws -> String {
        throw Unavailable()
    }

    func authorize(authorizationURL: URL, redirectURI: String) async throws -> URL {
        throw Unavailable()
    }
}
```

`Sources/SkiVideoViewer/iOS/NoSecondaryScreenPresenter.swift`:

```swift
import Foundation
import SkiVideoCore

/// Compare and Sort reach iPad in phase 5. Reporting `canPresent == false`
/// makes `ContentView` hide their toolbar buttons rather than offering
/// controls that do nothing.
@MainActor
final class NoSecondaryScreenPresenter: SecondaryScreenPresenter {
    var canPresent: Bool { false }

    func presentComparison(
        initialLeftVideo: URL?,
        openLibrary: [ComparisonAthleteChoice],
        onClose: @escaping () -> Void
    ) {}

    func presentSorting(
        openResizedLibrary: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    ) {}
}
```

- [ ] **Step 3: Write the iPad app entry**

Create `Sources/SkiVideoViewer/iOS/SkiVideoViewerApp_iOS.swift`. There is no `NSApplicationDelegate` and no command-line argument — the iPad always starts with no folder and the user picks one.

```swift
import SkiVideoCore
import SwiftUI

@main
struct SkiVideoViewerApp_iOS: App {
    @StateObject private var model = ViewerModel(
        input: InertInputSource(),
        folderPicker: UIKitFolderPicker(),
        oauthPresenter: UnavailableOAuthPresenter()
    )
    private let secondaryScreens = NoSecondaryScreenPresenter()

    var body: some Scene {
        WindowGroup {
            ContentView(
                model: model,
                initialDirectory: nil,
                secondaryScreens: secondaryScreens
            )
        }
    }
}
```

`UIKitFolderPicker` arrives in Task 5. Until then this file will not compile — that is expected, and Task 5's step 4 is where the target first builds.

- [ ] **Step 4: Make ContentView's macOS-only modifiers conditional**

`Shared/ContentView.swift:19` sets `.frame(minWidth: 980, minHeight: 640)`. An 11-inch iPad in portrait is 834pt wide, so this clips the UI. Replace with:

```swift
        #if os(macOS)
        .frame(minWidth: 980, minHeight: 640)
        #endif
```

This is the one place a platform conditional is justified — it is a single view modifier, not a file's worth of logic. `.keyboardShortcut` at `:63` and `:69` needs no guard; it is available on iOS 14+ and simply has no effect without a hardware keyboard.

- [ ] **Step 5: Add the iPad target to project.yml**

Append under `targets:` in `SkiVideoViewer/project.yml`:

```yaml
  SkiVideoViewer-iPad:
    type: application
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - path: Sources/SkiVideoViewer/Shared
      - path: Sources/SkiVideoViewer/iOS
    dependencies:
      - package: SkiVideoCore
        product: SkiVideoCore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: ch.ski.video-viewer.ipad
        PRODUCT_NAME: SkiVideoViewer
        SWIFT_VERSION: "5.0"
        MARKETING_VERSION: "1.0"
        CURRENT_PROJECT_VERSION: "1"
        GENERATE_INFOPLIST_FILE: true
        TARGETED_DEVICE_FAMILY: "2"
        INFOPLIST_KEY_UIApplicationSceneManifest_Generation: true
        INFOPLIST_KEY_UILaunchScreen_Generation: true
        INFOPLIST_KEY_UISupportedInterfaceOrientations: "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"
        INFOPLIST_KEY_UIFileSharingEnabled: true
        INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace: true
        CODE_SIGNING_REQUIRED: false
        CODE_SIGNING_ALLOWED: false
```

`TARGETED_DEVICE_FAMILY: "2"` is iPad-only. `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` are what the spec calls for so `athletes.txt` is reachable in Files; harmless now, needed later. Code signing is disabled because the simulator does not require it.

- [ ] **Step 6: Regenerate and confirm the target exists**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && xcodegen generate && xcodebuild -list | sed -n '/Schemes:/,$p'
```

Expected: both `SkiVideoViewer-macOS` and `SkiVideoViewer-iPad` appear. The iPad target will not build until Task 5 adds `UIKitFolderPicker`.

- [ ] **Step 7: Confirm macOS is unaffected**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && swift test 2>&1 | tail -3 && ./build_app.sh
```

Expected: 76 tests, 0 failures, bundle built.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Add the iPad target and its inert seam implementations"
```

---

### Task 5: iPad folder picking with security-scoped access

The last piece the iPad target needs, and the one with real iOS-specific semantics: a document-picker URL is only usable inside `startAccessingSecurityScopedResource()`.

**Files:**
- Create: `Sources/SkiVideoViewer/iOS/UIKitFolderPicker.swift`
- Create: `Sources/SkiVideoViewer/iOS/SecurityScopedFolderAccess.swift`
- No new tests. `UIDocumentPickerViewController` requires a live window scene, and
  `startAccessingSecurityScopedResource()` returns false for ordinary file URLs,
  so neither type is meaningfully unit-testable off-device. Task 6's simulator
  smoke test is what exercises this path. Say so in your report rather than
  writing a test that asserts nothing.

**Interfaces:**
- Consumes: `FolderPicker` from `Seams.swift`, with `pickFolder(startingAt:title:confirmLabel:) async -> URL?` and `pickFile(ofType:title:) async -> URL?`.
- Produces: `final class UIKitFolderPicker: FolderPicker`; `final class SecurityScopedFolderAccess` with `func begin(_ url: URL) -> Bool`, `func end()`, and `var current: URL?`.

- [ ] **Step 1: Read the exact protocol first**

```bash
cd SkiVideoViewer && grep -n "protocol FolderPicker" -A 8 Sources/SkiVideoCore/Seams.swift
```

Match the signatures exactly, including the `title:` and `confirmLabel:` parameters added in phase 1. A mismatch here is a compile error, not a subtle bug, so it will be caught — but read it rather than trusting this plan's summary.

- [ ] **Step 2: Write the security-scope holder**

Create `Sources/SkiVideoViewer/iOS/SecurityScopedFolderAccess.swift`:

```swift
import Foundation

/// A document-picker URL is only readable between
/// `startAccessingSecurityScopedResource()` and `stopAccessing...`. The
/// viewer keeps one folder open for the whole session, so this holds exactly
/// one scope and releases the previous one when a new folder is picked.
/// Child URLs produced by `FileManager.enumerator` inherit the parent's scope,
/// so `VideoLibrary.scan` needs no change.
final class SecurityScopedFolderAccess {
    private(set) var current: URL?

    @discardableResult
    func begin(_ url: URL) -> Bool {
        end()
        guard url.startAccessingSecurityScopedResource() else { return false }
        current = url
        return true
    }

    func end() {
        current?.stopAccessingSecurityScopedResource()
        current = nil
    }

    deinit {
        end()
    }
}
```

- [ ] **Step 3: Write the picker**

Create `Sources/SkiVideoViewer/iOS/UIKitFolderPicker.swift`:

```swift
import SkiVideoCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// iPad counterpart of `AppKitFolderPicker`. `UIDocumentPickerViewController`
/// is delegate-based, so the continuation is resumed from the delegate and
/// guarded against a double resume — the picker can report both a selection
/// and a cancellation if it is dismissed while a choice is in flight.
@MainActor
final class UIKitFolderPicker: NSObject, FolderPicker {
    private let access = SecurityScopedFolderAccess()
    private var continuation: CheckedContinuation<URL?, Never>?

    func pickFolder(startingAt: URL?, title: String, confirmLabel: String) async -> URL? {
        let url = await present(
            UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        )
        guard let url else { return nil }
        guard access.begin(url) else { return nil }
        return url
    }

    func pickFile(ofType type: UTType, title: String) async -> URL? {
        await present(
            UIDocumentPickerViewController(forOpeningContentTypes: [type])
        )
    }

    private func present(_ picker: UIDocumentPickerViewController) async -> URL? {
        guard let presenter = Self.topViewController() else { return nil }
        picker.allowsMultipleSelection = false
        picker.delegate = self
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            presenter.present(picker, animated: true)
        }
    }

    private func finish(_ url: URL?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: url)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

extension UIKitFolderPicker: UIDocumentPickerDelegate {
    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        finish(urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(nil)
    }
}
```

The `finish` guard is the important detail: resuming a `CheckedContinuation` twice is a crash, and both delegate methods can fire in some dismissal sequences.

- [ ] **Step 4: Build the iPad target**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer && xcodegen generate
xcodebuild -scheme SkiVideoViewer-iPad \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. This is the first time an iPad app binary exists.

- [ ] **Step 5: Confirm both other gates still pass**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd SkiVideoViewer
swift test 2>&1 | tail -3
xcodebuild -scheme SkiVideoCore-iOS \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' test 2>&1 \
  | grep -E "Executed [0-9]+ test" | tail -1
```

Expected: 76 tests on macOS, 46 on iOS (Task 2 added two core tests), 0 failures in both.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Add the iPad document picker with security-scoped folder access"
```

---

### Task 6: Automated simulator smoke test

The iPad is the one platform where real UI verification is automatable, so this phase does not end on "it compiles". `xcrun simctl` boots a device, installs the app, launches it, and captures a screenshot.

**Files:**
- Create: `scripts/ipad-smoke.sh`

**Interfaces:**
- Consumes: the `SkiVideoViewer-iPad` target from Tasks 4-5.
- Produces: an executable smoke script and a captured screenshot proving the app renders.

- [ ] **Step 1: Write the smoke script**

Create `scripts/ipad-smoke.sh`:

```bash
#!/bin/bash
set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

DEVICE="${1:-iPad Pro 11-inch (M5)}"
OUT="${2:-/tmp/ipad-smoke.png}"
BUNDLE_ID="ch.ski.video-viewer.ipad"

script_dir=$(cd "$(dirname "$0")" && pwd)
cd "$script_dir/../SkiVideoViewer"

echo "==> building for $DEVICE"
xcodebuild -scheme SkiVideoViewer-iPad \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath .build-ipad build >/dev/null

APP=$(find .build-ipad/Build/Products -name "SkiVideoViewer.app" -maxdepth 3 | head -1)
if [ -z "$APP" ]; then echo "no app bundle produced"; exit 1; fi
echo "==> app: $APP"

echo "==> booting"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b

echo "==> installing"
xcrun simctl install "$DEVICE" "$APP"

echo "==> launching"
xcrun simctl launch "$DEVICE" "$BUNDLE_ID"

sleep 4
xcrun simctl io "$DEVICE" screenshot "$OUT"
echo "==> screenshot: $OUT"

# The app must still be running; a launch-then-crash would leave no process.
if xcrun simctl spawn "$DEVICE" launchctl list 2>/dev/null | grep -q "$BUNDLE_ID"; then
  echo "==> RUNNING"
else
  echo "==> WARNING: process not found after launch — check the screenshot"
fi
```

```bash
chmod +x scripts/ipad-smoke.sh
```

- [ ] **Step 2: Run it**

```bash
./scripts/ipad-smoke.sh
```

Expected: `==> RUNNING` and a screenshot path. If `simctl bootstatus` hangs beyond a couple of minutes, the simulator is already booting from an earlier run — check `xcrun simctl list devices | grep Booted`.

- [ ] **Step 3: Look at the screenshot**

Read the PNG. The app must show the athlete sidebar and the "Choose a Video Folder" empty state from `ContentView.emptyState`. If the screen is blank or shows a crash dialog, that is a real failure — capture the log and report it:

```bash
xcrun simctl spawn "iPad Pro 11-inch (M5)" log show --last 2m --predicate 'process == "SkiVideoViewer"' 2>/dev/null | tail -40
```

- [ ] **Step 4: Verify the Compare and Sort buttons are absent**

`NoSecondaryScreenPresenter.canPresent` is `false`, so the toolbar must show only "Open Google Drive…", "Find Athlete" and "Open Folder…". Confirm from the screenshot that no "Compare Videos…" or "Sort & Resize…" button appears. If they do, the `canPresent` gating in Task 2 step 6 is wrong.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add an automated iPad simulator smoke test"
```

---

## Phase 3 done when

- `xcodegen generate` produces a project with `SkiVideoViewer-macOS` and `SkiVideoViewer-iPad`.
- `./scripts/ipad-smoke.sh` prints `==> RUNNING` and captures a screenshot showing the viewer UI.
- `swift test` = 76 tests, 0 failures; the `SkiVideoCore-iOS` scheme = 46 tests, 0 failures.
- `./build_app.sh` still produces a working macOS bundle, unchanged in behaviour.
- All four files in `Sources/SkiVideoViewer/Shared/` are free of AppKit and UIKit.

## Known limitations to record, not fix

- The iPad has no keyboard or gesture input — `InertInputSource` emits nothing. Phase 4.
- Compare and Sort are hidden on iPad. Phase 5.
- Drive sign-in throws on iPad. Phase 6.
- The picked folder's security scope is held for the session but **not persisted** as a bookmark, so the folder must be re-picked after relaunch. Bookmark persistence needs `ViewerModel` to store bookmark data rather than String paths — a core API change flagged in the phase 1 outcomes doc. Do it in phase 4 or later, not here.
