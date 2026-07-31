# iPadOS Phase 1 — Outcomes and Carried-Forward Items

**Date:** 2026-07-31
**Branch:** `ipados-phase1`, 18 commits off `0d6219e`
**Plan:** `docs/superpowers/plans/2026-07-31-ipados-phase1-core-extraction.md`
**Spec:** `docs/superpowers/specs/2026-07-31-ipados-support-design.md`

## What landed

`SkiVideoCore` now holds every platform-agnostic file, and the four AppKit
dependencies sit behind seam protocols with macOS implementations in
`Sources/SkiVideoViewer/Platform/`.

```
Sources/SkiVideoCore/          no AppKit, UIKit, SwiftUI or Process
  ComparisonChoices  ComparisonModel  GoogleDriveSupport  Seams
  SortingLibrary     SortingModel     VideoLibrary        ViewerModel

Sources/SkiVideoViewer/        SwiftUI views + AppKit shell
  Platform/  AppKitInputSource  AppKitFolderPicker
             AppKitOAuthPresenter  FFmpegMediaPipeline
```

Test suite: 10 → 72, all passing. The macOS app builds and signs.

`swift test` and `swift build` require
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The
machine's active developer directory is the Command Line Tools, which ship no
XCTest.

## Deliberate behaviour changes

Only two, both reviewed and intentional.

1. **Double-tap seek is now 5.0 seconds, was 4.0.** The old code already told
   the user "5 seconds" in the status line while seeking 4.0. This resolves the
   inconsistency rather than introducing one.
2. **Typing in the athlete search field no longer drives the comparison
   window.** The old comparison `NSEvent` monitor had no first-responder guard
   and was app-wide, so with the compare window open, clicking back to the main
   window and typing in "Jump to athlete…" had Space toggle the comparison
   videos and arrows seek them. The shared input source carries the guard. This
   is a fix; do not mistake it for a regression later.

## Not verified by this phase

State these plainly rather than assuming they work.

- **The `NSEvent` local monitor's runtime installation.** Deleting the
  registration leaves all 72 tests green while the app goes deaf to the
  keyboard. Synthetic events cannot drive a local monitor.
- **`SortingWindowController.swift:38`'s `input.arrowsBypassTextFieldFocus = true`
  and `:38`'s `arrowsRepeat = true`.** The flags' semantics are pinned by
  tests; their activation is not. Deleting either line keeps the suite green
  and silently kills the sorting window's arrow keys.
- **SwiftUI button bindings** — that each button calls the model method it
  appears to.
- **The Google Drive sign-in flow end to end.** No browser, Keychain or network
  call was made. `OAuthCallbackServer.receiveCallback` — HTTP request parsing,
  URL reconstruction, the response — is executed by nothing. The
  state-mismatch, `error` and missing-`code` branches likewise. Byte-identity
  to the pre-refactor code (verified by SHA-1) is the only assurance.

All of the above need XCUITest, which needs the Xcode project built in phase 3.

## Carried forward

### For phase 3 (Xcode project and iPad target)

- **The iOS platform component is not installed in Xcode.** The iOS 26.5 SDK
  ships with Xcode 26.6, but every iOS destination is ineligible until it is
  downloaded (Xcode → Settings → Components). Nothing can be built or tested
  for iPad until then. Note SwiftPM silently overrides `-sdk` with the macOS
  sysroot — it warns `using sysroot for 'MacOSX' but targeting 'iPhone'` and
  compiles against macOS anyway, so a passing `swift build` with an iOS triple
  proves nothing.
- **`CorePurityTests` is the only gate on core portability**, and it scans
  source text non-recursively. It will not see a forbidden import in a future
  `SkiVideoCore` subdirectory, and it cannot catch semantic divergences at all.
- **`FolderPicker` returns a bare `URL?` with no security-scope contract.** On
  iOS a document-picker URL is only usable inside
  `startAccessingSecurityScopedResource()`. More costly than it looks: the core
  persists **String paths**, not bookmarks — `ViewerModel.clientSecretsPath`,
  the `UserDefaults` writes around `ViewerModel.swift:171`, and
  `SortingModel.sourcePath` / `namesPath`. Moving to `bookmarkData()` changes
  core public API, not just the seam implementation.
- **`AppKitInputSource` and `ViewerModel` each track `heldDirection`.** Their
  guards were re-synchronised by hand after a regression; nothing structural
  stops them drifting again. `testReleasingASecondArrowMidHoldDoesNotEndTheScrub`
  is the only pin. Deliberately left duplicated — the source's copy is physical
  key state, the model's is scrub state, and the model clears its own while a
  key is still held.
- **The 10 older `AppKitInputSourceTests` build events with `windowNumber: 0`**,
  so `event.window` is nil and they structurally cannot reach the
  first-responder branch. That is how the dead-seek bug survived several
  reviews. Use the off-screen `NSWindow` fixture in that file for anything
  touching focus.

### For phase 6 (ASWebAuthenticationSession Drive auth)

- **SECURITY: `DriveMedia.streamingURL` embeds the OAuth access token as a URL
  query parameter** (`GoogleDriveSupport.swift:21`). Pre-existing, not
  introduced by this phase. Deferred because the fix needs an
  `AVAssetResourceLoaderDelegate` injecting `Authorization: Bearer` and
  handling byte-range requests — a new component with its own design and tests.
  Exposure is bounded: the token is 1-hour and `drive.readonly`-scoped, the
  refresh token is in Keychain and never in a URL, and there is no browser and
  so no `Referer` leak. **Additional urgency:** Google has been retiring
  `access_token` as a query parameter, so this may become a functional break
  before it becomes a security one.
- **`OAuthPresenter` abstracts presentation but not the credential model.**
  `GoogleDriveSupport.swift` requires an `installed` client-secrets JSON and
  unconditionally sends `client_secret`. iOS OAuth clients have neither, so
  phase 6 edits core rather than merely supplying a new implementation.
- **`AppKitOAuthPresenter`'s shared `private var server`** means a second
  `prepareRedirectURI()` overwrites the first flow's listener. Unreachable only
  because `GoogleDriveSheet` disables Connect while `isConnectingToDrive`. Make
  it local when the file is rewritten.
- **`GoogleDriveClient.scanSharedDrive` is entirely uncovered** — folder
  recursion, athlete grouping, extension filtering, `canDownload`, pagination.
  Unlike the loopback server this **is** cheaply testable with a `URLProtocol`
  stub and no network. Highest-value uncovered path in the codebase.

### For phase 2 (AVFoundation media pipeline)

- **The `enqueueResize` semaphore bridge can retire.** A cooperative-pool
  thread currently blocks in `waitUntilExit()` inside `Task.detached` while an
  `OperationQueue` thread parks on a semaphore. Safe at
  `maxConcurrentOperationCount = 1`; a starvation hazard if that ever rises. An
  actor-serialised async chain would replace it. `SortingModelResizeQueueTests`
  pins the serialisation guarantee that any replacement must preserve.
- **`FFmpegMediaPipeline` reads stderr only after `waitUntilExit()`**, so a
  >64KB stderr burst deadlocks the resize worker. Pre-existing and
  byte-identical to the original. Failure mode is a stalled queue, not data
  loss — the file move has already committed and the clip is intact under
  `organized/`.

## Smaller items, fine to carry

- `AppKitInputSource` has no `deinit`-time `.scrubEnded` emission. Correct:
  by `deinit` the refcount is zero, the monitor's `[weak self]` is nil, and
  there is no observer left to deliver to.
- With two arrows held at once, the second arrow's initial press emits nothing
  (the `heldDirection == nil` guard) while its repeats do. Narrower than the
  old monitor, never wider. Closing it would weaken a guard the viewer needs.
- `CorePurityTests.testSeamsAreReachableFromTests` is a compile-time gate
  dressed as a runtime test — its assertions cannot fail if the file compiles.
- `.togglePlayback → playSynced` is pinned only against the `pauseBoth` branch.
  `AVPlayer.setRate` raises an uncatchable ObjC exception without ready media;
  closing this needs an `AVAssetWriter` fixture plus a `readyToPlay` KVO wait.
