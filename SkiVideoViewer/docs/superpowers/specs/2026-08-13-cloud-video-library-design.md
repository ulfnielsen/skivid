# Browsing the club's video library from cloud storage

Date: 2026-08-13

The club keeps its footage centrally in Google Workspace. A coach should be able
to sign in, see the whole library, and review any clip — with the same frame
stepping, comparison and analysis the local library gets — without holding 74 GB
on a laptop.

The app already has a Google Drive integration. It does not do this, and cannot
be made to: it streams clips straight from Drive's media endpoint, and the
app's analysis and scrubbing are built on APIs that cannot read a remote URL at
all. This replaces streaming with **downloading into a managed cache**, so a
cloud clip becomes an ordinary local file before anything touches it.

## Why the current design cannot be repaired

Four findings, each verified rather than reasoned about.

**Analysis is impossible over a remote URL, not merely slow.** `ClipFrameReader`
(`Sources/SkiVideoCore/ClipFrameReader.swift:65`) and `AVFoundationMediaPipeline`
(`:66`) both build an `AVAssetReader`, and Apple documents that `AVAssetReader`
cannot read from a remote streaming source. Every feature built on frame
extraction — pose detection, alignment tracks, segment thumbnails, the resize
pipeline — is therefore unavailable on a streamed clip, not degraded.

**Frame stepping over a remote file is a network round trip per step.** Apple
documents that seeking with both tolerances at zero "may incur additional
decoding delay"; over a remote progressive MP4 that delay is an HTTP range
request plus a decode from the preceding sync sample. Frame step and reverse
slow motion are exactly that access pattern.

**The playback URL's token expires mid-session and cannot be replaced.**
`DriveMedia.streamingURL` (`Sources/SkiVideoCore/GoogleDriveSupport.swift:14-24`)
embeds the access token as a query parameter. Google access tokens last about an
hour, `AVPlayer` re-requests ranges for the whole life of an `AVPlayerItem`
including on every seek, and there is no supported way to swap the URL under a
live item.

**That URL is already failing — measured, not predicted.** Google's
system-parameters table no longer lists `access_token` at all, and on the
`alt=media` path a query-string token is not accepted as a credential.

Measured 2026-08-13 against the real library, using a valid refreshed token and
one real file (`C0197.MP4`, 7.0 MB). Everything held constant except where the
token sits — same file id, same `Range: bytes=0-63`:

| | Token in `Authorization` header | Token in query string |
| --- | --- | --- |
| Status | **206** Partial Content | **403** |
| Content-Type | `video/mp4` | `text/html` |
| Body | MP4 bytes, `\x00\x00\x00\x14ftypqt` | `<title>Sorry...</title>` anti-abuse page |

The metadata path still honours the query parameter — `files.list` returned 200
in the same run — which is exactly the observed symptom: the sidebar populates
and playback does not. So this work is a **replacement, not a repair**: no part
of `DriveMedia` needs preserving.

Two further things fell out of the same measurement, both previously
unverified. `alt=media` does honour `Range`, returning a genuine **206**. And
both `headRevisionId` and `md5Checksum` are present on real video records, so
the cache-validity key and the integrity check described below are actually
available rather than assumed.

> Scope note: the measurement used a `drive.file`-scoped token, the one
> `upload_to_drive.py` already holds. Scope governs *which* files a token can
> reach, not where the credential may be presented, so the A/B is unaffected —
> but the production app will use `drive.readonly`, and no one should read this
> table as evidence about scopes.

## The decision: download, don't stream

Measured against the actual library rather than assumed:

| | |
| --- | --- |
| Library | 1,034 videos, 74.3 GB |
| Clip size | p50 32 MB, p90 180 MB, max 814 MB |
| Resized copies | p50 14 MB, p90 45 MB |
| Duration | 13–61 s (sampled with `ffprobe`) |
| Largest event folder | 9.1 GB; typical event 3–6 GB |

These are short clips. A p50 clip on 100 Mbit lands in about 2.5 seconds, a
resized one in about one. Streaming buys roughly two seconds and costs every
scrub-heavy and analysis feature in the app.

So: **`URLSession` fetches whole clips with an `Authorization` header; `AVPlayer`
only ever opens a `file://` URL.** Everything downstream — comparison, overlay,
zoom, frame step, pose, alignment — works unchanged, because a cached clip is
indistinguishable from a local one.

Two consequences worth stating plainly. There is no
`AVAssetResourceLoaderDelegate` in this design, and no partial-file playback, so
no cache-completeness gating is needed on any control: a clip is complete or it
is not playing. And `AVAssetDownloadTask` is not used — it is documented as
HLS-only and returns nil for progressive assets.

## Discovery: how new videos appear

Three moments, one index.

**Cold start, once per Shared Drive.** Not a recursive walk. An entire shared
drive lists in one paged query:

```
files.list?corpora=drive&driveId=<id>&pageSize=1000
         &includeItemsFromAllDrives=true&supportsAllDrives=true
         &q=trashed=false
         &fields=nextPageToken,files(id,name,mimeType,size,md5Checksum,
                                      headRevisionId,parents,driveId)
```

1,034 clips is **two round trips**. The folder tree is rebuilt client-side from
each file's `parents` array. Today's scanner issues one request per folder
(`GoogleDriveSupport.swift:208`).

**Every launch, the change feed.** Call `changes.getStartPageToken(driveId)` once
at index time and persist it; on each launch drain `changes.list(pageToken,
driveId)` until it returns `newStartPageToken`. Two properties make this cheap:
page tokens **never expire**, so an app closed for months still resyncs in a
bounded number of calls; and the change log is **coalesced per file**, so a clip
edited 500 times while the app was closed is one entry. The handler upserts by
file id, which makes it naturally idempotent.

**While open.** The same call on a timer and on window focus, plus a manual
Refresh. Drive's push notifications need a public webhook endpoint, so they are
out of scope for a client-only app.

A coach uploads with `upload_to_drive.py`; everyone else sees the clips on next
refresh, usually in one request returning a handful of rows.

### The traps, all of which fail silently

| Trap | Consequence |
| --- | --- |
| `supportsAllDrives=true` omitted on any call | Shared-drive items silently excluded, spurious 404s. Set it centrally in the HTTP client, never per call site. |
| `corpora=allDrives` | Can drop files without erroring, signalled only by `incompleteSearch:true`. Enumerate with `drives.list`, then one `corpora=drive` sweep per drive, and assert `incompleteSearch != true` on every page. |
| `pageSize` left default | Defaults to **100** for shared drives — 11 requests instead of 2. |
| Tracking the *user* change log | Files moved into a shared drive stop appearing in it. Track the *drive* log via `driveId`, with `includeRemoved=true` and `includeCorpusRemovals=true`. |
| Treating `deleted` as deletion | It also means "this user lost access" or "moved corpora". **Never evict cached bytes on it** — mark unavailable and let a periodic full sweep reconcile. |
| Keying the cache on `version` or `modifiedTime` | `version` increments on metadata-only changes and `modifiedTime` is client-settable, so a rename would trigger a 180 MB re-download. |

**Cache validity is `headRevisionId`**, which by definition changes only when
content changes. `md5Checksum` is a post-download integrity check, not the key.
File ids are permanently stable across renames and moves, so they are the
primary key for both the index and the cache.

There is no recursive subtree operator in Drive — the `parents` term tests
direct parenthood only. If a coach picks a subfolder rather than a whole drive,
the efficient move is still one whole-drive sweep filtered in memory against the
parents graph.

Sizing, for the record: Drive's egress cap is 1 TB/day/project. The entire
74 GB library is 7% of one day. Request counts are nowhere near binding —
indexing costs about 300 quota units against 325,000 per minute per user.

### What this fixes on the way past

`GoogleDriveSupport.swift:126-133` documents a defect: because the folder
hierarchy is absent from the synthesised `drivevideo://` URL, Drive clips sort by
file name alone and sibling folders interleave instead of staying in blocks.
Reconstructing the tree from `parents` restores real folder ordering, and the
athlete/event rule reads parent links rather than inferring them from a
flattened URL.

## The cache

`ClipCache`, an actor in `SkiVideoCore`, owning two directories:

- **`Caches/CloudClips/<provider>/<fileID>.<ext>`** — ordinary cached clips.
  Deliberately in `Caches` so the OS may purge under storage pressure, which is
  correct for a cache and matters on iPad.
- **`Application Support/PinnedClips/…`** — pinned clips, with
  `isExcludedFromBackupKey = true`, so tens of gigabytes of footage never enter
  an iCloud backup.

Downloads run on a background `URLSession` so an iPad download survives app
suspension, carry `Authorization: Bearer` read fresh per request, and move into
place atomically. Where Drive supplies an `md5Checksum` the written bytes are
verified against it; where it does not, size is the only available check and a
mismatch is treated the same way — discard and retry once.  Two requests for the
same clip coalesce onto one task.

Eviction is **LRU by last-played against a size budget** — default 20 GB on
macOS, 5 GB on iPadOS — running after each completed download, never touching a
pinned or in-flight entry.

```swift
public actor ClipCache {
    /// Non-blocking. Nil when the clip is not on disk, so a caller can decide
    /// between showing progress and playing immediately.
    public func cachedURL(for identity: ClipIdentity) -> URL?

    /// Downloads if absent. Takes the whole record, not just the identity,
    /// because it needs `size` for progress and `headRevisionId` to decide
    /// whether an existing file is still valid.
    public func materialize(_ file: RemoteFile) async throws -> URL

    public func prefetch(_ files: [RemoteFile])
    public func pin(_ file: RemoteFile) async throws
    public func unpin(_ identity: ClipIdentity)
    public func setBudget(_ bytes: Int64)
    public func evictToFit() async
}
```

Lookups key on `ClipIdentity`; anything that may fetch takes the full
`RemoteFile`. That asymmetry is deliberate — a caller holding only an identity
can ask whether a clip is present, but cannot silently start a download.

**Prefetch policy.** On selection change, enqueue the next two and the previous
one in the athlete's clip list; when a comparison pane opens, enqueue its
partner. Cancel on selection move, concurrency capped at two so speculative work
cannot starve the clip someone is waiting for.

**Per-file download failures are per-file.** A clip Drive has flagged as abusive
fails unless `acknowledgeAbuse=true`, and there is an undocumented per-file
24-hour download cap. Neither may fail a batch: mark the clip temporarily
unavailable, back off, and carry on. Retry logic branches on
`error.errors[0].reason`, not on the HTTP status — 403 is overloaded and also
carries permission errors that must not be retried.

## Sign-in

The client-secret file picker and the pasted folder ID both go
(`GoogleDriveSheet.swift:16-33`). They are replaced by **Sign in with Google** →
`drives.list` → pick a Shared Drive from a list. `drives.list` is paged at 100;
its default of 10 would silently truncate the picker.

The audience is **Internal** — members of the club's Workspace only. This is the
decisive compliance fact: `drive.readonly` is a *restricted* scope, but an app
whose OAuth audience is Internal is exempt from Google verification, from the
annual CASA security assessment, from the 100-test-user cap, and from the 7-day
refresh-token expiry. The exemption requires the Cloud project to sit in the
organisation.

Two platform paths, which the `OAuthPresenter` seam already anticipates
(`Sources/SkiVideoCore/Seams.swift`, OAuth section):

| | macOS | iPadOS |
| --- | --- | --- |
| OAuth client type | Desktop | iOS |
| Redirect | loopback `http://127.0.0.1:<port>` | reverse-DNS custom scheme |
| Presenter | `AppKitOAuthPresenter` (exists) | replaces `UnavailableOAuthPresenter` |
| Client secret | yes | **none — iOS clients have none** |

Loopback redirects have been **blocked for iOS clients since 21 October 2022**,
so the iPad cannot reuse the Mac's flow. The out-of-band paste-the-code flow is
dead for every client type since 31 January 2023. Google blocks authorization
requests from embedded webviews with `disallowed_useragent`, naming WKWebView
explicitly, so the iPad path uses `ASWebAuthenticationSession`.

Because iOS clients have no secret, the token exchange takes `client_secret` as
optional rather than reading it out of a JSON file
(`GoogleDriveSupport.swift:292-314, 399-401`). PKCE with S256 is unconditional on
both platforms — with a public client it is the only binding between the
authorization request and the token exchange. Keychain continues to hold the
refresh token.

Two failures earn their own messages, because neither is retryable and both are
otherwise baffling:

- **`org_internal`** — "This Google account is not in the club's Workspace."
- **`admin_policy_enforced`** — "A Workspace administrator has to allow this app
  under Admin console → API controls."

## Analysis sidecars

`ClipAnalysisStore.sidecarURL` (`:12`) appends `.skianalysis.json` beside the
clip and reads it with `Data(contentsOf:)`. On a `drivevideo://` URL that can
never work, so analysis and alignment silently no-op on Drive clips today.

Introduce `ClipIdentity`:

```swift
public enum ClipIdentity: Hashable, Sendable {
    case local(URL)
    case remote(provider: String, fileID: String)
}
```

Local clips keep writing sidecars beside the footage — that portability is a
deliberate design choice `ClipAnalysisStore` documents, and it stays. Cloud clips
get an identity-keyed store under Application Support. `AlignmentTrackStore`
takes the same treatment for its clip *pairs*, with one rule worth stating
because comparison can straddle the two: a pair sits beside the left clip only
when **both** sides are local; any pair with a remote side goes to the
identity-keyed store.

> This does **not** make analysis survive a local clip being renamed or moved.
> A sidecar beside the footage is orphaned by a rename whatever the store is
> keyed on, and surviving that would need content-hash or inode keying — a
> different feature, not in scope. An earlier draft of this spec claimed
> otherwise in its delivery order; the claim was wrong.

**Not in this work:** writing sidecars back to Drive so coaches share each
other's analysis. It needs a write scope, conflict handling, and turns the app
read-write. The identity-keyed store is the seam it would attach to later.

## Module split

`GoogleDriveSupport.swift` is 510 lines doing five jobs — OAuth, Keychain, HTTP,
listing, grouping. This work changes four of them, so it splits:

| New file | Responsibility |
| --- | --- |
| `RemoteLibraryProvider.swift` | Protocol plus `RemoteFile`, `RemoteFolder`, `DownloadSource` |
| `GoogleOAuth.swift` | Authorization, token refresh, Keychain |
| `GoogleDriveProvider.swift` | Drive HTTP, listing, changes feed |
| `RemoteLibraryIndex.swift` | Persisted index, tree reconstruction, cursor |
| `ClipCache.swift` | Download, pinning, eviction |
| `ClipIdentity.swift` | Identity plus the reworked stores |

```swift
public protocol RemoteLibraryProvider: Sendable {
    static var identifier: String { get }        // "gdrive"

    func connect(presenter: OAuthPresenter) async throws

    /// Top-level containers the account can see — each Shared Drive, and
    /// My Drive. One element is a fine answer.
    func roots() async throws -> [RemoteFolder]

    /// Every descendant file, streamed so a large library shows results
    /// before the sweep finishes.
    func enumerate(_ folder: RemoteFolder) -> AsyncThrowingStream<RemoteFile, Error>

    /// Where to fetch the bytes. Minted per download, never stored in the
    /// index — credentials in it are short-lived.
    func downloadSource(for file: RemoteFile) async throws -> DownloadSource
}

public struct RemoteFile: Hashable, Sendable {
    public let id: String
    public let name: String
    /// Folder names from the enumerated root down to the parent. The grouping
    /// rule reads the last two; nothing may parse `id`.
    public let path: [String]
    public let size: Int64
    /// Opaque; equal means the bytes are unchanged. Drive's `headRevisionId`.
    /// Nil means never reuse a cached file.
    public let contentVersion: String?
    /// For post-download integrity checking only. Absent for some files.
    public let md5: String?
}

public struct DownloadSource: Sendable {
    public let url: URL
    public let headers: [String: String]
}
```

`DownloadSource` is a URL plus headers because that is all this design needs —
`URLSession` fetches whole files and `AVPlayer` never sees a remote URL. An
earlier draft had a `PlaybackSource` enum distinguishing pre-signed URLs from
header-authorized ones, which only matters if `AVPlayer` fetches the bytes
itself. It does not, so the distinction was removed.

`path: [String]` rather than a synthesised URL is what keeps the athlete/event
rule provider-independent, and is what fixes the ordering defect described
above.

The protocol stays small on purpose. Deliberately absent: writes, thumbnails,
quota, search, and delta. A usable change feed exists for only some providers,
so if a second provider is ever added, delta belongs in a separate optional
protocol rather than as a stub in three implementations.

`ViewerModel` keeps its existing shape. `driveMediaByURL`
(`ViewerModel.swift:58`) becomes a cache lookup, and `currentPlaybackURL` (`:177`)
resolves to a local file. That indirection already exists and is already right —
it is only pointing at the wrong thing.

## Testing

`CorePurityTests` forbids AppKit, UIKit, SwiftUI and `Process` in `SkiVideoCore`;
Foundation, URLSession and AVFoundation are permitted, so the cache and provider
live in core without a fight.

- **Provider protocol** — a fake provider makes every index and library test run
  with no network.
- **`ClipCache`**, with an injected downloader seam: eviction order, pinned
  entries surviving eviction, checksum mismatch forcing re-download, coalescing
  of concurrent requests for one clip, budget changes triggering eviction.
- **Index** — tree reconstruction from flat `parents` arrays, including the
  loose-file-at-root case `scanSharedDrive` documents at `:78-95` and the
  athlete/event rule; a `deleted` change marking unavailable **without** evicting
  bytes; upsert idempotency.
- **Sign-in** — `AppKitOAuthPresenterTests` already covers the loopback listener.
  The iPad presenter hands off to a system browser and cannot be tested end to
  end; its redirect-URI construction can be.

## Delivery order

One spec, but not one landing. The pieces interlock — a browsable library that
cannot play is not worth shipping — so the plan stages them behind the existing
Drive entry point and switches over once:

1. ~~**Measure** whether the current playback URL works.~~ **Done 2026-08-13** —
   it does not; see the table above. `GoogleDriveSupport`'s media path is
   replaced outright rather than refactored.
2. **`ClipIdentity` and the stores.** Independent of everything cloud and
   testable on its own: it gives cloud clips somewhere to keep analysis, and
   leaves local behaviour byte-for-byte as it is.
3. **Provider protocol, `GoogleOAuth` split, `GoogleDriveProvider`.** The
   existing sheet keeps working against the new provider.
4. **`RemoteLibraryIndex`** — sweep, tree reconstruction, changes cursor.
5. **`ClipCache`** — download, eviction, pinning. First point at which a cloud
   clip plays with full frame stepping.
6. **Prefetch**, then the sign-in and drive-picker UI replacing the
   client-secret and folder-ID fields.
7. **iPad presenter** and the iOS OAuth client.

Steps 2 and 3 are independent of each other. Step 7 is the only one that needs a
second OAuth client registration, so it can lag without blocking macOS.

## Risks and open questions

1. ~~Whether Drive playback is broken today.~~ **Resolved 2026-08-13: it is.**
   Query-string tokens are refused on `alt=media` with a 403 HTML interstitial
   while the header form returns 206 and real bytes. No longer a risk, and the
   reason the media path is replaced rather than repaired.
2. **The Internal audience is a hard wall.** A parent or guest coach on personal
   Gmail receives an `org_internal` error, not a request-access prompt. If
   external viewers are ever needed the architecture changes completely — the
   alternatives are Google Picker with `drive.file` (per-file consent, no
   browsing) or a backend fronting the content.
3. **A Workspace admin may need to allow the app** under API controls before
   anyone can sign in. Worth confirming before the first coach tries it.
4. **`files.list` page tokens are valid only "several hours"** and results can
   shift mid-pagination, so a full sweep is approximate. This is precisely why
   the sweep is followed by a `changes.list` cursor.
5. **Cold-start bandwidth on a hill.** Indexing is metadata-only and cheap, but
   the first clip a coach opens on LTE is a real download. Prefetch helps only
   after the first.
