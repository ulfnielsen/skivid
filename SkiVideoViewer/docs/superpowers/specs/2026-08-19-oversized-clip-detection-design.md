# Refusing, and repairing, clips that are too big to fetch

Date: 2026-08-19

Coaches upload footage straight to the club's Shared Drive. Those clips never
pass through this app's resize step, so they arrive at whatever bitrate the
phone or camera chose — one observed example is **400 MB**. Playing it means
fetching all of it.

This adds three things: notice such a clip before downloading a byte, refuse to
fetch it, and offer to replace it in Drive with one the app would have produced.

## What "too big" means

The app already knows the answer. `AVFoundationMediaPipeline` targets
**1.784 bits per pixel per second** — 3.70 Mbps at 1080p — and that number is
measured, not chosen: on real footage the step halved a clip from 7.41 to
3.70 Mbps.

```
flagged  if  size × 8 / duration  >  2 × (width × height × 1.784)
         or  width > 1920  or  height > 1080
```

The **2×** leaves room for ordinary encoder variation, so a clip merely
encoded a little richly is left alone. Phone 1080p/30 lands around 17 Mbps and
a GoPro 4K around 60 — both far past it.

The **resolution clause** exists because the pipeline downscales anything above
1080p anyway. A well-compressed 4K clip can slip under the bitrate bar while
still costing more to fetch than it can ever show.

Scale, not size: a correctly-encoded clip is never flagged for being long. At
3.70 Mbps a 1080p clip only reaches 400 MB at about 14 minutes, and a training
run is well under a minute — so the observed 400 MB file is over-encoded, not
long, and a plain size cap would have flagged the wrong things.

## Detection costs nothing

The Drive sweep already asks for `size`. Drive returns
`videoMediaMetadata(width,height,durationMillis)` in the same request for no
extra cost, and it is not currently requested. Adding it to both field masks —
`fileFields` and `changeFileFields` — supplies everything the rule needs.

`RemoteFile` gains `width`, `height` and `durationMillis` as **optionals**.

**Absent metadata means not flagged.** Drive populates `videoMediaMetadata`
asynchronously after an upload, so a clip added minutes ago may carry none.
Refusing to load something the app cannot measure would be worse than fetching
it: the failure would be silent, and it would strike hardest exactly when a
coach has just uploaded footage and wants to see it.

The rule itself is a pure value type — dimensions, duration and size in, a
verdict out. No network, no media, exhaustively testable.

## Refusing to fetch

The refusal applies to the **download**, not the listing. A flagged clip stays
in the sidebar with its size; selecting it shows the numbers and the repair
action rather than starting a 400 MB transfer.

**A clip already in the local cache still plays.** The download has been paid
for; refusing then would be obstruction with no benefit.

### Where it appears

Both screens refuse, because both fetch: the viewer when a clip is selected,
and the comparison window when a clip is loaded into either side. The
comparison case matters more than it looks — a coach loading two flagged clips
would otherwise start two large transfers at once.

The explanation and the repair action belong wherever the clip's own failure is
already reported, rather than in a new sheet: the viewer's status line and
`ClipPlayability`'s existing banner already carry "this clip cannot be played
here" for the undecodable-footage case, and this is the same shape of problem
with a different cause. Reuse that surface; do not invent a second one.

## Repairing it

Re-encoding reuses `AVFoundationMediaPipeline.resize` unchanged, so the output
matches what the sorting path already produces and the **framerate is
untouched** — motion is what a coach is judging.

The replace is `files.update` against the **same file id**. This is not an
implementation detail. Clip identity, the analysis sidecars, stored sync points
and the on-disk cache are all keyed on that id, so a delete-and-reupload would
silently orphan every correction the operator has made. `reencode_for_ios.py`
already replaces in place this way (`files().update(fileId, media_body=)`), so
the mechanism is proven in this project.

Replacing in place changes `headRevisionId`, which the app already carries as
`contentVersion`, so the clip cache invalidates itself with no extra work.

## Write access, asked for only when used

The app requests `drive.readonly`. Replacing a file needs write scope, and
broadening the scope outright would invalidate every stored refresh token and
sign out every club — including those that only ever watch — behind a consent
screen asking for write access to their whole Drive.

Instead the extra scope is requested **incrementally, the first time someone
actually repairs a clip**. Coaches who only watch never see it. The broader
refresh token then replaces the stored one.

### Scope is necessary but not sufficient

A coach with view-only permission on the club's Shared Drive gets a **403 from
`files.update` even with full `drive` scope granted**. This is the everyday case
for anyone who is not a club admin, not an edge case.

It must fail with "you do not have permission to change this file in Drive"
rather than a raw API error, and the flagged clip must remain listed and
explained rather than disappearing or appearing repaired.

## Testing

- The rule, as a pure value: flagged and unflagged at the boundary on both
  clauses, absent metadata, zero and non-finite durations.
- Detection through the provider's fake transport: a sweep reply carrying
  `videoMediaMetadata` produces the expected verdicts, and one lacking it
  flags nothing.
- Refusal: a flagged clip is not fetched; a flagged clip already in the cache
  is played.
- Repair: `files.update` is called with the original's file id — mutation-check
  by pointing it at a new file and confirming the test fails.
- The 403 path surfaces the permission message rather than a raw error.

## Out of scope

Repairing clips in bulk; touching local (non-Drive) libraries, which already go
through the resize step on ingest; and any change to the pipeline's target
bitrate, which is measured and not in question here.
