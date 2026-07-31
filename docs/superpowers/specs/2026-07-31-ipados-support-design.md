# iPadOS Support for SkiVideoViewer

**Date:** 2026-07-31
**Status:** Approved design, not yet implemented

## Goal

Run SkiVideoViewer on iPadOS with full feature parity — browsing, playback,
comparison, and Sort & Resize — while keeping the macOS app working.

## Decisions

| Question | Decision |
|---|---|
| Feature scope on iPad | Full parity, including Sort & Resize |
| Video storage | Any folder reachable through Files (external SSD, on-device, iCloud, Drive) |
| Input | Touch-first, hardware keyboard supported when attached |
| Code signing | Paid Apple Developer Program account |
| Code structure | Core SwiftPM package + shared SwiftUI views + platform seam protocols |
| ffmpeg | Replaced by AVFoundation on **both** platforms |

## What blocks iPadOS today

Verified by reading the current sources.

**Structural**

- `Package.swift:8` declares `.macOS(.v13)` only, and SwiftPM cannot produce an
  iOS app bundle. `build_app.sh` hand-assembles a `.app` and ad-hoc signs it.

**AppKit with no iOS equivalent**

- `NSOpenPanel` — `ViewerModel.swift:107,127`, `SortingModel.swift:81,96`,
  `ComparisonModel.swift:63`.
- `NSEvent.addLocalMonitorForEvents` — `ViewerModel.swift:377`,
  `SortingModel.swift:304`, `ComparisonModel.swift:344`. This is the entire
  control scheme, including the arrow hold-to-slow-scrub that depends on key-up.
- `NSWindow` + `NSHostingView` secondary windows —
  `ComparisonWindowController.swift:21`, `SortingWindowController.swift:32`.
- `NativePlayerView` is `NSViewRepresentable` around `AVPlayerView`.
- `OverlayPlayerView` is `NSViewRepresentable` around an `NSView` hosting two
  `AVPlayerLayer`s, and uses `CALayer.compositingFilter` for difference blending
  (`OverlayPlayerView.swift:9,32,93`).
- `NSWorkspace.shared.open` — `GoogleDriveSupport.swift:254`.

**Hard blockers**

- `SortingModel.swift:356` runs ffmpeg through `Process`. `Process` does not
  exist on iOS.
- Google Drive OAuth uses a loopback HTTP server (`NWListener` on 127.0.0.1).
  iOS requires `ASWebAuthenticationSession` with a custom URL scheme, and Google
  requires a separate iOS-type OAuth client.
- `SortingModel.swift:39-42` defaults to `~/Ski/athletes.txt` via
  `homeDirectoryForCurrentUser`, meaningless in an iOS sandbox.

**Ports cleanly, unchanged:** `VideoLibrary.swift`, `SortingLibrary.swift`, and
the playback logic in `ViewerModel` / `ComparisonModel`.

## Architecture

### Module layout

```
SkiVideoViewer/
  Package.swift                 platforms: .macOS(.v13), .iOS(.v17)
  Sources/SkiVideoCore/         no AppKit, no UIKit, no Process
    VideoLibrary.swift          unchanged
    SortingLibrary.swift        unchanged
    ViewerModel.swift           keyboard + panel code removed, consumes intents
    ComparisonModel.swift       same
    SortingModel.swift          same, ffmpeg replaced by MediaPipeline
    GoogleDriveClient.swift     OAuth transport extracted to a seam
    MediaPipeline.swift         new, AVFoundation export
    Seams.swift                 new, the protocols below
  Tests/SkiVideoCoreTests/
  App/
    Shared/                     SwiftUI views for both platforms
    macOS/                      AppKit seam implementations
    iOS/                        UIKit seam implementations
  SkiVideoViewer.xcodeproj      one app target, destinations: My Mac + iPad
```

The `SkiVideoCore` boundary is what makes the models portable. Today
`ViewerModel` (452 lines), `SortingModel` (379) and `ComparisonModel` (367) each
mix playback state, file-system work, keyboard event decoding, and AppKit
presentation. Extracting the platform pieces both enables the port and leaves
each file with one job. It also preserves `swift test` as the test path; an
Xcode-project-only layout would force `xcodebuild` for every test run.

### Minimum OS versions

iPadOS 17, macOS stays at 13.

Shared key handling deliberately avoids SwiftUI's `.onKeyPress`, which requires
macOS 14 and would raise the Mac floor for no benefit. macOS keeps its existing
`NSEvent` monitor behind the input seam; iPad uses `UIKeyCommand` plus
`pressesBegan`/`pressesEnded`.

### Build

`build_app.sh` and `run.sh` are replaced by `xcodebuild` (or Xcode directly). A
single multi-destination app target cannot be assembled by the current
hand-rolled bundle script. Ad-hoc `codesign --force --sign -` is replaced by the
Developer Program team identity, which the iPad build requires anyway and which
also provides the Keychain access group for the Drive refresh token.

## Input model

### Why the seam sits at "arrow down / arrow up"

The interesting timing logic is already platform-independent.
`beginArrow` / `endArrow` / `performArrowTap` (`ViewerModel.swift:262-332`) own
the 0.22s hold threshold, the 0.38s double-tap window, and the 0.35× scrub rate.
`NSEvent` only tells them that an arrow went down or came up.

```swift
protocol PlaybackInputSource {
    var intents: AsyncStream<PlaybackIntent> { get }
    func setEnabled(_ enabled: Bool)
}

enum PlaybackIntent {
    case togglePlayback
    case clip(Step)                 // Up / Down
    case athlete(Step)              // PageUp / PageDown
    case scrubBegan(Direction)      // Left / Right down
    case scrubEnded(Direction)      // Left / Right up
    case focusAthleteSearch         // Cmd-F
    case openFolder                 // Cmd-O
}
```

`ViewerModel` consumes intents and is otherwise unchanged.

### Touch mapping (viewer)

The video area splits into three vertical zones, with one
`DragGesture(minimumDistance: 0)` per side zone.

| Gesture | Intent | Mac equivalent |
|---|---|---|
| Tap centre zone | `.togglePlayback` | Space |
| Press-and-release left/right zone | `.scrubBegan` then `.scrubEnded` | Left/Right tap |
| Press-and-hold left/right zone | same pair, held | Left/Right hold |
| Swipe up / down | `.clip(.previous/.next)` | Up / Down |
| Sidebar row tap | athlete selection | PageUp / PageDown |

Because press-and-release emits the same begin/end pair as a key tap, tap = ±1s,
double-tap = ±5s, and hold = 0.35× slow scrub all reproduce identically on touch
with no new timing code.

**Gesture precedence.** The side-zone `DragGesture` and the vertical clip-change
swipe overlap, since a drag starting in a side zone can travel vertically. One
gesture recognizer handles the whole video area and resolves by first
significant movement: if vertical translation exceeds 40pt before horizontal
translation does, the touch becomes a clip-change swipe and no `.scrubBegan` is
emitted. If `.scrubBegan` was already emitted when that threshold is crossed, it
is cancelled with `.scrubEnded` carrying a suppress-tap flag — matching the
existing `endArrow(performTap: false)` path.

### Hardware keyboard on iPad

`UIKeyCommand` covers Space, Up/Down, PageUp/PageDown, Cmd-F and Cmd-O. It has
no key-up event, which the arrow hold requires, so the iOS input source is a thin
`UIViewController` overriding `pressesBegan` / `pressesEnded`, hosted invisibly
behind the player. Roughly 40 lines, confined to `App/iOS/`.

### Typing guard

`ViewerModel.swift:396` suppresses key handling while an `NSTextView` has focus.
Rather than reimplement that per platform, both input sources route through the
existing `setKeyboardControlsEnabled(_:)`, driven by the search field's
`@FocusState`.

### Secondary screens

Sort and Compare receive the same treatment: centre tap for play/pause, side
zones for their ±5s and ±1s synced seeks. Sorting's Return-to-tag becomes an
explicit **Tag** button, which touch requires regardless.

## Media pipeline

```swift
protocol MediaPipeline {
    func writeMetadata(athlete: String, to url: URL) async throws
    func resize(source: URL, destination: URL, athlete: String) async throws
}
```

One AVFoundation implementation serves both platforms, removing the ffmpeg
dependency and the Homebrew prerequisite from the macOS app.

**Metadata write** replaces the passthrough remux. Build an
`AVMutableComposition` containing only the first video track and first audio
track — which is what `-map 0:v:0 -map 0:a?` achieves, since telemetry and data
tracks are simply never inserted. Export with `AVAssetExportPresetPassthrough`,
setting `.metadata` to the source's existing items merged with new title, artist
and comment. Export to a temp file, then `replaceItemAt` as today.

An `AVMutableComposition` track does **not** inherit `preferredTransform` from
its source. It must be copied explicitly or portrait-held clips export sideways.
ffmpeg's `-c copy` preserved the display matrix for free; this does not. Covered
by a dedicated test.

**Resize** uses `AVAssetExportPreset1920x1080`, whose intent matches
`scale=w=1920:h=1080:force_original_aspect_ratio=decrease`. The serial
`OperationQueue` (`SortingModel.swift:26-33`, `maxConcurrentOperationCount = 1`)
is retained; it maps onto async exports unchanged and matters more for iPad
thermals than it did on the Mac.

**Fidelity:** output will not be byte-identical to ffmpeg's. The preset chooses
its own H.264 bitrate rather than ffmpeg's CRF default, so file sizes will
differ. Nothing in the repository reads the athlete metadata back — it is
write-only, consumed by external players and Finder — so exact atom-level
compatibility is not a contract.

## File access

```swift
protocol FolderPicker {
    func pickFolder(startingAt: URL?) async -> URL?
    func pickFile(ofType: UTType) async -> URL?
}
```

macOS keeps `NSOpenPanel`. iPad uses `UIDocumentPickerViewController` in folder
mode. The picked folder URL is security-scoped:
`startAccessingSecurityScopedResource()` is held for the session, child URLs from
`FileManager.enumerator` inherit access, and `bookmarkData()` persists it across
launches. `VideoLibrary.scan` needs no change.

**The macOS target stays unsandboxed.** It is not destined for the Mac App Store
and wants broad filesystem access, so the access seam is a no-op there. Stated
explicitly because Xcode enables App Sandbox by default on new app targets, and
silently breaking the Mac app's file access would be an easy regression.

The sorting flow writes `organized/` and `organized_resize/` inside the picked
folder and moves clips into them. All permitted under folder-scoped access.

**Provider-folder caveat:** iCloud Drive and Google Drive folders picked through
Files route writes through a File Provider, which can be slow or fail mid-export.
External SSD and on-device storage are the reliable cases. Provider folders
surface a clear error rather than hanging silently.

`athletes.txt` moves from the hardcoded `~/Ski/athletes.txt` to the app's
Documents directory by default, overridable by picking a file. Setting
`UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` makes the default
file editable directly in Files.app.

## Google Drive authentication

`OAuthCallbackServer` (the `NWListener` loopback server, roughly 90 lines) and
the `Network` import are deleted. Both platforms move to
`ASWebAuthenticationSession` with a custom-scheme redirect:

```swift
protocol OAuthPresenter {
    func authorize(_ url: URL, callbackScheme: String) async throws -> URL
}
```

This requires a new Google OAuth client of type **iOS**, with redirect
`com.googleusercontent.apps.<ID>:/oauth2redirect`. iOS clients carry no secret,
so `client_secret` (currently sent at `GoogleDriveSupport.swift:304`) drops out
of the token request, and the "pick a client-secrets JSON file" step disappears
on iPad. The client ID is compiled in; PKCE — already implemented at
`GoogleDriveSupport.swift:238-240` — provides the security.

**Unverified:** whether Google accepts an iOS-type client driven from a macOS
`ASWebAuthenticationSession`. If it does not, macOS keeps its existing loopback
flow and only iPad uses the new one. The seam makes that a single-file
difference.

Keychain storage works on both platforms but needs a `keychain-access-groups`
entitlement once team-signed. The iOS item uses
`kSecAttrAccessibleAfterFirstUnlock`.

## Presentation and layout

```swift
protocol SecondaryPresenter {
    func present(_ screen: SecondaryScreen, onClose: @escaping () -> Void)
}
```

macOS keeps `ComparisonWindowController` and `SortingWindowController` as they
are. iPad's implementation flips published state that `ContentView` renders as a
`.fullScreenCover`. Both must invoke `onClose` — that callback re-enables the
viewer's keyboard controls (`ContentView.swift:26-27, 41-42`).

Layout changes for iPad:

- `ContentView.swift:18` sets `.frame(minWidth: 980, minHeight: 640)` and
  `ComparisonView.swift:42` sets `.frame(minWidth: 1000, minHeight: 680)`. An
  11" iPad in portrait is 834pt wide, so both are compiled out on iOS.
- `NavigationSplitView` adapts natively; the sidebar becomes an overlay in
  portrait, which is now the primary way to switch athletes.
- The five toolbar items collapse into a single menu at compact width.
- `ComparisonView`'s `sideBySide` layout stacks vertically in portrait. Its
  `overlay` layout already works at any size, and its segmented layout picker
  and opacity slider are touch-friendly as they stand.

### Overlay player

`OverlayPlayerView` needs a UIKit counterpart. The structural port is
mechanical: `NSView` to `UIView`, `NSRect` to `CGRect`, `NSColor` to `UIColor`,
`layout()` to `layoutSubviews()`, and `wantsLayer` dropped because `UIView` is
always layer-backed. `AVPlayerLayer`, `CALayer` and `CATransaction` — including
the `setDisableActions(true)` guard against implicitly animated frame changes —
are identical on both platforms. Roughly 15 lines of a 98-line file differ.

**The difference blend is the open question.** `OverlayPlayerView.swift:93` sets
`topLayer.compositingFilter = CIFilter(name: "CIDifferenceBlendMode")`. The iOS
SDK declares `compositingFilter` at `CALayer.h:660` with no unavailability
annotation, so it compiles — but Core Animation on iOS has historically not
executed the layer filter pipeline, and whether it renders cannot be confirmed
without running on device. Treated as a spike, not an assumption.

If it is a no-op on iOS, the fallback is SwiftUI's own `.blendMode(.difference)`
inside a `.compositingGroup()`, which would also let the two-layer custom view
collapse into a `ZStack` of two single-player views shared by both platforms —
a simplification worth taking even on macOS if it works. That path is itself
unverified for `AVPlayerLayer` content, since video layers can be composited
out-of-band by the display server and may not participate in SwiftUI blending.
Second fallback is a Metal or `CIFilter`-based compositor drawing both frames,
which is materially more work.

Blend mode is the only part of the overlay feature at risk. Opacity blending
(`OverlayPlayerView.swift:89`) is plain `CALayer.opacity` and works everywhere.

## Error handling

The existing `errorMessage: String?` plus `.alert` pattern carries over
unchanged, and `failedResizes` already collects per-clip failures. Three new
iPad-specific failure modes:

- **Lost folder access** — external drive unplugged, or a stale bookmark after
  reboot. `startAccessingSecurityScopedResource()` returns false; surface a
  "Reconnect folder" action rather than a dead-end error.
- **Export failure** — `AVAssetExportSession.status == .failed` feeds
  `failedResizes` with the underlying error, exactly as a non-zero ffmpeg exit
  does today.
- **Backgrounding mid-export** — iOS suspends the app when the user leaves it.
  `beginBackgroundTask` buys roughly 30 seconds, far less than a batch resize
  needs. `isIdleTimerDisabled` is set during sorting and the UI states plainly
  that leaving the app cancels in-flight exports. Incomplete outputs are cleaned
  up and their clips stay queued for retry.

**Accepted limitation:** batch resizing on iPad requires keeping the app in the
foreground. There is no clean workaround within iOS's execution model.

`ProcessInfo.thermalState` is surfaced in the status line, since sustained
exports throttle an iPad in a way they do not throttle the Mac.

## Testing

`swift test` continues to run `SkiVideoCoreTests` on macOS. `xcodebuild test`
runs the same suite against an iPad simulator destination. Existing
`VideoLibraryTests` is unchanged.

The seam refactor unlocks coverage that does not exist today: `ViewerModel`'s
tap / double-tap / hold state machine is currently untestable because it is
driven directly by `NSEvent`. Once it consumes `PlaybackIntent`s, a fake input
source can drive it.

New tests:

- **MediaPipeline**, against a fixture clip synthesized with `AVAssetWriter` in
  setup, so no binary enters git (`testvid/` is gitignored):
  `preferredTransform` survives the composition round-trip; non-A/V tracks are
  dropped; resize output fits within 1920×1080 and does not upscale; metadata
  reads back.
- **Intent handling**: tap = ±1s; double-tap within 0.38s = ±5s; hold past 0.22s
  enters slow scrub; release restores the prior rate.
- **Fakes** for `FolderPicker` and `OAuthPresenter` covering the flows that
  depend on them.

## Risks and spikes

Ordered by how early they should be resolved.

1. **Reverse slow-scrub performance on iPad.** `ViewerModel.swift:350-361` uses
   `playImmediately(atRate: -0.35)` only when `canPlayReverse` is true, otherwise
   falling back to a repeating 0.08s seek. For typical H.264 camera footage
   `canPlayReverse` is usually false, so iPad will take the fallback, and 12.5
   seeks per second against a file on an external USB-C SSD may stutter badly.
   Unmeasured. Spike first; fallback plan is to pre-roll a short reverse buffer.
2. **`AVAssetExportPreset1920x1080` no-upscale behaviour.** Believed to match
   `force_original_aspect_ratio=decrease` but unverified. Spike with a visual A/B
   against ffmpeg output on one real clip.
3. **`CALayer.compositingFilter` on iOS.** Determines whether the overlay
   difference blend survives the port unchanged, or needs the SwiftUI
   `.blendMode` rewrite. Cheap to test: one layer, one filter, one screenshot.
   Run it before phase 5.
4. **Google iOS-type OAuth client from macOS.** See above; contained by the seam.
5. **Export throughput and thermals** on a long real-world batch.

## Implementation phases

This is a large change touching the build system, three models, the media
pipeline, and authentication. The pieces are coupled through the seam refactor,
so they belong in one spec — but they should be staged so that macOS keeps
working and is verifiable at every step.

1. **Extract `SkiVideoCore`, macOS only.** Move portable code into the package,
   introduce the seam protocols, implement the AppKit side. The macOS app builds
   and behaves identically. No iOS work yet. This is the largest and riskiest
   step and it is independently verifiable.
2. **Replace ffmpeg with `MediaPipeline`, macOS only.** Includes spike 2. The
   macOS app loses its ffmpeg dependency and output is A/B'd against ffmpeg.
3. **Xcode project and iPad app target.** Both destinations build and launch;
   iPad reaches the viewer with a picked folder and plays clips.
4. **iPad input** — gestures, then hardware keyboard. Includes spike 1.
5. **iPad secondary screens** — Compare and Sort, the `OverlayPlayerView` UIKit
   counterpart, plus layout adaptation.
6. **`ASWebAuthenticationSession` Drive auth.** Includes spike 3.

Spike 1 (reverse scrub performance) should be run early and out of order if
possible, since a bad result changes the input design in phase 4.

## Incidental fix

`ViewerModel.swift:327` seeks 4.0 seconds on a double-tap while `:329` reports
"5 seconds" to the user. Corrected to 5 seconds in both places.
