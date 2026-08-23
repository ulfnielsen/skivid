# Photos to the Club Drive — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a coach films a few runs on their phone at the hill, tags them, and
they land in the club's Drive beside everything else — without a laptop, a card
reader, or a trip home first.

**Architecture:** four arrows, only the last of which is new.

    Photos ──PHPicker──▶ temp folder ──existing sorting flow──▶ Sorted/<event>/<athlete>/ ──upload──▶ club Drive

The first arrow exports what the coach picked into a scratch directory, so
`SortingModel` reads a folder of clips exactly as it does from an SD card and
needs no notion of Photos at all. The last arrow mirrors the tray sorting
already leaves behind into the open Drive library, following that library's own
`FolderConvention`. Because the upload stage reads a *directory*, it works for
SD-card sorting on an iPad too, not only for Photos on a phone.

**Tech Stack:** Swift 6.1 / SwiftPM (`swiftLanguageModes: [.v5]`), PhotosUI,
AVFoundation, Google Drive v3, SwiftUI, XCTest, XcodeGen.

## What was measured before this plan was written

- **Nothing in this repo touches Photos.** No `PhotosUI`, no `PHPicker`, no
  `PHAsset`, and no `NSPhotoLibraryUsageDescription` in `iPad-Info.plist`.
- **Drive cannot create anything.** The only write is
  `replaceContents(ofFileID:withFileAt:)` — an `uploadType=media` PATCH onto a
  file that already exists, built for the oversized-clip repair. There is no
  `files.create`, no folder creation, and no `parents` handling anywhere.
- **The write scope is already the full one.** `GoogleOAuth` asks for
  `…/auth/drive` (not `drive.file`) the first time a write is needed. Uploading
  therefore needs **no new consent screen** beyond what repair already triggers.
- **`ClipPublisher` is the wrong seam, despite looking like the right one.**
  `prepare(source:athlete:event:)` is synchronous and returns filesystem URLs —
  it answers "where does the resize read from and write to". An upload is
  asynchronous, networked, and can fail for an hour on a chairlift; putting it
  there would make every tag wait on a round trip. Sorting's own
  `completedOutputDirectory` is the handoff point instead.
- **iOS already sorts read-only.** `SkiVideoViewerApp_iOS` passes
  `keepsSourceIntact: true`, so `ReadOnlySourcePublisher` writes resizes under
  `outputRoot` and never touches the source. Photos originals are safe by
  construction, not by a new rule.
- **Libraries carry their layout.** `Library.convention` is set when a drive is
  connected, so the destination path is the library's answer, not this plan's.

## Decisions taken

- **Resized copies upload; originals stay in Photos.** That is what the resize
  step is for — a clip the club can stream. A phone original is several times
  larger and is the difference between an upload that finishes on the lift and
  one that does not.
- **One batch at the end.** Tag everything, then press Upload once and watch a
  single progress view that can be cancelled. Nothing uploads behind the coach's
  back.

## Global Constraints

- **Photos is read-only.** Nothing is moved, deleted, or edited there. The
  coach's camera roll is not this app's storage.
- **No new OAuth scope.** If a task finds itself editing the scope string, stop:
  the grant is already `…/auth/drive`, and widening it costs every user a
  scarier consent screen.
- **Uploading must be resumable or retryable per clip.** A 25 MB upload on a
  mountain will fail. A failure must cost one clip and be retryable from the
  tray, not restart the batch.
- **Nothing uploads twice.** A clip already in the destination folder is
  skipped, and the check must not be "we think we sent it" — that is lost the
  moment the app is killed.
- **Test command is not plain `swift test`.** Prefix every invocation:
  `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter …`
- **Never `git add -A`** — `AppBundle/` holds intentionally uncommitted artwork.

## Tasks

### Task 1 — Photos becomes a folder of clips

- [ ] A `PHPickerViewController` wrapper, multi-select, videos only.
      `PHPicker` runs out of process and needs **no permission prompt and no
      usage description** — the coach picks, the app receives copies. Do not
      reach for `PHPhotoLibrary` authorisation; it costs a prompt and the
      limited-access mess for a browsing experience this flow does not need.
- [ ] Export each pick to a scratch directory with
      `loadFileRepresentation(forTypeIdentifier: UTType.movie)`. Keep the
      original filename where Photos offers one; fall back to something ordered
      by capture date, because "IMG_0413" ordering is how a coach recognises the
      run they just filmed.
- [ ] Scratch lives under `Caches` and is cleared when the sort ends. A
      half-exported session must not accumulate gigabytes invisibly.
- [ ] "From Photos…" beside "Choose…" in `SortingSheet`'s setup, on iOS only.
- [ ] Test: exporting two picks yields two readable movies with distinct names.

### Task 2 — Drive can create things

- [ ] `createFolder(named:parent:)` — `files.create` with
      `mimeType: application/vnd.google-apps.folder`, `supportsAllDrives=true`.
- [ ] `findFolder(named:parent:)` so the same event folder is not created twice
      by two coaches on the same afternoon. Find-or-create, in that order.
- [ ] `upload(fileAt:named:parent:)` — resumable upload, not `uploadType=media`.
      Resumable is the one that survives a signal dropping mid-clip, which is
      the normal case here rather than the exceptional one.
- [ ] All three against a Shared Drive: `supportsAllDrives=true` is not
      optional, and its absence is exactly the bug `replaceContents` already
      carries a comment about.
- [ ] Tests with a fake transport covering: created, already exists, 401 after
      token expiry, and a mid-upload failure that resumes.

### Task 3 — The destination follows the library

- [ ] Resolve `<root>/<event>/<athlete>/` — or `<athlete>/<event>/` — from the
      open library's `convention`. The app must not invent a layout the club
      does not use; a clip in the wrong folder is worse than one not uploaded.
- [ ] Refuse clearly when the open library is a folder rather than a Drive, or
      when none is open. "Upload" with nowhere to go should say so before the
      coach tags twenty clips, not after.

### Task 4 — The tray, and the batch

- [ ] When tagging finishes, show what is waiting: clip, athlete, event, size.
      This is the screen the coach reads standing in a lift queue.
- [ ] "Upload N clips to <library>" — one progress view, cancellable, with
      per-clip state so a failure names the clip that failed.
- [ ] Failures stay in the tray and can be retried without re-tagging. Sorting
      already writes them to disk; losing a tag to a network error would be
      unforgivable on a hill.
- [ ] Skip what is already there, checked against the destination folder rather
      than against anything the app remembers — the app being killed mid-batch
      is a normal event, not an edge case.

### Task 5 — Proof

- [ ] Unit tests for the export, the path resolution, and the skip rule.
- [ ] A UI test through the phone flow: pick from Photos, tag, upload, with a
      fake provider standing in for Drive.
- [ ] A real run on a real iPhone against the real club Drive before this is
      called done. Everything above can pass with a fake and still be wrong
      about Shared Drives, HEVC, or a slow-motion clip's rendered export.

## What this plan does not do

- **Photos as a browsable library.** A `Kind.photos` row on the landing list is
  a natural third noun, but the viewer's spine is `AthleteGroup` and Photos has
  no folders to get athletes from — so a Photos library would be a flat pile the
  viewer cannot group. Sorting is where unlabelled clips get names; that is the
  door Photos comes through.
- **Uploading originals.** Decided against — see Decisions.
- **Background upload while the app is closed.** The batch is deliberately
  foreground and watched. If it turns out coaches want to pocket the phone
  mid-upload, that is a `URLSession` background configuration and its own task.
- **Deleting from Photos after upload.** Never, without a much more explicit
  conversation than this plan is.

## Open questions

- **Two coaches, one run.** Skipping by filename stops one coach uploading
  twice; it does not stop two coaches uploading the same run under different
  camera filenames. Probably out of scope, worth naming.
- **Slow-motion and HDR.** What `loadFileRepresentation` hands back for a
  120 fps or Dolby Vision clip, and whether the resize step handles it, is
  unknown until tried on a device with real footage.
