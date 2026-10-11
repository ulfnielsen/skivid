# Draw and Measure on a Frame — Design

**Date:** 2026-10-11
**Status:** design approved in conversation; spec awaiting review.

## Goal

A coach pauses a clip in the single-clip viewer, draws on the frame to show a
racer something — the line they skied, the line they should ski, a body
axis — and measures angles such as the ski against the snow. Drawings can
cover a stretch of frames, are saved with the clip, and come back when the
clip is opened again, shown or hidden by one switch.

**Success:** a coach on an iPad draws a line on a frame, steps through the
next few frames watching the racer move against it, zooms in to 3× to place
an angle precisely, closes the clip, and on reopening finds both exactly
where they were — anchored to the picture, not the screen.

## What was decided with the user

- **Saved with the clip, display optional.** A "Show drawings" switch decides
  whether saved drawings appear. A quick sketch is a drawing you clear; there
  is no separate unsaved mode.
- **A drawing covers a span of frames.** It starts on the frame it was drawn
  on. **Stepping in drawing mode stretches every drawing on screen onto the
  new frame** (user's choice over "show faded, keep it on its frame").
  Jumping — scrubbing, tapping the timeline — never stretches.
- **Tools:** freehand pen, straight line / arrow, three-point angle, text.
  Circles were offered and not chosen.
- **Angle tool is three points:** corner, then the two arm ends. Ski to snow is
  corner where ski meets snow, one arm along the snow, one along the ski.
- **Approach A:** one drawing layer in the app, in video coordinates, shared
  by macOS, iPadOS and iPhone. PencilKit was rejected: no macOS canvas,
  screen-space strokes, and no line, angle or text tools.
- **Single-clip viewer only.** Compare comes later.
- **On this device first, Drive later.** The file format is chosen so the Drive
  step reads it unchanged.

## What the codebase already gives us (measured by reading it)

- **Zoom exists**: 1×–4× with pan, in `VideoZoom` (pure geometry, in core) and
  applied by `SinglePlayerView`/`ViewerPane`. `VideoZoom.layerFrame` is the
  single place that says where the video's picture sits in the pane. Drawings
  map through it, so they cannot drift from the picture.
- **Video size**: `ViewerModel` reads `player.currentItem?.presentationSize`
  (`ViewerModel.swift:1508`), which `VideoZoom` already takes as `videoSize`.
- **Sidecars**: `ClipAnalysisStore` writes `<stem>.skianalysis.json` beside a
  local clip and, for a remote clip, under `ClipIdentity.keyedStoreRoot` keyed
  by `pairKey`. An unreadable sidecar reads as absent and is never
  overwritten. The drawings store copies this shape.
- **Event rename already carries a new sidecar.** `EventRenamePlan.belongs`
  moves every file whose name starts with `<stem>.` together with its clip,
  so `<stem>.skidrawings.json` follows a rename with no change.
- **There is no single-frame step today.** `TransportAction.back1/forward1`
  seek one *second* (`ViewerModel.applyTransport`), and the macOS arrow keys
  emit `.seek` (`AppKitInputSource.swift:262`). This design adds a
  frame step for drawing mode.
- **Existing gestures on the video** (`ViewerPane`): tap toggles playback; a
  one-finger drag pans while zoomed. **There is no pinch**: zoom is the zoom
  chip's slider and buttons only.
- **Keys exist on macOS only.** `AppKitInputSource` turns keys into
  `PlaybackIntent`s; iOS uses `InertInputSource`, which emits nothing.
- **Nothing observes `scenePhase` today**, so saving on background is new.

## Behaviour

### Drawing mode

- **Enter:** a pencil button in the viewer's control bar, or **D** on macOS.
  Space on macOS leaves drawing mode and plays.
  Entering pauses playback and shows the palette.
- **Palette:** it takes the control bar's place below the video while drawing
  (the transport is meaningless in drawing mode, and a phone has no room for
  both). Move (hand) · pen · line/arrow (with an arrowhead toggle, on by
  default) · angle · text · colour (red, yellow, blue, black) · step back one frame ·
  step forward one frame · Clear frame · undo · redo · Done.
- **Gestures in drawing mode:** one finger or the mouse draws with the current
  tool; a tap does **not** toggle playback. Zoom stays on the zoom chip,
  which remains on screen. Panning while zoomed is the **Move** tool: with it
  chosen, a drag pans exactly as it does outside drawing mode. (Corrected
  after reading the code: the conversation assumed pinch and two-finger pan,
  and neither exists.)
- **Frame step:** in drawing mode the palette's step buttons, and ←/→ on
  macOS, move exactly one frame: an exact seek to the neighbouring frame
  boundary, `(round(t / frame) ± 1) · frame`, clamped to the clip. Not
  `AVPlayerItem.step(byCount:)`: stretching needs the from and to times at
  the moment of the step, and `step` reports neither. Outside drawing mode
  the arrows keep their one-second seek.
- **Stretching:** a frame step extends every drawing visible on the current
  frame onto the new one — forward extends its end, backward its start.
  Scrubbing or tapping the timeline in drawing mode moves without
  stretching.
- **Clear frame:** cuts every drawing visible here back to end on the previous
  frame. On a drawing's first frame it deletes that drawing.
- **Leave:** Done, or pressing Play. Leaving saves.

### Tools

- **Pen:** freehand, lightly smoothed (points closer than ~2 screen points are
  dropped, then the stroke is drawn as a smoothed path).
- **Line / arrow:** drag from start to end.
- **Angle:** press at the corner and drag the first arm; tap or drag to place
  the second arm's end. The value shows at the corner, 0–180°, whole degrees,
  updating live. The three points then carry handles.
- **Text:** tap to place, type, confirm. Tapping existing text edits it.
- **Line width and text size are constant on screen** at any zoom.
- **Selection:** a tap (no drag) on a mark selects it and shows Delete.
  Dragging a handle of a selected line or angle moves that point. Pen strokes
  can be deleted, not reshaped.
- **Undo/redo** cover drawing, editing, deleting, stretching and clearing,
  for as long as drawing mode stays open.

### Angle accuracy

The angle is computed in the clip's **pixel** space (normalized points scaled
by `presentationSize`), never in normalized or screen space; a non-square
picture would otherwise skew it. The first use of the angle tool shows a
one-line note: the angle is as filmed, and matches the real angle only when
the camera is roughly square-on to it.

### Outside drawing mode

- With **Show drawings** on, each drawing shows across its whole span during
  playback, scrubbing and stepping. The switch is remembered per device.
- The timeline shows each drawing's span as a short bar. The bars are
  **display-only**: attached to the slider they overlapped its hit area and
  their tap gesture took presses meant for it, and at 4pt they were too small
  to tap on iPad, so "tap a bar to jump to its start" was dropped rather than
  fixed. They sit below the slider's track and do not take hits.
- Instead, a scrub on the viewer's timeline that lands within ~6pt of a span
  is pulled onto it: onto its start from before it, onto its end from after
  it (the same frame for a one-frame mark), and not at all inside it, where
  the drawing is already on screen. Without this a one-frame mark — visible
  only within half a frame either side — is near impossible to scrub onto.
  The pull lands with the same frame-accurate seek as a frame step. The
  comparison screen's timeline has no drawings and does not pull.

### Which frames a drawing is on

A drawing is visible at time `t` when
`start − frame/2 ≤ t ≤ end + frame/2`, where `frame` is the clip's nominal
frame duration (1 / `nominalFrameRate` of the video track; 1/30 s if
unknown). Stepping lands on frame boundaries and stored times carry
rounding, so without the half-frame margin a drawing would flicker off on its
own last frame.

Every seek that lands a frame — a step, entering drawing mode, a scrub while
drawing, a pull onto a span — aims the player a quarter of a frame into the
frame while the stored and published time stays on the frame boundary. A
paused player shows the frame at or before the seek time, and at 29.97/59.94
fps a boundary rounded to 1/600 s falls just before its frame: aimed exactly,
148 of 150 steps showed the previous frame. Entering drawing mode and
scrubbing in it snap to the nearest frame, so the picture is always the frame
a new mark is stored on.

## Saving

- **File:** `<stem>.skidrawings.json`, JSON, with a `version` field (1).
  Each drawing: `id` (UUID), `kind` (`pen`/`line`/`angle`/`text`), `color`,
  `points` as fractions of the picture (0…1 on each axis over the picture;
  outside that range for a point drawn over the letterbox — deliberately not
  clamped, because clamping would distort a measured angle), `arrow` (line
  only), `text` (text only), `start` and `end` in clip seconds.
- **Where:** beside a local clip; under `ClipIdentity.keyedStoreRoot` by
  `pairKey` for a Drive clip — the same rule as `ClipAnalysisStore`.
- **When:** shortly after each change (debounced ~1 s), on leaving drawing
  mode, and when the app goes to the background. Writes are atomic. Saving
  an empty set deletes the file.
- **Unreadable file:** the clip shows no drawings, the file is never
  overwritten, drawing on that clip is refused, and a quiet notice says
  "Drawings for this clip couldn't be read."

## Components

**Core (`SkiVideoCore`, no AppKit/UIKit):**

- `Drawing` — one mark: kind, colour, normalized points, span, kind-specific
  fields. `Codable`, `Equatable`.
- `ClipDrawings` — a clip's marks. `visible(at:frameDuration:)`,
  `stretch(from:to:frameDuration:)`, `clear(at:frameDuration:)`.
- `DrawingGeometry` — picture ↔ pane conversion via `VideoZoom.layerFrame`;
  `angle(corner:a:b:videoSize:)` in pixel space; hit-testing a point
  against marks and handles, with a tolerance in screen points.
- `DrawingSession` — `@MainActor ObservableObject`: tool, colour, the mark in
  progress (including the angle's placement steps), selection, undo/redo.
  Drives `ClipDrawings`; knows nothing of views.
- `ClipDrawingsStore` — `load(for:)` → `.none` / `.drawings` / `.unreadable`;
  `save(_:for:)` with the never-overwrite-unreadable rule.

**App (`SkiVideoViewer`):**

- `DrawingOverlay` — a `Canvas` over the video drawing the visible marks;
  turns the drawing-mode gestures into `DrawingSession` calls.
- `DrawingPalette` — the tool bar.
- `ViewerPane` / `ViewerModel` — the drawing-mode switch, gesture routing,
  frame step, stretch-on-step, loading/saving per clip, the Show drawings
  switch.
- `TimelineScrubber` — the span bars (display-only).
- `DrawingAwareScrubber` — the viewer's timeline: pulls a scrub onto a nearby
  span (`ClipDrawings.scrubLanding`).
- `AppKitInputSource` — **D**, and ←/→ as frame steps while drawing.

## Error handling

- An unreadable drawings file: as above. Never overwritten.
- A failed save: the drawings stay in memory and on screen, and the viewer
  shows "Couldn't save drawings" with the reason; the next change retries.
- Switching clip mid-drawing saves the old clip's drawings first.
- `presentationSize` still zero (asset not loaded): drawing mode is disabled
  until the size is known, since points cannot be normalized without it.

## Out of scope (deliberately, for later)

- Saving drawings to the club Drive (the format is ready for it).
- Drawing in Compare.
- Exporting an annotated frame as an image.
- Circles / ellipses.
- Moving or reshaping whole pen strokes.
- Apple Pencil pressure and tilt.
- Automatic angle measurement from pose detection (pose does not find skis).

## Testing

**Core unit tests** (`--filter SkiVideoCoreTests`, no windows):

- Stretch forward, stretch backward, stretch with nothing visible.
- Clear on a drawing's first frame deletes; on a later frame truncates.
- Visibility at exactly `start − frame/2`, `end + frame/2`, and just outside.
- Angle: known right angle and 45°; a non-square `videoSize` where the
  normalized-space answer would be wrong.
- Picture → pane → picture round-trip at 1×, 2×, 4×, panned to each edge,
  and with letterboxing.
- Store: round-trip; Drive identity uses the keyed store; unreadable file is
  reported and not overwritten; empty set deletes the file.
- Session: undo/redo across draw, stretch, clear, delete; the angle's three
  placement steps; selection by tap versus drag.

**UI tests (iPad and iPhone simulators):**

- Enter drawing mode, draw a line, step three frames: the line is present on
  all four (accessibility readout of visible drawing count).
- Close and reopen the clip: the drawing is still there.
- Zoom to 3×: the line's endpoints stay on the same picture point —
  verified by screenshots shown to the user.
- An angle drawn between known points reads the expected value.

**macOS:** the **D** shortcut and frame-step arrows through the existing
input-source tests; drawing with the mouse through a view test.
