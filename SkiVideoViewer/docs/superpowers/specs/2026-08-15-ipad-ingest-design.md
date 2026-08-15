# iPad ingest — design

**Goal:** a coach at the hill, with no laptop, pulls the card out of the
camera, tags each run to an athlete, and the clips reach the club's Drive
before anyone has taken their boots off.

## The scenario, and what it forces

Filming happens at the side of a piste. The coach has an iPad, a card reader,
and a phone hotspot. There is no laptop and there will not be one until the
evening. Athletes want to see their runs the same day — that is the entire
point; feedback a week later is a different, much weaker product.

Four constraints fall out of that and shape everything below:

- **The network is the slow link.** A phone hotspot on a mountain is
  intermittent and metered. Uploads must resume rather than restart, and what
  goes up must be as small as it can usefully be.
- **Battery is finite** and there is no charger.
- **The card is the archive.** Nothing is copied to the iPad in full: an iPad
  Air's free space cannot be assumed to fit a card, and the originals are
  safest where they already are. The card is therefore **read-only** to this
  app.
- **Cold hands, between runs.** Anything requiring more than a tap or a typed
  name per clip will not be used twice.

## What already exists

More than expected, and the design is shaped to reuse it rather than build
beside it.

- **`SortingModel`** is already platform-agnostic — its own documentation says
  "so an iPadOS target can present the same model". It does folder selection,
  athlete-name search, playback, and a serialised resize queue.
- **`SortingSheet`** lives in `Shared/` and compiles for both platforms.
- **`AVFoundationMediaPipeline.resize`** uses `AVAssetReader`/`AVAssetWriter`
  with no platform guards, caps output at 1920×1080, never upscales, and
  already forces even dimensions — the exact failure that broke the Drive
  re-encode of a 1215×2160 phone clip.
- **`UIKitFolderPicker`** and **`SecurityScopedFolderAccess`** are how an SD
  card is reached: iPadOS surfaces a card reader as a Files location, and a
  document picker on `.folder` returns a security-scoped URL. No entitlement
  and no capability is involved.

Two things are missing, and they are the whole project:

1. `IOSSecondaryScreenPresenter.canPresentSorting` returns `false`, so the
   button is simply hidden on iPad.
2. Nothing uploads. The OAuth scope is `drive.readonly`.

## The one structural change

`SortingModel` ends a session by writing into `organized/<event>/<athlete>/`
and `organized_resize/…`, **both derived from the source folder**. Pointed at
an SD card that writes to the card, which this design forbids.

That end-stage becomes a seam — a `ClipPublisher` taking `(resized file,
athlete, event)` and placing it:

| Publisher | Behaviour |
| --- | --- |
| `LocalFolderPublisher` | Today's behaviour, extracted unchanged |
| `DrivePublisher` | Resize to app storage → find-or-create `<athlete>/<event>` → resumable upload → delete the temp |

**The destination is a per-session choice, not a platform difference.** Both
publishers exist on both platforms. A Mac can upload straight to Drive; an
iPad can output to a local folder. Splitting it by device would have been
easier and would have been wrong — the choice belongs to the situation
(is there network? is this a quick triage?), not to the hardware.

`DriveUploader` is a separate unit from `DrivePublisher` so that the
publish-an-existing-folder action reuses it rather than reimplementing it.

**Folder order is the library's, not this app's.** Local output is
`<event>/<athlete>/`; this club's Drive is `<athlete>/<event>/`. The existing
`FolderConvention` already models exactly this, and `DrivePublisher` takes it
from the target library rather than assuming either order.

## Session state

A session is (source folder, event, destination) plus, per clip, an athlete
and a stage: `tagged → resized → uploaded`.

**It is durable**, and that is not gold-plating: the failure modes here are a
flat battery, an ejected card, and a hotspot that comes and goes. A session
that cannot resume turns any of those into "do the whole thing again", which
means the coach does not start it in the first place. Durability is also what
makes "never upload the same clip twice" true across a relaunch rather than
only within one run.

## What happens when things fail

In roughly the order they will actually happen:

| Failure | Behaviour |
| --- | --- |
| Network drops mid-upload | Resumable upload continues from where it stopped; the queue retries with backoff |
| Card ejected mid-session | The security scope is lost. Say so plainly, keep the tagged state, resume when it is reinserted |
| Upload rejected by Drive | The temp resize is **kept**, the clip stays `resized`, and the reason is surfaced |
| Event folder already exists | Reused. Find-or-create must tolerate a concurrent creator — Drive permits duplicate names, and two coaches ingesting one event would otherwise produce two `2026-01-14_Brunni` folders and a library that shows the event twice |
| Same clip tagged twice | While `tagged`, the second tag replaces the first. Once `uploaded`, it is a move, not a re-upload |

**Nothing local is deleted until Drive confirms the file.** The card is the
only archive; a temp resize is the only other copy that exists.

## Two constraints iOS imposes

**Transcoding cannot continue in the background.** iOS suspends the app and
`AVAssetWriter` stops. This is not worked around — the honest behaviour is that
transcoding happens while the coach is in the app tagging, which is exactly
when they are.

**Uploads can continue**, through a background `URLSession`. That needs no
capability, which is worth stating because the obvious guess is Background
Modes, and adding an entitlement the App ID is not configured for fails the
*install* rather than the build.

## The scope change, and why it is the risk

"Straight into the library" forces the full `drive` scope.

`drive.file` is the tempting alternative — it is not a restricted scope and
needs no verification — but it grants access only to files the app itself
created. It could upload, and then could neither see nor write into the
athlete folders that already exist. Placing a clip inside a folder the app did
not create requires write access to that folder.

Full `drive` is restricted, the same tier as the `drive.readonly` already in
use, so for Internal club-supplied clients it changes nothing about
verification or CASA. What it does change: **every existing sign-in must
re-consent**, on every device and at every club. That is unavoidable, and it
is the reason for the split below.

## Two plans

**Plan 1 — Sort on iPad, from a card.** The `ClipPublisher` seam,
`LocalFolderPublisher` extracted, `canPresentSorting` turned on, outputs
redirected to app storage instead of beside the source. No Drive changes, no
scope change, nobody re-consents. Delivers tagging-at-the-hill on its own.

**Plan 2 — Drive as a destination.** `DriveUploader`, `DrivePublisher`, the
scope change, the durable queue, and the publish-an-existing-folder action.

Plan 1 first, and live with it for a few sessions before spending the
re-consent.

## Testing

- `DriveUploader` against the existing `FakeHTTPTransport`: find-or-create with
  the target folder missing, present, partially present (athlete exists, event
  does not), and duplicated.
- `LocalFolderPublisher` pinned against today's exact output — same paths, same
  filenames — so the Mac cannot regress while being refactored underneath it.
  This is the highest-value test in the project: it is the one guarding
  working behaviour, and every other test here guards behaviour that does not
  exist yet.
- Queue durability: enqueue, kill the process, relaunch, confirm it resumes and
  that an already-uploaded clip is not sent again.
- A session whose source is read-only writes nothing to the source.
- `FolderConvention` honoured in both orders, asserting both path components,
  so a swap that fixes one and breaks the other still fails.

Each test names the change that would make it fail, and the load-bearing ones
are confirmed against a deliberately broken implementation before being
trusted — the practice that has already caught an always-green plist assertion
and an `isDecodable` check that could never fire.

## Not in scope

Uploading originals. Background transcoding. Bib recognition. Any change to
how the library is browsed. Automatic publishing when a connection appears —
the manual action is the honest version until there is evidence anyone wants
the app deciding what "good connection" means.
