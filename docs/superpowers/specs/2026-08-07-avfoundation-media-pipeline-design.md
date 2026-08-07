# AVFoundation Media Pipeline — Replacing ffmpeg

**Date:** 2026-08-07
**Status:** Approved design, not yet implemented
**Applies to:** the Sort & Resize transcoding pipeline

## Problem

### Resize is broken when the app is launched normally

`FFmpegMediaPipeline.swift:49-50` runs `/usr/bin/env ffmpeg`, which resolves
through `PATH`. Measured:

- with a login shell's `PATH` → `ffmpeg version 8.1.1`
- with the `PATH` a Finder- or Dock-launched `.app` actually gets
  (`/usr/bin:/bin:/usr/sbin:/sbin`) → `env: ffmpeg: No such file or directory`

`launchctl getenv PATH` is unset, so GUI-launched apps get the bare default.
ffmpeg lives at `/opt/homebrew/bin/ffmpeg`, which is not on it. Resize therefore
works when the app is started from a terminal and fails when it is started the
way anyone actually starts it. Nothing in recent work caused this; `runFFmpeg`
has one commit in its entire history.

### Shelling out has three further costs

- **`Process` does not exist on iOS.** While transcoding shells out, Sort &
  Resize can never run on iPad — which is why `IOSSecondaryScreenPresenter`
  hard-codes `canPresentSorting == false`.
- **Bundling the binary is not an option.** The installed ffmpeg is built
  `--enable-gpl --enable-version3`, so shipping it inside the app would put the
  app under GPLv3. Avoiding that would mean building and notarising a custom
  LGPL ffmpeg.
- **The pipeline cannot be tested where the binary is absent**, which is the
  same failure mode as the bug above.

## What the resize actually does

Measured on a real pair from the library:

| | source | after resize |
|---|---|---|
| dimensions | 1920×1080 | 1920×1080 |
| codec | H.264 High, `yuv420p` | H.264 High 4.2, `yuv420p` |
| video bitrate | 7.41 Mbps | 3.70 Mbps |
| frame rate | — | 50 fps |
| audio | — | AAC 48 kHz stereo, 128 kbps |
| file size | 45.1 MB | 22.3 MB |

**The source was already 1080p, so no scaling happened.** What this step buys is
bitrate reduction — roughly half — not geometry. That is why the design pins the
encode settings explicitly rather than accepting a preset: a preset would hand
Apple's bitrate policy the one number that matters.

## Design

### Where it lives

`FFmpegMediaPipeline` is deleted. `AVFoundationMediaPipeline` replaces it in
**`Sources/SkiVideoCore/`**, not in the macOS target, so it compiles for iOS.
The `MediaPipeline` protocol in `Seams.swift` is unchanged — this is a swap
behind an existing seam, one line at each app's composition root.

### `resize` — AVAssetReader plus AVAssetWriter

An export session is not used, because only the writer exposes the settings that
matter:

| setting | value | rationale |
|---|---|---|
| `AVVideoWidthKey` / `AVVideoHeightKey` | fit within 1920×1080, aspect preserved, computed explicitly | full control over geometry |
| `AVVideoAverageBitRateKey` | `round(width × height × 1.784)` bits/s | 3.7 Mbps at 1920×1080, matching today's output, scaling linearly with pixel count |
| `AVVideoProfileLevelKey` | `H264HighAutoLevel` | source and current output are both High |
| pixel format | `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` | 8-bit 4:2:0, so `kVTVideoDecoderBadDataErr` (−8969) cannot return |
| frame rate | the source's, never forced | this footage is 50 fps; forcing 30 would silently drop half the frames |
| audio | AAC, 48 kHz, stereo, 128 kbps | matches today's output |

**A source with no audio track produces an output with no audio track.** Today's
`-map 0:a?` makes audio optional; the writer must do the same rather than fail
or synthesise silence. Clips trimmed from screen recordings and some drone
footage arrive without audio.

**Never upscale.** Precisely: let `s = min(1920 / width, 1080 / height)` taken
from the source's *transformed* (display) dimensions. If `s >= 1` the output
keeps the source's dimensions unchanged; otherwise both dimensions are
multiplied by `s` and rounded to even numbers, which H.264 4:2:0 requires.

This differs from ffmpeg's `force_original_aspect_ratio=decrease`, which *will*
enlarge a source smaller than the box. Upscaling only inflates bytes, so clips
below 1080p will come out smaller than they do today. This is a deliberate
change.

**Bitrate follows the output, not the source.** A clip left at 1280×720 by the
rule above gets `1280 × 720 × 1.784 ≈ 1.64 Mbps`, not the 1080p figure.

`-pix_fmt yuv420p` disappears from the codebase as a concept: the writer is
configured for 8-bit 4:2:0, so there is no path to the 10-bit 4:4:4 output that
broke iPad playback.

### `writeMetadata` — passthrough export

A remux, not an encode, so there is no encode setting to control.
`AVAssetExportPresetPassthrough` plus metadata, written to a temporary file and
then `replaceItemAt`, the same shape as today. Passthrough carries only the
tracks AVFoundation recognises, which reproduces the effect of today's
`-map 0:v:0 -map 0:a?` — proprietary camera telemetry tracks are dropped.

### Metadata identifiers

`commonIdentifierTitle`, `commonIdentifierArtist` and
`commonIdentifierDescription`. AVFoundation maps common identifiers into the
right key space per container.

**The fidelity bar is low, and that is a measured fact rather than an
assumption.** Nothing in the app reads these tags back: `VideoLibrary.scan`
derives the athlete from the containing folder name
(`video.deletingLastPathComponent().lastPathComponent`), not from metadata. The
tags exist for Finder, Photos and other external tools. The requirement is
"shows up sensibly in Finder", not "round-trips through our own parser".

### Format policy

`mkv`, `webm` and `avi` are removed from `VideoLibrary.supportedExtensions`.

**This is a bug fix, not a feature removal.** The app lists `.mkv` today and
`AVPlayer` cannot open it. Measured on a real file from the library:
`AVURLAsset.load(.isPlayable)` fails with *Cannot Open*, while the same probe on
an `.mp4` returns `isPlayable=true, videoTracks=1`. The 14 Matroska files in the
library — YouTube downloads, H.264 video with Opus audio — currently appear in
the sidebar and fail to play. After this change they are simply not listed.

The sorting flow additionally rejects an unreadable source explicitly: an asset
whose `.isPlayable` is false produces a clear "this format cannot be read" error
rather than a cryptic writer failure partway through.

## Structure

| File | Responsibility |
|---|---|
| `Sources/SkiVideoCore/AVFoundationMediaPipeline.swift` | **create** — both operations |
| `Sources/SkiVideoViewer/macOS/FFmpegMediaPipeline.swift` | **delete** |
| `Sources/SkiVideoCore/VideoLibrary.swift` | **modify** — `supportedExtensions` |
| `Sources/SkiVideoCore/SortingModel.swift` | **modify** — reject unreadable sources |
| `Tests/SkiVideoViewerTests/FFmpegMediaPipelineTests.swift` | **delete** |
| `Tests/SkiVideoCoreTests/AVFoundationMediaPipelineTests.swift` | **create** |

`SkiVideoCore` may not import AppKit, UIKit, SwiftUI or Process; `AVFoundation`
is already imported there by `ViewerModel` and `ComparisonModel`.

## Testing

The current `FFmpegMediaPipelineTests` can only run where an `ffmpeg` binary is
on `PATH` — the same fragility as the bug this replaces. The new pipeline is
in-process and tests like any other code, which is why its tests move from the
app target into `SkiVideoCoreTests`.

The project already has `makeRealVideoFile` in
`Tests/SkiVideoCoreTests/RealVideoFixture.swift`, generating real H.264 of a
known length with `AVAssetWriter`. That makes a genuine round-trip available:
generate, resize, load the output back with `AVURLAsset`, and assert on

- output dimensions, including the never-upscale rule;
- frame rate preserved (a fixture at 50 fps, so a forced 30 would fail);
- pixel format 8-bit 4:2:0;
- duration preserved;
- `preferredTransform` preserved — see risk 1;
- metadata items present;
- the audio track surviving.

Assert on **properties**, not on exact byte sizes or achieved bitrates:
VideoToolbox behaviour differs between hosts and those figures will be flaky.

## Risks

1. **`preferredTransform` is the one most likely to bite.** Camera and phone
   clips carry a rotation transform. `AVAssetReader`/`AVAssetWriter` do not
   carry it for you — get it wrong and portrait footage comes out sideways.
   It will look fine on generated fixtures, which have an identity transform, so
   this needs an explicit test with a rotated fixture. The concern applies to
   `writeMetadata` as well.
2. **Average bitrate is not CRF.** x264 at its default is quality-targeted and
   varies with content; `AVVideoAverageBitRateKey` is not. Matching 3.7 Mbps
   nominally does not mean matching quality clip-for-clip, and busy snow spray is
   exactly where they diverge. This needs eyeballing on a real run, not only a
   passing test.
3. **The 14 Silvretta mkv files become invisible.** They are already unplayable,
   so nothing that works today breaks, but they will silently stop being listed.
   Converting them once with the existing ffmpeg install is the remedy if they
   are wanted.
4. **VideoToolbox differs by host.** Encoder behaviour on Apple silicon macOS is
   not identical to the simulator.

## Out of scope

- **iPad Sort & Resize.** This work removes the blocker — the pipeline compiles
  for iOS — but `canPresentSorting` stays `false` and no iPad sorting UI is
  built. Enabling it needs folder picking, security-scoped write access and file
  moving on a user-chosen folder, and the flow MOVES files, so it is its own
  spec. Encouraging finding for that follow-up: `organized/` and
  `organized_resize/` are both `source.appendingPathComponent(...)`
  (`SortingModel.swift:170-171`), so a single security scope covers reading,
  folder creation, moving and writing.
- **The interim ffmpeg `PATH` fix.** Deliberately not done — the code is
  scheduled for deletion, so resize stays broken from Finder until this lands.
- **The resize queue's one-at-a-time serialisation**, which stays exactly as it
  is.
- **Progress reporting.** `AVAssetWriter` could report it where ffmpeg could
  not; not designed here.
