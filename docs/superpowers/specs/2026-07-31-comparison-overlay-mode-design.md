# Comparison Overlay Mode — Design

Date: 2026-07-31
Component: `SkiVideoViewer` (macOS SwiftUI app)

## Goal

Add a superimposed playback mode to the existing Compare Videos window so two clips can be
watched drawn on top of each other, not only side by side. This is a first experiment:
there is deliberately **no spatial alignment** — no anchor points, no pan, no zoom, no
rotation. Both clips are drawn into the same rect and whatever registration results is what
the user sees. Alignment is a follow-up decision to be made after using this.

## Scope

In scope:

- A layout toggle (Side-by-side / Overlay) inside the existing Compare Videos window.
- Two blend modes in overlay: opacity blend and difference blend.
- Reuse of the existing two-player model: sync points, host-clock paired playback,
  independent per-side scrubbing, keyboard handling.

Out of scope (explicitly, for this iteration):

- Spatial alignment of any kind — anchor points, pan, zoom, rotation, auto-registration.
- A separate overlay window or a second model.
- Per-side color tinting.
- Any change to the side-by-side layout's behaviour.

## Architecture

The overlay is a second *layout* over the same `ComparisonModel`. Nothing about video
loading, seeking, syncing, or playback changes. Three things are added: model state for the
layout and blend, a new view that stacks two `AVPlayerLayer`s, and a split of
`ComparisonView`'s pane so its header and transport rows can be reused by both layouts.

### Rendering — new file `Sources/SkiVideoViewer/OverlayPlayerView.swift`

An `NSViewRepresentable` wrapping a single `NSView` that hosts two `AVPlayerLayer`s in the
same bounds:

- **bottom layer** = `leftPlayer`
- **top layer** = `rightPlayer`
- both layers use `videoGravity = .resizeAspect` (aspect-fit, not the side-by-side view's
  `.resizeAspectFill`) so neither clip is cropped and both occupy the same frame
- both layers' frames follow the host view's bounds on resize

Blend behaviour:

- **Blend mode:** top layer's `opacity` is set from `model.overlayOpacity`. `0` shows only
  the left clip, `1` only the right, `~0.5` gives the ghosted double exposure.
- **Difference mode:** top layer's `compositingFilter` is set to
  `CIFilter(name: "CIDifferenceBlendMode")` and its opacity is forced to `1.0`. Identical
  pixels render black; divergence lights up. Compositing is done by CoreAnimation on the
  GPU — no `AVVideoComposition`, no per-frame CPU work.
- Leaving Difference mode sets `compositingFilter = nil`.

`dismantleNSView` sets both layers' `player` to `nil` so that switching layouts cannot leave
an `AVPlayer` bound to a torn-down layer while the other layout attaches it.

### Model — `Sources/SkiVideoViewer/ComparisonModel.swift`

Two new enums and three new published properties. No existing method changes.

```swift
enum ComparisonLayout { case sideBySide, overlay }
enum OverlayBlend { case blend, difference }

@Published var layout: ComparisonLayout = .sideBySide
@Published var overlayOpacity: Double = 0.5
@Published var blend: OverlayBlend = .blend

var topLayerOpacity: Double {   // difference blending needs full opacity to read
    blend == .difference ? 1.0 : overlayOpacity
}
```

`topLayerOpacity` is the one non-obvious rule and is the unit-tested part.

### View — `Sources/SkiVideoViewer/ComparisonView.swift`

`videoPane(side:)` is split into two reusable builders with no behaviour change:

- `paneHeader(side:)` — "Left"/"Right" label, file name, "From Open Folder…" menu,
  "Choose File…" button.
- `paneTransport(side:)` — scrubber, timecode, −5s/−1s/Play-Pause/Slow 0.25×/+1s/+5s.

Side-by-side composes them exactly as today (header, `NativePlayerView`, transport, per
side). Overlay composes:

```
[ Side-by-side | Overlay ]              <- segmented picker
 paneHeader(.left)   |  paneHeader(.right)
+--------------------------------------+
|      right drawn over left           |   <- OverlayPlayerView
+--------------------------------------+
 opacity ------o------   mode [ Blend | Difference ]
 paneTransport(.left) | paneTransport(.right)
[ synchronizedControls — unchanged ]
```

The opacity slider is disabled in Difference mode, with a short hint explaining that
difference blending uses full opacity.

Keeping the per-side transports in overlay mode is deliberate: the user can nudge the two
clips into *time* alignment while watching them superimposed, then press **Set Sync Points**.
That is the main thing that makes the mode useful without spatial alignment.

## Data flow

Unchanged from today. `ComparisonModel` owns both `AVPlayer`s; the views observe published
time/duration/status and call model methods. The overlay view is a pure consumer of
`leftPlayer`, `rightPlayer`, `topLayerOpacity`, and `blend`.

## Error handling

- Missing second video: the overlay simply shows whatever single clip is loaded. The
  existing "Choose both videos before setting sync points" guard is untouched.
- Clips of differing resolution or aspect: aspect-fit means both are letterboxed into the
  same rect; no crash, just imperfect registration (expected — see Known limitation).
- `CIFilter(name:)` returning `nil`: treated as blend mode with full opacity rather than
  failing; a filter name this standard is not expected to fail, but the code must not force
  unwrap.

## Testing

`Tests/` currently covers `VideoLibrary` only. `ComparisonModel` is `@MainActor` and owns
`AVPlayer`s, but can be constructed with no media, so add `ComparisonModelTests` covering
the pure state rules:

- default layout is `.sideBySide`, default blend is `.blend`, default opacity `0.5`
- `topLayerOpacity` equals `overlayOpacity` in blend mode
- `topLayerOpacity` is `1.0` in difference mode regardless of `overlayOpacity`
- toggling layout does not disturb blend or opacity state

Rendering, compositing, and the layout switch are verified by running the app against two
clips — automated tests are not attempted for the `AVPlayerLayer` compositing.

## Known limitation

With no spatial alignment, Difference mode reads as noise unless the two clips were shot
from a near-identical camera position. Blend mode at ~50% opacity is useful regardless. This
is the expected outcome of the experiment: manual pan/zoom or anchor-point registration is
the follow-up if Difference looks promising but misregistered.
