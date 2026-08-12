# Zoom and pan for the viewer and the comparison window

Date: 2026-08-11

A coach reviewing a run wants to get closer than the camera did — to the hands,
the edge angle, the ski tips. Today neither screen can. This adds a zoom
control and drag-to-pan to both, with per-side zoom in the comparison window so
two runs shot from different distances can be framed to match.

## Behaviour

| | Viewer | Comparison, side-by-side | Comparison, overlay |
| --- | --- | --- | --- |
| Zoom range | 1×–4× | 1×–4×, **per side** | 1×–4×, one zoom for the stack, **capped by the alignment shift** — see the correction below |
| Control | a chip on the video | a chip on each pane | one chip on the stack |
| 1× | whole frame, letterboxed | whole frame (unchanged) | whole frame (unchanged) |
| Pan | drag on the video, above 1× only | same, per side | same, moves the pair |
| Reset | click the level | double-click, or click the level | click the level |

> **Corrected 2026-08-12, after Tasks 6 and 7.** The Reset row originally read
> "double-click, or click the level" on all three screens. Only the
> side-by-side panes shipped both.
>
> **The viewer has no double-click, and the absence is a measurement.** A
> `count: 2` tap makes SwiftUI hold *every* single tap until the double-click
> window closes, whether or not a second click ever comes — and the viewer's
> single tap is play/pause. Measured on `ViewerPane` hosted in a real window,
> five synthetic single clicks per configuration, mouse-down to `player.rate`
> changing: **1.2 ms median** (3.6 ms worst) with the single tap alone, against
> **358 ms median** (363 ms worst) with a `count: 2` tap beside it — 2.4× the
> 150 ms this document's Risk 2 called perceptible, paid on the app's most-used
> gesture whether or not anyone ever double-clicks. Declaration order does not
> buy it back (357 ms / 358 ms either way). The full note, including what 358 ms
> is *not*, is on `ViewerPane` beside the gap where the gesture would go.
>
> **The overlay has no double-click either**, which was never a decision so much
> as an omission — `ComparisonVideos`' overlay branch has no tap gesture at all.
> It is left that way: the stack's chip carries the level readout, and the two
> panes are where a coach reaches for a double-click.

Zoom persists across clips — comparing several runs of one drill at a fixed
magnification is the point — and resets when the library changes
(`openDirectory`, `connectGoogleDrive`), where a stale pan would be meaningless.

## 1× means the whole frame, on both screens

The viewer renders through `AVPlayerView` with `.resizeAspectFill` today: it
crops to fill the pane, so the frame edges are never visible. The comparison
panes do the opposite. After this change both letterbox at 1×.

This is not a new opinion. The iPad player already chose `.resizeAspect`, and
recorded why (`Sources/SkiVideoViewer/iOS/NativePlayerView.swift:14-20`):

> A skier leaving the visible frame defeats the point of a coaching viewer, so
> letterbox instead of crop.

macOS used fill only because its minimum window aspect (980/640 ≈ 1.53) is close
enough to 16:9 that fill crops a sliver. Applying the iPad's rule to the Mac
makes 1× mean one thing everywhere, which a zoom control needs.

## `VideoZoom`

A pure value type in `SkiVideoCore` — no AVFoundation, no UI:

```swift
public struct VideoZoom: Equatable, Sendable {
    public static let range: ClosedRange<Double> = 1.0...4.0

    public private(set) var scale: Double      // within `range`
    public private(set) var center: CGPoint    // normalised; which point of the
                                               // frame sits at the pane's middle

    public var isZoomed: Bool { scale > 1 }

    public mutating func setScale(_ newScale: Double, in bounds: CGSize, videoSize: CGSize)
    public mutating func pan(by translation: CGSize, in bounds: CGSize, videoSize: CGSize)
    public mutating func reset()

    public func layerFrame(in bounds: CGSize, videoSize: CGSize) -> CGRect
}
```

### The invariant

**The picture must always cover the pane, on both axes, whenever it is large
enough to.** Per axis, with `fitted` the aspect-fitted size of the video in the
pane:

```
half   = min( bounds / (2 × fitted × s) , 0.5 )
center ∈ [ half , 1 − half ]
```

> **Corrected 2026-08-11, in Task 1's second review round.** This was originally
> `[1/(2s), 1 − 1/(2s)]` — a fraction of the *video*, not of the pane. That
> stops the picture vanishing but still allows a gap where full coverage was
> achievable: measured, a 16:9 clip in a 500×800 pane at 4× is 1125pt tall
> against an 800pt pane — big enough to fill it — yet at the pan bound the
> operator sees a 259pt black band (32.4% of the pane) they cannot pan away. A
> sweep found 25,808 such combinations. The form above closes it.

Read the three regimes:

- **Aspects match** — `fitted == bounds`, so `half = 1/(2s)` and this is exactly
  the original rule. Nothing about the matched case changes.
- **The picture is larger than the pane on an axis** — `half < 0.5`, and the
  interval is precisely the set of centres that keep the pane covered.
- **The picture is smaller than the pane on an axis** — `half` clamps to `0.5`
  and the interval collapses to the single point. Bars are unavoidable there;
  centring them is the right answer, and it is what `s = 1` does on every axis.

Because the bound depends on the pane and the video, the mutators take both:
`setScale(_:in:videoSize:)` and `pan(by:in:videoSize:)`.

**`layerFrame` clamps again, defensively.** A window resize changes `bounds`
with no mutator called, so a centre legal for the old pane can be illegal for
the new one. The mutators keep the stored value tidy; `layerFrame` guarantees
nothing is ever *rendered* out of bounds. Both are cheap, and the failure they
prevent is a black band the operator cannot explain.

### What a drag means

`pan(by:in:)` takes the drag in points and the pane's size in points. A drag of
`d` points must move the picture `d` points on screen at every scale, so the
centre moves by `d / (paneSize × scale)` in normalised units — the `scale`
divisor is what keeps a drag feeling the same at 4× as at 1.5×, rather than
four times as fast.

**Dragging right moves the picture right, so the centre decreases**: the operator
is pushing the frame around, not pushing a viewport over it. Both signs are
defensible in the abstract and only one matches every video app the operator has
used, so it is pinned here and asserted in a test rather than left to whoever
writes the gesture.

Both mutators re-establish the invariant. `pan` clamping is obvious;
**`setScale` clamping is the one that gets forgotten** — zooming out from a panned position widens
nothing but shrinks the legal interval's complement, and an un-reclamped centre
leaves the picture hanging off the edge with black down one side. That defect is
the reason this type exists as a separate, exhaustively tested value.

### `layerFrame`

> **Corrected 2026-08-11, after Task 1's review.** This section originally had
> `layerFrame` scale the *pane's* rect and claimed the geometry needed no aspect
> ratio at all. Measured, that clamps the wrong rectangle: `.resizeAspect`
> letterboxes the picture into a sub-rect of the layer, so when the pane's
> aspect differs from the clip's, the picture can be panned entirely off the
> pane while the layer still covers it. A 16:9 clip in a 500×800 pane shows 2.7%
> of the picture at 3× and **0.0% at 4×**, with the pan at its bound and no
> resistance to tell the operator they have gone past it. The comparison panes
> are unconstrained in both axes with a 1000×680 window minimum, so
> roughly-square panes are the normal case there.
>
> The signature is now `layerFrame(in bounds: CGSize, videoSize: CGSize)`: it
> scales the *aspect-fitted* rect of the video within the pane, so the picture
> rect and the layer rect coincide and the invariant below bounds what the
> operator actually sees. `videoSize` is the item's `presentationSize`; when it
> is zero or non-finite — which is what an item reports before it loads — the
> pane's rect is used, which is correct rather than a fudge, because there is no
> picture on screen yet to bound.

**The rest of this section describes the corrected form.**

`layerFrame` returns the rect to give the `AVPlayerLayer`: the video's fitted
rect scaled by `scale`, positioned so `center` lands at the pane's middle.

```
fitted = largest rect of the video's aspect that fits bounds
size   = fitted × s
origin = bounds × 0.5  −  center × size
```

Read the origin as: put the layer where the normalised point `center` lands at
the pane's middle. Check it at the corners of the range — with a pane matching
the clip's aspect, `s = 1, center = 0.5` gives origin `0` and a layer exactly the
size of the pane; `s = 2, center = 0.25` gives origin `0`, a layer twice as wide,
and the frame's left quarter-point sitting at the pane's middle.
(`(0.5 − center) × size` is the plausible wrong answer for the origin: it agrees
at `s = 1` and drifts everywhere else.)

Because the fitted rect already absorbs the aspect difference, `.resizeAspect`
has no bars left to add — the picture fills the layer exactly, which is what
makes the clamp below bound the picture rather than a box around it.

The pane clips the overflow (`masksToBounds`).

### Why not `.scaleEffect`

A SwiftUI `.scaleEffect` on the player view would magnify an already-rendered
bitmap and go soft at 4×. Enlarging the layer's frame asks `AVPlayerLayer` to
render at the larger size instead. See Risks — this is the expected behaviour,
not yet a measured one.

## Rendering: one path for both screens

`SinglePlayerView(player:zoom:)` gains the zoom and hands it to its
`PlayerLayerHostView`, which reads the item's `presentationSize` and applies
`layerFrame` in `layout()` inside the same
`CATransaction` that already disables implicit animation (a zoom that eased in
would lag the video exactly as a resize did).

The viewer moves off `NativePlayerView` onto `SinglePlayerView`. That is what
makes 1× identical on both screens, and it retires a macOS/iPad divergence
rather than adding a third rendering path: both `NativePlayerView` files become
unused and are deleted. Neither used any AVKit feature beyond hiding the
controls, which both already did.

## State

- `ViewerModel.zoom: VideoZoom`, published.
- `ComparisonModel.leftZoom` / `rightZoom`, published, with `zoom(for:)` and a
  per-side mutator following the shape `nudge`/`seek` already use.

### The overlay layout uses the left clip's zoom for both

`OverlayPlayerStack` positions the top clip by an alignment translation
expressed in normalised frame widths, and masks both clips to the region they
share (`sharedRect`). Two independent scales would invalidate both the
registration and the mask.

One zoom applied to the stack magnifies the aligned pair as a unit, so the
translation stays correct in normalised units and the shared region scales with
everything else. Per-side zoom stays a side-by-side feature; the overlay's job
is comparing an aligned pair, not reframing one of them.

> **Corrected 2026-08-12, after Task 6.** This section, and the Behaviour table
> above it, both said the overlay's range is plainly 1×–4×. It is not: the
> overlay's zoom is **capped**, and the cap is the largest design change in the
> feature. It is applied twice, and both applications are load-bearing.
>
> **The cap.** `OverlayPlayerStack.maximumScale` bounds the scale at
>
> ```
> min( 4× , 0.9 / max(a, b) )      a = |dx|·Wr/container.width
>                                  b = |dy|·Wr/container.height
> ```
>
> with `Wr` the video's *rendered* width in the container — the same ruler
> `offset` normalises by, which is why `dy` is scaled by a width. (`max(|dx|,
> |dy|·Wv/Hv)` is the shorthand, and it is only the same number when the clip
> fills the container's width; for a pillarboxed clip it is conservative by a
> stop — measured, 2.57× against the accurate 2.89× at `dx 0.35` in a 1000×500
> area.)
>
> **Why there is a cap at all.** The strip the alignment shift opens between the
> two clips is a fixed fraction of the *picture*, so it grows with the scale
> while the container does not: zooming in shrinks the region the pair shares,
> and far enough in it eats the frame entirely. Measured on an 800pt stack at
> 4×, shared region across: `dx 0.20` → 160pt, `dx 0.225` → 80pt, **`dx 0.25` →
> exactly 0pt**, `dx 0.30` → nothing at all. `dx 0.25` is not an extreme: a pure
> horizontal shift of a quarter frame is an overlap of 0.75, which is exactly
> `AlignmentGate.defaultEngageAbove`. So without the cap, a pair sitting on the
> gate's own engage threshold blacks the overlay out at the top of the slider.
>
> **The `0.9` is deliberate, and it is not a fudge factor.** `1/max(a, b)` is
> precisely where the shared region reaches zero, so capping *there* would put
> the black screen at the top of the slider — the failure moved rather than
> removed. Measured across the nine cases of
> `testTheSharedRegionIsNeverEmptyAtTheCappedMaximum`: under `1/max(a, b)`,
> **eight of nine leave exactly 0.0pt** on the binding axis (the ninth is `dx
> 0.05`, whose bound clamps to the range's own 4× long before it binds).
> `0.9/max(a, b)` lands every one of those eight on exactly 10.00% of the
> container. A tenth is the smallest strip that is still a comparison rather
> than a sliver, and it costs a well-aligned pair nothing: everything out to `dx
> 0.225` still reaches the full 4×.
>
> **A second clamp at draw time, `OverlayPlayerStack.drawnZoom`.** The chip's
> cap is computed from the translation in force when the operator moves the
> slider; `AlignmentGate` returns the **raw measured** translation inside an
> engaged run, with no magnitude bound — only the engage/disengage *decision* is
> median-filtered. This repo's own two fixtures flip between *adjacent* samples
> from `dy ≈ −0.04` (overlap 0.79) to `dy ≈ −0.42` (overlap 0.23). At `dy −0.42`
> the region collapses from 1.34×, while the cap computed at the neighbouring
> quiet sample is the full 4×. So a 4× that was legal when it was set draws
> black frames a sample later, on the fixtures this feature was built against.
> `drawnZoom` bounds what is *painted* against the translation it is painted
> with; without it the chip's cap makes "the region cannot collapse" only
> usually-true.
>
> **The trade, accepted rather than discovered later.** The draw-time clamp
> swaps a black frame for a transient scale-*and-position* jump on flicker
> frames: the picture zooms out for those frames and comes back, and because
> `setScale` re-clamps the centre into the narrower interval a lower scale
> brings, an off-centre pan snaps toward the middle and back out with it —
> measured, an overlay panned to its 4× corner (centre 0.875) draws at 1.205×
> and centre 0.585 on a `dy −0.42` sample, then returns to 4× / 0.875 on the
> next quiet one. `sharedRect` argues elsewhere that a picture jumping scale
> mid-run is worse than one losing a border, and this *is* a scale jump; it is
> the lesser evil only because the alternative is not a border but the whole
> frame. **If the flicker proves distracting in the running app, the fix is to
> smooth this bound over time — not to remove it.**

## Controls

**Viewer** — a chip on the video, bottom-trailing, the same control the
comparison panes carry.

> **Corrected 2026-08-11, after Task 4.** This was originally a slider in
> `ViewerControlBar`. Measured, that pushed the bar's ideal width from 557.0pt
> to 793.0pt: unchanged on an iPad Pro portrait (834pt, still one row at 104pt)
> but wrapping on an iPad mini portrait (744pt), where the band grows to 156pt —
> 26pt taller than the ~130pt control band an earlier redesign deleted. Spending
> that on the smallest screen, where video area is scarcest, is the wrong trade.
>
> On the video it costs no layout height at all, the bar returns to 557.0pt and
> one row everywhere, and both screens gain the same interaction. It also
> removes a plumbing seam: the bar is the video's *sibling* and had no pane
> size, so wiring it required reporting the pane's size up through `ContentView`;
> `ViewerPane` already has that size from its own `GeometryReader`.

**Comparison** — a compact chip on each pane, bottom-trailing, opposite the
existing clip-name chip: `−`, slider, `+`, level. Per side by construction, so
no side selector is needed, and the control bar keeps its width.

The bar was the obvious home and is the wrong one. It is measured at 941pt ideal
and wraps to two rows below that
(`ComparisonControlBar.swift:12-19`); a slider plus a side selector would push
that threshold up again on a screen where every iPad portrait width is already
below it. The chips cost it nothing.

In overlay layout, one chip for the stack, placed with the overlay's existing
clip choosers.

## Gestures

- **Drag on the video → pan**, enabled only when `isZoomed`. At 1× the drag is
  not installed at all, so it cannot swallow anything.
- **Viewer tap → play/pause**, unchanged. A tap and a drag are distinct
  gestures and compose.
- **Double-click → reset**, and the level readout is itself a button that
  resets.

The reset button is not redundant with the double-click. Adding a double-tap
beside an existing single-tap makes SwiftUI wait to see whether a second tap is
coming, which can delay play/pause. The button is the route that does not depend
on gesture arbitration — and if the delay measures perceptible, the double-click
is dropped and the button remains.

## Testing

**`VideoZoomTests`** carries the weight — a pure value with no media fixtures:

- `setScale` re-clamps a panned centre (zoom in to 4×, pan to a corner, zoom
  back to 1.5×, assert the centre moved to the new legal bound).
- `pan` stops at each of the four edges and does not overshoot on a large drag.
- A drag moves the picture the same number of points at 1.5× and at 4× (the
  `scale` divisor), and in the same direction as the drag (the sign convention).
- `scale == 1` pins the centre to 0.5 whatever the pan history.
- `layerFrame` covers the pane at every scale in the range — no gap at any edge,
  at 1× exactly the bounds — and is correct for a non-square pane.
- The range is enforced at both ends.

**Rendering** — `layerFrame` is asserted directly; `PlayerLayerHostView` is a
thin applier. One test that the host view's layer frame follows the zoom it is
given, in the style of the existing `attachedPlayer` seam.

**Wiring** — the models expose and mutate zoom; `ComparisonPane` passes its own
side's zoom (mutation-check: building both panes with `.left` must fail);
`OverlayPlayerStack` receives the left's.

**Overlay** — a test with a non-zero translation at 2× confirming both clips
stay masked to the same rect.

**Bar layout** — `ViewerControlBarLayoutTests` re-measured after the slider
lands, recording the new number rather than adjusting a control to preserve the
old one, which is that file's stated convention.

## Risks

1. **Sharpness at 4×.** Enlarging the layer frame should make `AVPlayerLayer`
   render at the larger size rather than upscale. That is how AVFoundation is
   expected to behave, not something measured in this project. First
   implementation step is a throwaway check on a real clip at 4×. If it does
   upscale, the fallback is to render at native resolution and clip, at the cost
   of more layer area.
2. **Double-tap delaying play/pause** — measured, and the double-click dropped
   if perceptible.
3. **The overlay's `sharedRect` under zoom** — reasoned, not measured; the
   overlay test above is what settles it.

## Out of scope

Pinch and scroll-wheel zoom; zoom presets; remembering zoom per clip; zoom in
the secondary-screen or exported output.
