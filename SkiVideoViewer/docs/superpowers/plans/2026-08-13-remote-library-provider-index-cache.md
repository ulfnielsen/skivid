# Remote Library: Provider, Index and Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A coach signs in, sees the whole Shared Drive listed, opens any clip, and reviews it with every feature the local library gets — because the clip is downloaded to a managed cache and handed to `AVPlayer` as an ordinary file.

**Architecture:** Three units behind one protocol. `RemoteLibraryProvider` says what any cloud source must offer — roots, an enumeration, and where to fetch bytes. `GoogleDriveProvider` implements it against Drive with one flat paged sweep instead of a folder-by-folder walk. `RemoteLibraryIndex` turns that flat list into the sidebar's groups by reconstructing the folder tree from each file's `parents`, and persists itself with a `changes.list` cursor so relaunch is a delta, not a re-sweep. `ClipCache` is an actor that materialises a clip to disk and evicts by LRU against a size budget. `ViewerModel` changes at one seam: the map from a library URL to a playable URL now goes through the cache instead of through a tokenised HTTPS URL.

**Tech Stack:** Swift 6.1 toolchain, SwiftPM, XCTest, Foundation, CryptoKit. No new dependencies.

This is plan 2 of 3 from `docs/superpowers/specs/2026-08-13-cloud-video-library-design.md`, covering its delivery-order steps 3–5. Plan 1 (`2026-08-13-clip-identity-and-stores.md`) is complete and provides `ClipIdentity`. Plan 3 covers the sign-in UI, the Shared Drive picker, prefetch, and the iPad OAuth path.

## Global Constraints

- **The test command is NOT plain `swift test`.** `xcode-select -p` points at `/Library/Developer/CommandLineTools`, which ships no XCTest, so bare `swift test` fails with `error: no such module 'XCTest'` before running anything. Every command here is prefixed:
  `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test …`
- **Zero *new* compiler warnings.** The repo carries **10 pre-existing warnings** in `SortingModelResizeQueueTests.swift`, `AVFoundationMediaPipelineTests.swift`, `ClipFrameReader.swift` and `ComparisonModel.swift`. Do not fix them — they are outside this work. Check your own files only, and force recompilation, because an incremental build reports 0 falsely:
  `touch <the files you changed> && env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --build-tests 2>&1 | grep "warning:" | grep -E "<your files>"` — must be empty.
- **`Sources/SkiVideoCore` may not contain `import AppKit`, `import UIKit`, `import SwiftUI`, or `Process(`.** Enforced by `CorePurityTests`. Foundation, CryptoKit and AVFoundation are permitted.
- **No test may reach the network.** Every provider test goes through the `HTTPTransport` seam (Task 4) or the fake provider (Task 1). A test that would hit `googleapis.com` is a defect.
- **No test may write to the real Application Support or Caches directory.** Both roots are injectable; point them at a temporary directory and remove it in `defer`.
- **Run commands from `/Users/ulfnielsen/Ski/script/SkiVideoViewer`.** The git root is one level up at `/Users/ulfnielsen/Ski/script`, so `git add` paths are as written in each commit step.
- Swift language mode is v5 (`Package.swift`), so a mutable `static var` is not a concurrency error.
- Platforms: macOS 13, iOS 17.
- **Do not edit a pre-existing test to make your change pass.** If one fails, the implementation is wrong.

## Decisions already made, with their evidence

**Download, never stream.** `AVAssetReader` cannot read from a remote source at all, and `ClipFrameReader.swift:65` and `AVFoundationMediaPipeline.swift:66` both use it — so pose detection, alignment, thumbnails and the resize pipeline are *impossible* on a streamed clip, not merely slow. Measured 2026-08-13: the library is 1,034 clips of 13–61 s, p50 32 MB, so a p50 clip lands in about 2.5 s on 100 Mbit. There is no `AVAssetResourceLoaderDelegate` in this design and no partial-file playback.

**The token goes in a header, never a URL.** Measured 2026-08-13 against the real library, same file and same `Range`, varying only where the token sits: `Authorization: Bearer` returns **206** with MP4 bytes; `?access_token=` returns **403** with Google's HTML anti-abuse page. `files.list` still honours the query form, which is why the sidebar populates today and playback does not.

**The library URL carries the folder path.** Verified with a Swift probe: a base64url file id survives as a URL host (`drivevideo://1A_bC-dEf/…` parses, `_` and `-` both fine), and folder names round-trip through percent-encoding — `URLComponents` with `path = "/Neuss 2026/Ada Lovelace/run 3.mp4"` yields `.path` back verbatim and `lastPathComponent` still the file name.

This matters because `LibraryGrouping.pathOrder` (`LibraryGrouping.swift:135`) sorts on `video.path`, and today's synthesised URL is `drivevideo://<id>/<name>` — no hierarchy — which is why `GoogleDriveSupport.swift:126-133` documents Drive clips sorting by file name alone and sibling folders interleaving. Putting the folder path in the URL path fixes that defect as a side effect of this work.

> **The one case this does not handle:** a Drive folder name containing `/`. Drive permits it; `LibraryGrouping.id` (`:120`) already says so. Such a name creates extra URL path components, so the clip *sorts* as if nested one level deeper. Grouping is unaffected — athlete and event come from the `RemoteFile`'s own fields, not from parsing the URL. Accepted, and recorded here so nobody reads the URL path as authoritative structure.

## File Structure

| File | Responsibility |
| --- | --- |
| Create `Sources/SkiVideoCore/RemoteLibraryProvider.swift` | The protocol plus `RemoteFile`, `RemoteFolder`, `DownloadSource`, `RemoteLibraryError` |
| Create `Sources/SkiVideoCore/HTTPTransport.swift` | One-method seam over `URLSession`, so provider tests never touch the network |
| Create `Sources/SkiVideoCore/GoogleOAuth.swift` | Authorization, refresh, Keychain — moved out of `GoogleDriveSupport.swift` unchanged |
| Create `Sources/SkiVideoCore/GoogleDriveProvider.swift` | `drives.list`, the flat sweep, `changes.list`, download source |
| Create `Sources/SkiVideoCore/RemoteLibraryIndex.swift` | Tree reconstruction, library URLs, grouping, persistence, cursor |
| Create `Sources/SkiVideoCore/ClipCache.swift` | Materialise, verify, pin, evict |
| Modify `Sources/SkiVideoCore/ViewerModel.swift` | Replace `driveMediaByURL` with index + cache |
| Delete from `Sources/SkiVideoCore/GoogleDriveSupport.swift` | `DriveMedia`, `DriveLibrary`, `GoogleDriveClient` — the file ends up holding nothing and is removed |
| Create `Tests/SkiVideoCoreTests/FakeRemoteProvider.swift` | Shared fake, no network |
| Create `Tests/SkiVideoCoreTests/FakeHTTPTransport.swift` | Canned responses for provider tests |
| Create tests | `RemoteLibraryIndexTests`, `GoogleDriveProviderTests`, `ClipCacheTests`, `RemoteLibraryWiringTests` |

---

### Task 1: The provider protocol and its value types

**Files:**
- Create: `Sources/SkiVideoCore/RemoteLibraryProvider.swift`
- Create: `Tests/SkiVideoCoreTests/FakeRemoteProvider.swift`
- Test: `Tests/SkiVideoCoreTests/RemoteLibraryProviderTests.swift`

**Interfaces:**
- Consumes: `ClipIdentity` (plan 1), `OAuthPresenter` (`Seams.swift`).
- Produces: `RemoteLibraryProvider`, `RemoteFolder`, `RemoteFile`, `DownloadSource`, `RemoteLibraryError`, `RemoteFile.identity(inProvider:)`. Tasks 3–7 all build on these exact names.

- [ ] **Step 1: Write the failing test**

Create `Tests/SkiVideoCoreTests/RemoteLibraryProviderTests.swift`:

```swift
import XCTest
@testable import SkiVideoCore

final class RemoteLibraryProviderTests: XCTestCase {
    func testAFileBecomesTheIdentityItsAnalysisIsKeyedOn() {
        let file = RemoteFile(
            id: "1AbC", name: "run.mp4", path: ["Neuss 2026", "Ada"],
            size: 32_000_000, contentVersion: "rev1", md5: nil
        )
        XCTAssertEqual(
            file.identity(inProvider: "gdrive"),
            .remote(provider: "gdrive", fileID: "1AbC")
        )
    }

    /// Identity is the file id alone. A clip renamed or moved in Drive keeps
    /// its analysis, because neither its name nor its folder is part of it.
    func testRenamingOrMovingAFileDoesNotChangeItsIdentity() {
        let before = RemoteFile(
            id: "1AbC", name: "run.mp4", path: ["Neuss 2026", "Ada"],
            size: 32_000_000, contentVersion: "rev1", md5: nil
        )
        let after = RemoteFile(
            id: "1AbC", name: "run-final.mp4", path: ["Neuss 2026", "Bea"],
            size: 32_000_000, contentVersion: "rev1", md5: nil
        )
        XCTAssertEqual(before.identity(inProvider: "gdrive"), after.identity(inProvider: "gdrive"))
    }

    func testAFakeProviderStreamsTheFilesItWasGiven() async throws {
        let provider = FakeRemoteProvider(files: [
            RemoteFile(id: "a", name: "1.mp4", path: ["E", "A"], size: 1, contentVersion: nil, md5: nil),
            RemoteFile(id: "b", name: "2.mp4", path: ["E", "A"], size: 2, contentVersion: nil, md5: nil),
        ])

        var seen: [String] = []
        for try await file in provider.enumerate(RemoteFolder(id: "root", name: "Drive")) {
            seen.append(file.id)
        }

        XCTAssertEqual(seen, ["a", "b"])
    }

    /// The stream must surface a mid-enumeration failure rather than ending
    /// quietly — a sweep that stops early would silently hide half a library.
    ///
    /// Two files and `errorAfter = 1`, so the failure lands *part-way through*.
    /// One file would prove only that a stream can throw, which is not the
    /// behaviour at risk: the dangerous case is a sweep that yields some clips
    /// and then dies, because a caller that swallowed it would show a partial
    /// library as if it were whole. Asserting what was yielded first is what
    /// makes this a mid-stream test rather than a "does it throw" test.
    func testAFailingEnumerationThrowsAfterYieldingWhatItCould() async {
        let provider = FakeRemoteProvider(files: [
            RemoteFile(id: "a", name: "1.mp4", path: ["E", "A"], size: 1, contentVersion: nil, md5: nil),
            RemoteFile(id: "b", name: "2.mp4", path: ["E", "A"], size: 2, contentVersion: nil, md5: nil),
        ])
        provider.errorAfter = 1

        var seen: [String] = []
        do {
            for try await file in provider.enumerate(RemoteFolder(id: "root", name: "Drive")) {
                seen.append(file.id)
            }
            XCTFail("expected the enumeration to throw")
        } catch {
            XCTAssertTrue(error is RemoteLibraryError)
        }
        XCTAssertEqual(seen, ["a"], "the failure must come after what could be yielded, not instead of it")
    }
}
```

Create `Tests/SkiVideoCoreTests/FakeRemoteProvider.swift`:

```swift
import Foundation
@testable import SkiVideoCore

/// Stands in for a cloud source with no network of any kind. Every test that
/// needs a library of files uses this rather than `GoogleDriveProvider`.
final class FakeRemoteProvider: RemoteLibraryProvider, @unchecked Sendable {
    static let identifier = "fake"

    var files: [RemoteFile]
    /// Not named `roots` — a stored property cannot share its name with the
    /// protocol method that returns it.
    var rootsToReturn: [RemoteFolder] = [RemoteFolder(id: "root", name: "Test Drive")]
    /// Throws after this many files have been yielded. Nil never throws.
    var errorAfter: Int?
    var downloadURL = URL(string: "https://example.invalid/bytes")!
    var headers: [String: String] = ["Authorization": "Bearer test"]
    private(set) var connectCallCount = 0
    private(set) var downloadSourceCallCount = 0

    init(files: [RemoteFile] = []) {
        self.files = files
    }

    func connect(presenter: OAuthPresenter) async throws {
        connectCallCount += 1
    }

    func roots() async throws -> [RemoteFolder] { rootsToReturn }

    func enumerate(_ folder: RemoteFolder) -> AsyncThrowingStream<RemoteFile, Error> {
        AsyncThrowingStream { continuation in
            for (offset, file) in files.enumerated() {
                if let errorAfter, offset >= errorAfter {
                    continuation.finish(throwing: RemoteLibraryError.api("fake enumeration failure"))
                    return
                }
                continuation.yield(file)
            }
            continuation.finish()
        }
    }

    func downloadSource(for file: RemoteFile) async throws -> DownloadSource {
        downloadSourceCallCount += 1
        return DownloadSource(url: downloadURL, headers: headers)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter RemoteLibraryProviderTests
```
Expected: FAIL to compile — `cannot find 'RemoteFile' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SkiVideoCore/RemoteLibraryProvider.swift`:

```swift
import CryptoKit
import Foundation

/// A filesystem-safe, length-bounded name for an arbitrary identifier.
///
/// Names the files this module writes: one index per Shared Drive, one cached
/// clip per file id. A digest rather than an escaped copy, because an
/// identifier is not a filename — escaping is lossy, so two distinct ids can
/// fold to one name and silently overwrite each other, and an escaped
/// identifier is unbounded where a filename component is capped at 255 bytes.
///
/// Deliberately *not* `ClipIdentity.pairKey`. That answers "what is this
/// clip's analysis filed under" and is half of a stored format; borrowing it
/// to name an unrelated file would tie two things that must stay free to
/// change apart.
enum StorageName {
    static func forIdentifier(_ identifier: String) -> String {
        SHA256.hash(data: Data(identifier.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// A cloud source of clips: what the app needs from Drive, and what it would
/// need from anything else.
///
/// Four methods, because four are what a library that only *reads* requires.
/// Deliberately absent: writes, thumbnails, quota, search, and a change feed.
/// A usable change feed exists for only some providers, so when a second one
/// arrives, delta belongs in its own optional protocol rather than as a stub
/// three implementations have to carry.
public protocol RemoteLibraryProvider: Sendable {
    /// Namespaces this provider's file ids. Becomes the scheme of a library
    /// URL and half of a `ClipIdentity`, so it must not change once anything
    /// has been indexed or cached.
    static var identifier: String { get }

    /// Interactive sign-in. Implementations persist their own refresh token.
    func connect(presenter: OAuthPresenter) async throws

    /// The top-level containers this account can see — each Shared Drive, and
    /// My Drive. One element is a fine answer.
    func roots() async throws -> [RemoteFolder]

    /// Every descendant *file* of `folder`, streamed so a large library can
    /// show results before the sweep finishes. A failure part-way through
    /// finishes the stream by throwing — never silently, which would show a
    /// half library as if it were whole.
    func enumerate(_ folder: RemoteFolder) -> AsyncThrowingStream<RemoteFile, Error>

    /// Where to fetch this file's bytes. Minted per download and never stored
    /// in the index: any credential in it is short-lived.
    func downloadSource(for file: RemoteFile) async throws -> DownloadSource
}

public struct RemoteFolder: Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct RemoteFile: Hashable, Sendable {
    public let id: String
    public let name: String
    /// Folder names from the enumerated root down to this file's parent.
    /// The grouping rule reads the last two; nothing may parse `id`.
    public let path: [String]
    public let size: Int64
    /// Opaque. Equal means the bytes are unchanged — Drive's `headRevisionId`.
    /// Nil means never reuse a cached copy, because nothing can confirm it is
    /// still current.
    public let contentVersion: String?
    /// For checking the bytes after a download. Absent for some files, so a
    /// cache cannot depend on having it.
    public let md5: String?

    public init(
        id: String, name: String, path: [String],
        size: Int64, contentVersion: String?, md5: String?
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.contentVersion = contentVersion
        self.md5 = md5
    }

    /// What this clip's analysis is keyed on.
    ///
    /// The file id alone, so a clip renamed or moved in Drive keeps the
    /// alignment and pose work already done on it — the thing a path-keyed
    /// sidecar could never manage.
    public func identity(inProvider provider: String) -> ClipIdentity {
        .remote(provider: provider, fileID: id)
    }
}

/// A URL plus the headers that must accompany every request to it.
///
/// Headers rather than a signed URL because Google Drive has no
/// pre-authenticated download link: measured 2026-08-13, a query-string
/// `access_token` on `alt=media` is refused with a 403 HTML anti-abuse page
/// while the same request with `Authorization: Bearer` returns 206 and bytes.
/// That is workable only because `URLSession` fetches these bytes — `AVPlayer`
/// never sees this URL.
public struct DownloadSource: Sendable {
    public let url: URL
    public let headers: [String: String]

    public init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }
}

public enum RemoteLibraryError: LocalizedError, Equatable {
    case notSignedIn
    case api(String)
    case cancelled
    /// Drive answers an unauthenticated media request with an HTML block page
    /// rather than JSON. Its own case so a caller cannot mistake the body for
    /// an API error object.
    case unexpectedResponseBody(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to your club's Google account to browse the shared library."
        case let .api(message), let .unexpectedResponseBody(message):
            return message
        case .cancelled:
            return "The request was cancelled."
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter RemoteLibraryProviderTests
```
Expected: PASS, 4 tests.

- [ ] **Step 5: Check purity and your own warnings**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CorePurityTests
touch Sources/SkiVideoCore/RemoteLibraryProvider.swift Tests/SkiVideoCoreTests/FakeRemoteProvider.swift Tests/SkiVideoCoreTests/RemoteLibraryProviderTests.swift
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --build-tests 2>&1 \
  | grep "warning:" | grep -E "RemoteLibrary|FakeRemote"
```
Expected: `CorePurityTests` passes; the grep prints nothing.

- [ ] **Step 6: Commit**

```bash
git add SkiVideoViewer/Sources/SkiVideoCore/RemoteLibraryProvider.swift \
        SkiVideoViewer/Tests/SkiVideoCoreTests/FakeRemoteProvider.swift \
        SkiVideoViewer/Tests/SkiVideoCoreTests/RemoteLibraryProviderTests.swift
git commit -m "Say what the app needs from a cloud library

Four methods: sign in, list the roots, stream the files, say where the bytes
are. A clip's identity is its file id alone, so renaming or moving it in Drive
keeps the analysis already done on it.

Headers rather than a signed URL because Drive has no pre-authenticated link —
measured, a query-string token on alt=media is refused with an HTML block page."
```

---

### Task 2: Move OAuth out of `GoogleDriveSupport`

**Files:**
- Create: `Sources/SkiVideoCore/GoogleOAuth.swift`
- Modify: `Sources/SkiVideoCore/GoogleDriveSupport.swift` (remove the moved code)

**Interfaces:**
- Consumes: `OAuthPresenter` (`Seams.swift`).
- Produces: `DriveError` (unchanged, still `public` — `AppKitOAuthPresenter` throws it), `GoogleOAuthClient`, `GoogleOAuth.authorize(client:presenter:)`, `KeychainTokenStore`. Task 4 consumes `GoogleOAuth`.

**This is a pure move.** Cut the code, paste it, change nothing. Any behaviour change here is a defect — the point is that Task 4's review sees only new code, not a diff tangled with a relocation.

- [ ] **Step 1: Confirm the tests that must not move**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter AppKitOAuthPresenterTests
```
Expected: PASS. Record the count; it must be identical after the move.

- [ ] **Step 2: Move the code**

From `Sources/SkiVideoCore/GoogleDriveSupport.swift`, cut these declarations **verbatim, including every doc comment** and paste them into a new `Sources/SkiVideoCore/GoogleOAuth.swift` with `import CryptoKit`, `import Foundation`, `import Security` at the top:

- `public enum DriveError`
- `private struct GoogleOAuthClient`
- `private enum GoogleOAuth`
- `private struct GoogleTokenResponse`
- `private enum KeychainTokenStore`
- `private extension Data { base64URLEncodedString }`
- `private extension String { urlFormEncoded }`

Change exactly one thing: `GoogleOAuthClient` and `GoogleOAuth` become **internal** (drop `private`) so Task 4's `GoogleDriveProvider` can call them from its own file. Everything else keeps its access level. `DriveError` stays `public`.

Add this file-level doc comment at the top of the new file:

```swift
/// Google's OAuth 2.0 flow for an installed app: PKCE, a presenter-supplied
/// redirect, and a refresh token in the Keychain.
///
/// Its own file because it is not about Drive. The same flow authorizes any
/// Google API, and keeping it beside the Drive client made a 510-line file
/// that did five jobs.
```

- [ ] **Step 3: Verify nothing changed**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -5
```
Expected: the full suite green, with the same totals as before the move.

```bash
git diff --stat
```
Expected: `GoogleDriveSupport.swift` loses roughly the lines `GoogleOAuth.swift` gains. A large net change in either direction means something was rewritten rather than moved.

- [ ] **Step 4: Commit**

```bash
git add SkiVideoViewer/Sources/SkiVideoCore/GoogleOAuth.swift \
        SkiVideoViewer/Sources/SkiVideoCore/GoogleDriveSupport.swift
git commit -m "Give the Google sign-in flow its own file

A pure move, so the provider that replaces the Drive client lands as new code
rather than as a diff tangled with a relocation. The flow is not about Drive —
it authorizes any Google API — and it was sharing a 510-line file with four
other jobs."
```

---

### Task 3: The index — tree reconstruction, library URLs, grouping

**Files:**
- Create: `Sources/SkiVideoCore/RemoteLibraryIndex.swift`
- Test: `Tests/SkiVideoCoreTests/RemoteLibraryIndexTests.swift`

**Interfaces:**
- Consumes: `RemoteFile`, `RemoteFolder` (Task 1), `LibraryGrouping`, `AthleteGroup`, `VideoLibrary.supportedExtensions`.
- Produces: `RemoteLibraryIndex` (a value type), `RemoteLibraryIndex.libraryURL(for:providerIdentifier:)`, `RemoteLibraryIndex.athletes`, `RemoteLibraryIndex.file(for: URL)`. Tasks 6 and 7 consume these.

This task is pure: no network, no disk. Persistence is Task 5.

- [ ] **Step 1: Write the failing test**

Create `Tests/SkiVideoCoreTests/RemoteLibraryIndexTests.swift`:

```swift
import XCTest
@testable import SkiVideoCore

final class RemoteLibraryIndexTests: XCTestCase {
    private func file(
        _ id: String, _ name: String, _ path: [String], size: Int64 = 1
    ) -> RemoteFile {
        RemoteFile(id: id, name: name, path: path, size: size,
                   contentVersion: "v1", md5: nil)
    }

    // MARK: - Library URLs

    /// The folder path rides in the URL path, which is what `LibraryGrouping`
    /// sorts on. Without it, Drive clips sort by file name alone and sibling
    /// folders interleave — the defect `GoogleDriveSupport` documented.
    func testALibraryURLCarriesTheFolderPathAndTheFileID() {
        let url = RemoteLibraryIndex.libraryURL(
            for: file("1AbC", "run 3.mp4", ["Neuss 2026", "Ada Lovelace"]),
            providerIdentifier: "gdrive"
        )
        XCTAssertEqual(url.scheme, "gdrive")
        XCTAssertEqual(url.host, "1AbC")
        XCTAssertEqual(url.path, "/Neuss 2026/Ada Lovelace/run 3.mp4")
        XCTAssertEqual(url.lastPathComponent, "run 3.mp4")
    }

    /// Two clips sharing a name in different folders must be different URLs,
    /// or the index would lose one of them.
    func testTwoClipsWithOneNameInDifferentFoldersAreDifferentURLs() {
        let a = RemoteLibraryIndex.libraryURL(
            for: file("a", "run.mp4", ["E", "Ada"]), providerIdentifier: "gdrive")
        let b = RemoteLibraryIndex.libraryURL(
            for: file("b", "run.mp4", ["E", "Bea"]), providerIdentifier: "gdrive")
        XCTAssertNotEqual(a, b)
    }

    /// A file id is base64url and contains `-` and `_`. Verified against
    /// Foundation: both survive as a URL host.
    func testAFileIDWithBase64URLCharactersSurvives() {
        let url = RemoteLibraryIndex.libraryURL(
            for: file("1A_bC-dEf", "run.mp4", ["E", "Ada"]), providerIdentifier: "gdrive")
        XCTAssertEqual(url.host, "1A_bC-dEf")
    }

    // MARK: - Grouping

    func testAthleteAndEventComeFromTheLastTwoPathComponents() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive",
            files: [file("a", "run.mp4", ["Neuss 2026", "Ada"])]
        )
        XCTAssertEqual(index.athletes.map(\.name), ["Ada"])
        XCTAssertEqual(index.athletes.map(\.event), ["Neuss 2026"])
    }

    /// A clip one level down has an athlete but no event, exactly as a local
    /// library does for `root/Athlete/clip.mp4`.
    func testAClipOneLevelDownHasAnAthleteButNoEvent() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive",
            files: [file("a", "run.mp4", ["Ada"])]
        )
        XCTAssertEqual(index.athletes.map(\.name), ["Ada"])
        XCTAssertNil(index.athletes[0].event)
    }

    /// A clip loose in the root has neither. It is grouped under the root's
    /// own name, which is the closest analogue to what the local scanner does.
    func testALooseClipIsGroupedUnderTheRootName() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive",
            rootName: "Club Footage",
            files: [file("a", "run.mp4", [])]
        )
        XCTAssertEqual(index.athletes.map(\.name), ["Club Footage"])
        XCTAssertNil(index.athletes[0].event)
    }

    /// Clips deeper than event/athlete take the two folders nearest them, so
    /// an extra organisational layer above does not break grouping.
    func testDeeperClipsUseTheTwoFoldersNearestThem() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive",
            files: [file("a", "run.mp4", ["2026", "Neuss 2026", "Ada"])]
        )
        XCTAssertEqual(index.athletes.map(\.name), ["Ada"])
        XCTAssertEqual(index.athletes.map(\.event), ["Neuss 2026"])
    }

    /// Within an athlete, clips sort by folder path then name — the local
    /// scanner's order, which the old flat URL could not produce.
    func testClipsSortByFolderPathThenName() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive",
            files: [
                file("c", "b.mp4", ["E", "Ada"]),
                file("a", "a.mp4", ["E", "Ada"]),
            ]
        )
        XCTAssertEqual(
            index.athletes[0].videos.map(\.lastPathComponent), ["a.mp4", "b.mp4"]
        )
    }

    // MARK: - Filtering

    func testOnlyPlayableExtensionsAreIndexed() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive",
            files: [
                file("a", "run.mp4", ["E", "Ada"]),
                file("b", "notes.txt", ["E", "Ada"]),
                file("c", "old.mkv", ["E", "Ada"]),
            ]
        )
        XCTAssertEqual(index.athletes[0].videos.map(\.lastPathComponent), ["run.mp4"])
    }

    /// The same list the local scanner uses, not a copy of it. Drive kept its
    /// own set until 2026-08-08 and offered files `AVPlayer` cannot open.
    func testTheExtensionListIsTheLocalScannersOwn() {
        XCTAssertEqual(
            RemoteLibraryIndex.supportedExtensions, VideoLibrary.supportedExtensions
        )
    }

    // MARK: - Lookup

    func testAFileCanBeFoundBackFromItsLibraryURL() {
        let indexed = file("1AbC", "run.mp4", ["E", "Ada"])
        let index = RemoteLibraryIndex(providerIdentifier: "gdrive", files: [indexed])
        let url = index.athletes[0].videos[0]
        XCTAssertEqual(index.file(for: url)?.id, "1AbC")
    }

    func testAnUnknownURLFindsNothing() {
        let index = RemoteLibraryIndex(providerIdentifier: "gdrive", files: [])
        XCTAssertNil(index.file(for: URL(fileURLWithPath: "/tmp/run.mp4")))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter RemoteLibraryIndexTests
```
Expected: FAIL to compile — `cannot find 'RemoteLibraryIndex' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SkiVideoCore/RemoteLibraryIndex.swift`:

```swift
import Foundation

/// A cloud library as the sidebar sees it: the files, the groups they form,
/// and the way back from a group's URL to the file it came from.
///
/// A value type computed once from a flat file list. The folder *tree* is not
/// stored — Drive's flat sweep already hands each file the names of the
/// folders above it, so there is nothing to walk.
public struct RemoteLibraryIndex: Equatable {
    /// The same list the local scanner uses, deliberately not a copy. Drive
    /// kept its own set until 2026-08-08, still naming avi, mkv and webm after
    /// the local one dropped them — so Drive offered files `AVPlayer` cannot
    /// open. One source of truth cannot drift like that.
    public static var supportedExtensions: Set<String> { VideoLibrary.supportedExtensions }

    public let providerIdentifier: String
    /// What a clip loose in the root is grouped under. Stored, not just a
    /// parameter, because Task 5 reloads an index from disk and it has to
    /// group those clips the same way the sweep that built it did.
    public let rootName: String
    public private(set) var athletes: [AthleteGroup]

    private var filesByURL: [URL: RemoteFile]

    public init(
        providerIdentifier: String,
        rootName: String = "Unsorted",
        files: [RemoteFile]
    ) {
        self.providerIdentifier = providerIdentifier
        self.rootName = rootName

        var entries: [LibraryGrouping.Entry] = []
        var filesByURL: [URL: RemoteFile] = [:]

        for file in files {
            guard Self.supportedExtensions.contains(
                URL(fileURLWithPath: file.name).pathExtension.lowercased()
            ) else { continue }

            let url = Self.libraryURL(for: file, providerIdentifier: providerIdentifier)
            filesByURL[url] = file
            entries.append(
                LibraryGrouping.Entry(
                    video: url,
                    // The two folders nearest the clip, the same rule the
                    // local scanner applies to a path. A clip loose in the
                    // root has neither, and is grouped under the root's own
                    // name — the grouping *key*, not a caption, which is why
                    // a literal "Unsorted" would fold a real folder of that
                    // name together with the loose files.
                    athlete: file.path.last ?? rootName,
                    event: file.path.count >= 2 ? file.path[file.path.count - 2] : nil
                )
            )
        }

        self.filesByURL = filesByURL
        self.athletes = LibraryGrouping.group(entries)
    }

    /// The URL the sidebar, the comparison picker and the analysis stores all
    /// carry for this clip.
    ///
    /// The file id is the host and the folder path is the URL path. Both parts
    /// are load-bearing. The id makes two clips that share a name distinct and
    /// survives a rename in Drive. The folder path is what
    /// `LibraryGrouping.pathOrder` sorts on — with only the file name there,
    /// as the old client had it, Drive clips sorted by name alone and sibling
    /// folders interleaved instead of staying in blocks.
    ///
    /// A Drive folder name may contain `/`, which adds URL path components and
    /// so sorts the clip as if nested deeper. Grouping is unaffected: athlete
    /// and event come from `RemoteFile.path`, never from parsing this URL.
    public static func libraryURL(
        for file: RemoteFile, providerIdentifier: String
    ) -> URL {
        var components = URLComponents()
        components.scheme = providerIdentifier
        components.host = file.id
        components.path = "/" + (file.path + [file.name]).joined(separator: "/")
        if let url = components.url { return url }
        // Unreachable for Drive, whose ids are base64url and whose names are
        // percent-encoded by URLComponents. A provider that broke that
        // assumption would otherwise crash on a force-unwrap; this keeps the
        // clip out of the library instead, where the id still makes it unique.
        return URL(string: "\(providerIdentifier)://\(file.id)")
            ?? URL(fileURLWithPath: "/dev/null")
    }

    /// The file a library URL stands for, or nil when the URL is not this
    /// index's — a local clip, or one indexed before a refresh dropped it.
    public func file(for url: URL) -> RemoteFile? { filesByURL[url] }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter RemoteLibraryIndexTests
```
Expected: PASS, 12 tests.

- [ ] **Step 5: Confirm the local library is untouched**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter "VideoLibraryTests|LibraryGroupingTests"
```
Expected: PASS. This task adds a second caller of `LibraryGrouping`; the first must be unaffected.

- [ ] **Step 6: Commit**

```bash
git add SkiVideoViewer/Sources/SkiVideoCore/RemoteLibraryIndex.swift \
        SkiVideoViewer/Tests/SkiVideoCoreTests/RemoteLibraryIndexTests.swift
git commit -m "Group a cloud library the way the local one is grouped

The folder path now rides in the library URL's path, which is what
LibraryGrouping sorts on. The old client put only the file name there, so Drive
clips sorted by name alone and sibling folders interleaved instead of staying in
blocks — a defect that file documented and could not fix from where it stood.

Athlete and event still come from the file's own folder names, never from
parsing the URL, so a Drive folder containing a slash cannot reshape a group."
```

---

### Task 4: `GoogleDriveProvider` — roots, the flat sweep, download source

**Files:**
- Create: `Sources/SkiVideoCore/HTTPTransport.swift`
- Create: `Sources/SkiVideoCore/GoogleDriveProvider.swift`
- Create: `Tests/SkiVideoCoreTests/FakeHTTPTransport.swift`
- Test: `Tests/SkiVideoCoreTests/GoogleDriveProviderTests.swift`

**Interfaces:**
- Consumes: `RemoteLibraryProvider` and its types (Task 1), `GoogleOAuth` (Task 2).
- Produces: `HTTPTransport`, `URLSessionTransport`, `GoogleDriveProvider(transport:tokenProvider:)`, `GoogleDriveProvider.identifier == "gdrive"`. Task 7 constructs it.

- [ ] **Step 1: Write the failing test**

Create `Tests/SkiVideoCoreTests/FakeHTTPTransport.swift`:

```swift
import Foundation
@testable import SkiVideoCore

/// Canned HTTP, so provider tests never reach the network.
///
/// Records every request, which is how the tests assert on query parameters —
/// `supportsAllDrives`, `pageSize` and `corpora` are exactly the parameters
/// whose omission fails *silently* against the real API.
final class FakeHTTPTransport: HTTPTransport, @unchecked Sendable {
    struct Response {
        let status: Int
        let body: Data
        let contentType: String

        init(status: Int = 200, json: String, contentType: String = "application/json") {
            self.status = status
            self.body = Data(json.utf8)
            self.contentType = contentType
        }
    }

    /// Consumed in order, one per request.
    var responses: [Response] = []
    private(set) var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw RemoteLibraryError.api("FakeHTTPTransport ran out of responses")
        }
        let response = responses.removeFirst()
        let http = HTTPURLResponse(
            url: request.url!, statusCode: response.status,
            httpVersion: nil, headerFields: ["Content-Type": response.contentType]
        )!
        return (response.body, http)
    }

    /// The query items of the nth request, for assertions.
    func queryItems(of index: Int) -> [String: String] {
        guard requests.indices.contains(index),
              let url = requests[index].url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return [:] }
        return Dictionary(items.compactMap { item in
            item.value.map { (item.name, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }
}
```

Create `Tests/SkiVideoCoreTests/GoogleDriveProviderTests.swift`:

```swift
import XCTest
@testable import SkiVideoCore

final class GoogleDriveProviderTests: XCTestCase {
    private var transport: FakeHTTPTransport!
    private var provider: GoogleDriveProvider!

    override func setUp() {
        super.setUp()
        transport = FakeHTTPTransport()
        provider = GoogleDriveProvider(transport: transport, token: { "test-token" })
    }

    // MARK: - Credentials

    /// Measured 2026-08-13: a query-string token on `alt=media` is refused
    /// with a 403 HTML page while the header form returns 206 and bytes.
    /// The token must never appear in a URL.
    func testTheTokenIsSentAsAHeaderAndNeverInTheURL() async throws {
        transport.responses = [.init(json: #"{"drives":[]}"#)]
        _ = try await provider.roots()

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertFalse(try XCTUnwrap(request.url).absoluteString.contains("access_token"))
    }

    func testADownloadSourceCarriesTheTokenAsAHeader() async throws {
        let source = try await provider.downloadSource(
            for: RemoteFile(id: "1AbC", name: "run.mp4", path: [],
                            size: 1, contentVersion: nil, md5: nil)
        )
        XCTAssertEqual(source.headers["Authorization"], "Bearer test-token")
        XCTAssertFalse(source.url.absoluteString.contains("access_token"))
        XCTAssertTrue(source.url.absoluteString.contains("alt=media"))
    }

    // MARK: - Roots

    func testRootsListsTheSharedDrivesTheAccountCanSee() async throws {
        transport.responses = [.init(json: """
        {"drives":[{"id":"d1","name":"Club Footage"},{"id":"d2","name":"Archive"}]}
        """)]

        let roots = try await provider.roots()

        XCTAssertEqual(roots.map(\.name), ["Club Footage", "Archive"])
        XCTAssertEqual(roots.map(\.id), ["d1", "d2"])
    }

    /// `drives.list` defaults to a page size of 10, which would silently
    /// truncate the picker for a club in more drives than that.
    func testRootsAsksForAFullPage() async throws {
        transport.responses = [.init(json: #"{"drives":[]}"#)]
        _ = try await provider.roots()
        XCTAssertEqual(transport.queryItems(of: 0)["pageSize"], "100")
    }

    // MARK: - The sweep

    /// One flat query per drive, not one request per folder. The folder tree
    /// is rebuilt here from each file's `parents`.
    func testEnumerateSweepsTheWholeDriveInOneQuery() async throws {
        transport.responses = [.init(json: """
        {"files":[
          {"id":"f1","name":"Neuss 2026","mimeType":"application/vnd.google-apps.folder","parents":["d1"]},
          {"id":"f2","name":"Ada","mimeType":"application/vnd.google-apps.folder","parents":["f1"]},
          {"id":"f3","name":"run.mp4","mimeType":"video/mp4","parents":["f2"],
           "size":"32000000","headRevisionId":"rev1","md5Checksum":"abc"}
        ]}
        """)]

        var files: [RemoteFile] = []
        for try await file in provider.enumerate(RemoteFolder(id: "d1", name: "Club Footage")) {
            files.append(file)
        }

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].id, "f3")
        XCTAssertEqual(files[0].path, ["Neuss 2026", "Ada"])
        XCTAssertEqual(files[0].size, 32_000_000)
        XCTAssertEqual(files[0].contentVersion, "rev1")
        XCTAssertEqual(files[0].md5, "abc")
    }

    /// Omitting `supportsAllDrives` excludes shared-drive items *silently* —
    /// the classic "my drive looks empty" bug — and `corpora=allDrives` can
    /// drop files without erroring. Both are pinned here because neither
    /// failure announces itself.
    func testTheSweepSetsTheParametersWhoseAbsenceFailsSilently() async throws {
        transport.responses = [.init(json: #"{"files":[]}"#)]
        for try await _ in provider.enumerate(RemoteFolder(id: "d1", name: "Club")) {}

        let query = transport.queryItems(of: 0)
        XCTAssertEqual(query["supportsAllDrives"], "true")
        XCTAssertEqual(query["includeItemsFromAllDrives"], "true")
        XCTAssertEqual(query["corpora"], "drive")
        XCTAssertEqual(query["driveId"], "d1")
        XCTAssertEqual(query["pageSize"], "1000")
        XCTAssertEqual(query["q"], "trashed = false")
    }

    func testTheSweepFollowsPageTokens() async throws {
        transport.responses = [
            .init(json: """
            {"nextPageToken":"p2","files":[
              {"id":"f1","name":"a.mp4","mimeType":"video/mp4","parents":["d1"],"size":"1"}
            ]}
            """),
            .init(json: """
            {"files":[
              {"id":"f2","name":"b.mp4","mimeType":"video/mp4","parents":["d1"],"size":"2"}
            ]}
            """),
        ]

        var ids: [String] = []
        for try await file in provider.enumerate(RemoteFolder(id: "d1", name: "Club")) {
            ids.append(file.id)
        }

        XCTAssertEqual(ids, ["f1", "f2"])
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.queryItems(of: 1)["pageToken"], "p2")
    }

    /// `incompleteSearch` means Drive dropped files without erroring. Ignoring
    /// it would show a partial library as if it were whole.
    func testAnIncompleteSearchFailsTheSweep() async {
        transport.responses = [.init(json: #"{"incompleteSearch":true,"files":[]}"#)]

        do {
            for try await _ in provider.enumerate(RemoteFolder(id: "d1", name: "Club")) {}
            XCTFail("expected an incomplete search to throw")
        } catch {
            XCTAssertTrue("\(error)".contains("incomplete"), "got \(error)")
        }
    }

    /// A file whose parent is not in the sweep — its folder was trashed, or
    /// access to it was lost — is kept with the path that could be resolved,
    /// not dropped. Losing a clip because a folder record is missing is worse
    /// than filing it one level shallow.
    func testAFileWithAnUnresolvableParentIsKeptNotDropped() async throws {
        transport.responses = [.init(json: """
        {"files":[
          {"id":"f3","name":"run.mp4","mimeType":"video/mp4","parents":["missing"],"size":"1"}
        ]}
        """)]

        var files: [RemoteFile] = []
        for try await file in provider.enumerate(RemoteFolder(id: "d1", name: "Club")) {
            files.append(file)
        }

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, [])
    }

    /// A folder cycle would hang a naive parent walk. Drive should not produce
    /// one, which is exactly why nothing would catch it in production.
    func testAParentCycleTerminates() async throws {
        transport.responses = [.init(json: """
        {"files":[
          {"id":"a","name":"A","mimeType":"application/vnd.google-apps.folder","parents":["b"]},
          {"id":"b","name":"B","mimeType":"application/vnd.google-apps.folder","parents":["a"]},
          {"id":"f","name":"run.mp4","mimeType":"video/mp4","parents":["a"],"size":"1"}
        ]}
        """)]

        var files: [RemoteFile] = []
        for try await file in provider.enumerate(RemoteFolder(id: "d1", name: "Club")) {
            files.append(file)
        }

        XCTAssertEqual(files.count, 1)
        XCTAssertLessThanOrEqual(files[0].path.count, 2)
    }

    // MARK: - Errors

    /// Drive answers an unauthenticated media request with an HTML block page.
    /// A client that assumes non-200 means JSON would mis-parse it.
    func testAnHTMLErrorBodyIsReportedAsSuchRatherThanMisParsed() async {
        transport.responses = [.init(
            status: 403, json: "<html><head><title>Sorry...</title></head></html>",
            contentType: "text/html"
        )]

        do {
            _ = try await provider.roots()
            XCTFail("expected a 403 to throw")
        } catch let error as RemoteLibraryError {
            guard case .unexpectedResponseBody = error else {
                return XCTFail("expected .unexpectedResponseBody, got \(error)")
            }
        } catch {
            XCTFail("expected RemoteLibraryError, got \(error)")
        }
    }

    func testAJSONErrorBodyKeepsGooglesMessage() async {
        transport.responses = [.init(
            status: 403,
            json: #"{"error":{"code":403,"message":"Insufficient permissions"}}"#
        )]

        do {
            _ = try await provider.roots()
            XCTFail("expected a 403 to throw")
        } catch {
            XCTAssertTrue("\(error)".contains("Insufficient permissions"), "got \(error)")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter GoogleDriveProviderTests
```
Expected: FAIL to compile — `cannot find 'HTTPTransport' in scope`.

- [ ] **Step 3: Write the transport seam**

Create `Sources/SkiVideoCore/HTTPTransport.swift`:

```swift
import Foundation

/// The one HTTP call the remote library makes, behind a seam.
///
/// Exists so provider tests can assert on the query parameters whose omission
/// fails *silently* against the real API — `supportsAllDrives`, `pageSize`,
/// `corpora` — without reaching the network. Those are precisely the mistakes
/// that surface as an empty library rather than as an error.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteLibraryError.api("The server's reply was not an HTTP response.")
        }
        return (data, http)
    }
}
```

- [ ] **Step 4: Write the provider**

Create `Sources/SkiVideoCore/GoogleDriveProvider.swift`:

```swift
import Foundation

/// Google Drive as a remote library.
///
/// One flat paged sweep per Shared Drive, not a folder-by-folder walk: Drive
/// can list a whole drive with `corpora=drive`, so a 1,000-clip library is two
/// round trips rather than one per folder. The folder tree is rebuilt here
/// from each file's `parents`.
public struct GoogleDriveProvider: RemoteLibraryProvider {
    public static let identifier = "gdrive"

    private static let folderMimeType = "application/vnd.google-apps.folder"
    /// Drive returns a minimal field set unless asked. Every field here is
    /// used: `headRevisionId` is the cache-validity key, `md5Checksum` the
    /// post-download check, `parents` the tree, `size` the progress bar.
    private static let fileFields =
        "nextPageToken,incompleteSearch,files(id,name,mimeType,size,md5Checksum,headRevisionId,parents)"

    private let transport: HTTPTransport
    private let token: @Sendable () -> String?

    /// `token` is read per request rather than captured once, so a refresh
    /// between calls is picked up without rebuilding the provider.
    public init(transport: HTTPTransport = URLSessionTransport(), token: @escaping @Sendable () -> String?) {
        self.transport = transport
        self.token = token
    }

    public func connect(presenter: OAuthPresenter) async throws {
        // Sign-in lands in plan 3, which owns the client registration and the
        // two platform redirect paths. Until then the token closure supplies
        // credentials obtained elsewhere.
        throw RemoteLibraryError.notSignedIn
    }

    public func roots() async throws -> [RemoteFolder] {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/drives")!
        components.queryItems = [
            // The default is 10, which would silently truncate the picker for
            // an account in more drives than that.
            URLQueryItem(name: "pageSize", value: "100"),
        ]
        let page: DriveListOfDrives = try await get(components)
        return page.drives.map { RemoteFolder(id: $0.id, name: $0.name) }
    }

    public func enumerate(_ folder: RemoteFolder) -> AsyncThrowingStream<RemoteFile, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let records = try await sweep(driveID: folder.id)
                    let folders = Dictionary(
                        uniqueKeysWithValues: records
                            .filter { $0.mimeType == Self.folderMimeType }
                            .map { ($0.id, $0) }
                    )
                    for record in records where record.mimeType != Self.folderMimeType {
                        continuation.yield(
                            RemoteFile(
                                id: record.id,
                                name: record.name,
                                path: Self.folderPath(of: record, in: folders, rootID: folder.id),
                                size: Int64(record.size ?? "") ?? 0,
                                contentVersion: record.headRevisionId,
                                md5: record.md5Checksum
                            )
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func downloadSource(for file: RemoteFile) async throws -> DownloadSource {
        guard let token = token() else { throw RemoteLibraryError.notSignedIn }
        var components = URLComponents(
            string: "https://www.googleapis.com/drive/v3/files"
        )!
        // Appended through `path` so an id that is not URL-safe is encoded
        // rather than reshaping the request.
        components.path += "/\(file.id)"
        components.queryItems = [
            URLQueryItem(name: "alt", value: "media"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
        ]
        guard let url = components.url else {
            throw RemoteLibraryError.api("That Drive file id cannot be used in a request.")
        }
        return DownloadSource(url: url, headers: ["Authorization": "Bearer \(token)"])
    }

    // MARK: - The sweep

    private func sweep(driveID: String) async throws -> [DriveRecord] {
        var records: [DriveRecord] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(
                string: "https://www.googleapis.com/drive/v3/files"
            )!
            components.queryItems = [
                URLQueryItem(name: "corpora", value: "drive"),
                URLQueryItem(name: "driveId", value: driveID),
                // Omitting either excludes shared-drive items *silently*,
                // which reads as an empty library rather than as an error.
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
                // Defaults to 100 for a shared drive; 1000 makes a
                // 1,000-clip library two requests instead of eleven.
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "q", value: "trashed = false"),
                URLQueryItem(name: "fields", value: Self.fileFields),
            ]
            if let pageToken {
                components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            let page: DriveFileList = try await get(components)
            // Drive can drop files from a result without erroring. Reporting a
            // partial library as whole is the one outcome worth failing over.
            if page.incompleteSearch == true {
                throw RemoteLibraryError.api(
                    "Google Drive returned an incomplete listing for this drive. Try again."
                )
            }
            records.append(contentsOf: page.files)
            pageToken = page.nextPageToken
        } while pageToken != nil
        return records
    }

    /// The folder names from the drive root down to this record's parent.
    ///
    /// Bounded by the number of known folders, not by trust in the data: a
    /// parent cycle would otherwise spin forever, and nothing in production
    /// would catch it because Drive should never produce one. A record whose
    /// parent is missing — trashed folder, lost access — keeps the path that
    /// could be resolved rather than being dropped, because losing a clip is
    /// worse than filing it one level shallow.
    static func folderPath(
        of record: DriveRecord, in folders: [String: DriveRecord], rootID: String
    ) -> [String] {
        var names: [String] = []
        var seen: Set<String> = []
        var current = record.parents?.first
        while let id = current, id != rootID, !seen.contains(id), names.count <= folders.count {
            seen.insert(id)
            guard let folder = folders[id] else { break }
            names.append(folder.name)
            current = folder.parents?.first
        }
        return names.reversed()
    }

    // MARK: - Requests

    private func get<T: Decodable>(_ components: URLComponents) async throws -> T {
        guard let token = token() else { throw RemoteLibraryError.notSignedIn }
        guard let url = components.url else {
            throw RemoteLibraryError.api("Could not build a request to Google Drive.")
        }
        var request = URLRequest(url: url)
        // Never a query parameter. Measured 2026-08-13: on the media path a
        // query-string token is refused with an HTML block page.
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await transport.data(for: request)
        guard (200...299).contains(response.statusCode) else {
            throw Self.describeFailure(data: data, response: response)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RemoteLibraryError.api(
                "Google Drive returned an unexpected reply: \(error.localizedDescription)"
            )
        }
    }

    /// Google answers some failures with an HTML anti-abuse page rather than a
    /// JSON error object. A caller that assumes non-200 means JSON would
    /// mis-parse that, so the two are told apart before decoding.
    static func describeFailure(data: Data, response: HTTPURLResponse) -> RemoteLibraryError {
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        if !contentType.contains("json") {
            return .unexpectedResponseBody(
                """
                Google Drive answered with a \(response.statusCode) web page rather than an \
                API reply. This usually means the request was not authenticated.
                """
            )
        }
        let decoded = try? JSONDecoder().decode(DriveAPIError.self, from: data)
        let message = decoded?.error?.message ?? "No detail returned by Google."
        return .api("Google Drive returned HTTP \(response.statusCode): \(message)")
    }
}

// MARK: - Wire formats

struct DriveRecord: Decodable {
    let id: String
    let name: String
    let mimeType: String
    let size: String?
    let md5Checksum: String?
    let headRevisionId: String?
    let parents: [String]?
}

private struct DriveFileList: Decodable {
    let nextPageToken: String?
    let incompleteSearch: Bool?
    let files: [DriveRecord]
}

private struct DriveListOfDrives: Decodable {
    struct Drive: Decodable {
        let id: String
        let name: String
    }

    let drives: [Drive]
}

private struct DriveAPIError: Decodable {
    struct Details: Decodable {
        let code: Int?
        let message: String?
    }

    let error: Details?
}
```

- [ ] **Step 5: Run test to verify it passes**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter GoogleDriveProviderTests
```
Expected: PASS, 11 tests.

- [ ] **Step 6: Confirm no test reaches the network**

```bash
grep -rn "googleapis.com" Tests/ || echo "no test names a real host"
```
Expected: nothing but the fixture strings inside `GoogleDriveProviderTests` if any; no test constructs a `URLSessionTransport`.

- [ ] **Step 7: Commit**

```bash
git add SkiVideoViewer/Sources/SkiVideoCore/HTTPTransport.swift \
        SkiVideoViewer/Sources/SkiVideoCore/GoogleDriveProvider.swift \
        SkiVideoViewer/Tests/SkiVideoCoreTests/FakeHTTPTransport.swift \
        SkiVideoViewer/Tests/SkiVideoCoreTests/GoogleDriveProviderTests.swift
git commit -m "Sweep a Shared Drive in one query instead of one per folder

Drive can list a whole drive with corpora=drive, so a thousand clips are two
round trips rather than one request per folder. The tree is rebuilt from each
file's parents.

The parameters pinned by tests here are the ones whose omission fails silently:
supportsAllDrives excludes shared-drive items without erroring, pageSize
defaults to 100, and incompleteSearch means Drive dropped files and said so
only in a flag. A partial library reported as whole is the failure worth
throwing over."
```

---

### Task 5: Persist the index and refresh it from the change feed

**Files:**
- Modify: `Sources/SkiVideoCore/RemoteLibraryIndex.swift`
- Modify: `Sources/SkiVideoCore/GoogleDriveProvider.swift`
- Modify: `Sources/SkiVideoCore/RemoteLibraryProvider.swift`
- Test: `Tests/SkiVideoCoreTests/RemoteLibraryIndexTests.swift`, `Tests/SkiVideoCoreTests/GoogleDriveProviderTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1, 3, 4.
- Produces: `IncrementallyEnumerable` (optional protocol), `RemoteLibraryChanges`, `RemoteLibraryIndex.applying(_:)`, `RemoteLibraryIndex.save(to:)`, `RemoteLibraryIndex.load(from:)`, `RemoteLibraryIndex.storeRoot`. Task 7 consumes these.

- [ ] **Step 1: Write the failing test**

Append to `Tests/SkiVideoCoreTests/RemoteLibraryIndexTests.swift`:

```swift
    // MARK: - Persistence

    private func withTemporaryStore(_ body: (URL) throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let previous = RemoteLibraryIndex.storeRoot
        RemoteLibraryIndex.storeRoot = root
        defer {
            RemoteLibraryIndex.storeRoot = previous
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }

    func testAnIndexSurvivesASaveAndLoad() throws {
        try withTemporaryStore { _ in
            let index = RemoteLibraryIndex(
                providerIdentifier: "gdrive",
                files: [file("a", "run.mp4", ["E", "Ada"])],
                cursor: "cursor-1"
            )
            try index.save(forRoot: "d1")

            let loaded = try XCTUnwrap(RemoteLibraryIndex.load(forRoot: "d1"))
            XCTAssertEqual(loaded.athletes.map(\.name), ["Ada"])
            XCTAssertEqual(loaded.cursor, "cursor-1")
            XCTAssertEqual(loaded.file(for: loaded.athletes[0].videos[0])?.id, "a")
        }
    }

    func testTwoDrivesKeepSeparateIndexes() throws {
        try withTemporaryStore { _ in
            try RemoteLibraryIndex(
                providerIdentifier: "gdrive", files: [file("a", "a.mp4", ["E", "Ada"])], cursor: nil
            ).save(forRoot: "d1")
            try RemoteLibraryIndex(
                providerIdentifier: "gdrive", files: [file("b", "b.mp4", ["E", "Bea"])], cursor: nil
            ).save(forRoot: "d2")

            XCTAssertEqual(RemoteLibraryIndex.load(forRoot: "d1")?.athletes.map(\.name), ["Ada"])
            XCTAssertEqual(RemoteLibraryIndex.load(forRoot: "d2")?.athletes.map(\.name), ["Bea"])
        }
    }

    func testNoStoredIndexLoadsAsNil() throws {
        try withTemporaryStore { _ in
            XCTAssertNil(RemoteLibraryIndex.load(forRoot: "never-saved"))
        }
    }

    /// An index written by an older build is refused, not adapted — the same
    /// rule `AlignmentTrackStore` applies to a stale track. Refusing costs one
    /// sweep; adapting silently costs a library that is subtly wrong.
    func testAnIndexFromAnOlderVersionIsRefused() throws {
        try withTemporaryStore { root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(#"{"version":0,"providerIdentifier":"gdrive","files":[],"cursor":null}"#.utf8)
                .write(to: RemoteLibraryIndex.storeURL(forRoot: "d1"))
            XCTAssertNil(RemoteLibraryIndex.load(forRoot: "d1"))
        }
    }

    func testAnUnreadableIndexLoadsAsNilRatherThanThrowing() throws {
        try withTemporaryStore { root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: RemoteLibraryIndex.storeURL(forRoot: "d1"))
            XCTAssertNil(RemoteLibraryIndex.load(forRoot: "d1"))
        }
    }

    // MARK: - Applying changes

    func testANewFileAppearsInTheLibrary() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive", files: [file("a", "a.mp4", ["E", "Ada"])], cursor: "c1"
        )
        let refreshed = index.applying(
            RemoteLibraryChanges(
                changed: [file("b", "b.mp4", ["E", "Ada"])], removed: [], cursor: "c2"
            )
        )
        XCTAssertEqual(refreshed.athletes[0].videos.count, 2)
        XCTAssertEqual(refreshed.cursor, "c2")
    }

    /// The change feed is coalesced per file and replayed by id, so applying
    /// the same change twice must not duplicate a clip.
    func testApplyingTheSameChangeTwiceIsIdempotent() {
        let index = RemoteLibraryIndex(providerIdentifier: "gdrive", files: [], cursor: nil)
        let change = RemoteLibraryChanges(
            changed: [file("a", "a.mp4", ["E", "Ada"])], removed: [], cursor: "c1"
        )
        XCTAssertEqual(index.applying(change).applying(change).athletes[0].videos.count, 1)
    }

    /// A rename arrives as a change to the same id. The clip must move, not
    /// double.
    func testARenamedFileReplacesItsOldEntry() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive", files: [file("a", "old.mp4", ["E", "Ada"])], cursor: nil
        )
        let refreshed = index.applying(
            RemoteLibraryChanges(
                changed: [file("a", "new.mp4", ["E", "Ada"])], removed: [], cursor: "c1"
            )
        )
        XCTAssertEqual(
            refreshed.athletes[0].videos.map(\.lastPathComponent), ["new.mp4"]
        )
    }

    func testARemovedFileLeavesTheLibrary() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive",
            files: [file("a", "a.mp4", ["E", "Ada"]), file("b", "b.mp4", ["E", "Ada"])],
            cursor: nil
        )
        let refreshed = index.applying(
            RemoteLibraryChanges(changed: [], removed: ["a"], cursor: "c1")
        )
        XCTAssertEqual(refreshed.athletes[0].videos.map(\.lastPathComponent), ["b.mp4"])
    }

    /// An athlete whose last clip goes away should not linger as an empty row.
    func testAnAthleteWithNoClipsLeftDisappears() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive", files: [file("a", "a.mp4", ["E", "Ada"])], cursor: nil
        )
        let refreshed = index.applying(
            RemoteLibraryChanges(changed: [], removed: ["a"], cursor: "c1")
        )
        XCTAssertTrue(refreshed.athletes.isEmpty)
    }
```

Append to `Tests/SkiVideoCoreTests/GoogleDriveProviderTests.swift`:

```swift
    // MARK: - The change feed

    func testAFirstRefreshAsksForAStartPageToken() async throws {
        transport.responses = [.init(json: #"{"startPageToken":"t1"}"#)]
        let cursor = try await provider.startCursor(forRoot: "d1")
        XCTAssertEqual(cursor, "t1")
        XCTAssertEqual(transport.queryItems(of: 0)["driveId"], "d1")
        XCTAssertEqual(transport.queryItems(of: 0)["supportsAllDrives"], "true")
    }

    func testChangesReportAdditionsRemovalsAndTheNextCursor() async throws {
        transport.responses = [.init(json: """
        {"newStartPageToken":"t2","changes":[
          {"fileId":"f1","removed":false,
           "file":{"id":"f1","name":"run.mp4","mimeType":"video/mp4","parents":["d1"],
                   "size":"1","headRevisionId":"r1"}},
          {"fileId":"f2","removed":true}
        ]}
        """)]

        let changes = try await provider.changes(since: "t1", forRoot: "d1")

        XCTAssertEqual(changes.changed.map(\.id), ["f1"])
        XCTAssertEqual(changes.removed, ["f2"])
        XCTAssertEqual(changes.cursor, "t2")
    }

    /// The drive change log must be asked for, not the user log: files moved
    /// into a shared drive stop appearing in the user log. `includeRemoved`
    /// and `includeCorpusRemovals` are required or a deletion never arrives.
    func testChangesTrackTheDriveLogAndIncludeRemovals() async throws {
        transport.responses = [.init(json: #"{"newStartPageToken":"t2","changes":[]}"#)]
        _ = try await provider.changes(since: "t1", forRoot: "d1")

        let query = transport.queryItems(of: 0)
        XCTAssertEqual(query["driveId"], "d1")
        XCTAssertEqual(query["includeRemoved"], "true")
        XCTAssertEqual(query["includeCorpusRemovals"], "true")
        XCTAssertEqual(query["supportsAllDrives"], "true")
        XCTAssertEqual(query["pageToken"], "t1")
    }

    func testChangesFollowTheirOwnPageTokens() async throws {
        transport.responses = [
            .init(json: """
            {"nextPageToken":"p2","changes":[
              {"fileId":"f1","removed":false,
               "file":{"id":"f1","name":"a.mp4","mimeType":"video/mp4","parents":["d1"],"size":"1"}}
            ]}
            """),
            .init(json: #"{"newStartPageToken":"t2","changes":[]}"#),
        ]

        let changes = try await provider.changes(since: "t1", forRoot: "d1")

        XCTAssertEqual(changes.changed.map(\.id), ["f1"])
        XCTAssertEqual(changes.cursor, "t2")
        XCTAssertEqual(transport.requests.count, 2)
    }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter "RemoteLibraryIndexTests|GoogleDriveProviderTests"
```
Expected: FAIL to compile — `extra argument 'cursor' in call`, `cannot find 'RemoteLibraryChanges' in scope`.

- [ ] **Step 3: Add the optional protocol**

Append to `Sources/SkiVideoCore/RemoteLibraryProvider.swift`:

```swift
/// What a provider offers when it has a change feed a client can use.
///
/// Separate from `RemoteLibraryProvider` because only some providers have one:
/// Drive and Dropbox do, an object store does not. A core method would make
/// three implementations carry a stub that just re-enumerates, which reads as
/// support for something that is not there. Call sites test for it:
/// `if let incremental = provider as? IncrementallyEnumerable`.
public protocol IncrementallyEnumerable: RemoteLibraryProvider {
    /// The cursor to start from, obtained once when the library is first swept.
    func startCursor(forRoot rootID: String) async throws -> String

    /// Everything that changed since `cursor`, and the cursor to use next.
    func changes(since cursor: String, forRoot rootID: String) async throws -> RemoteLibraryChanges
}

public struct RemoteLibraryChanges: Sendable {
    public let changed: [RemoteFile]
    /// File ids that left the library. **Not a licence to delete cached
    /// bytes:** Drive reports "you lost access" and "moved to another corpus"
    /// the same way it reports a deletion, and a coach who regains access
    /// should not pay to download the clip again.
    public let removed: [String]
    public let cursor: String

    public init(changed: [RemoteFile], removed: [String], cursor: String) {
        self.changed = changed
        self.removed = removed
        self.cursor = cursor
    }
}
```

- [ ] **Step 4: Add persistence and change application to the index**

In `Sources/SkiVideoCore/RemoteLibraryIndex.swift`, add a `cursor` to the type and these members. Keep the existing `init` working by giving `cursor` a default:

```swift
    /// Where the change feed resumes, or nil before the first sweep.
    public private(set) var cursor: String?

    /// Bumped whenever the stored shape changes. A stored index from an older
    /// version is refused rather than adapted, the same rule
    /// `AlignmentTrackStore` applies to a stale track: refusing costs one
    /// sweep, adapting silently costs a library that is subtly wrong.
    static let currentVersion = 1

    /// Where indexes are written. Application Support rather than Caches: an
    /// index is cheap to rebuild but a purge would turn every launch into a
    /// full sweep. Settable so tests never write to the real directory.
    public static var storeRoot: URL = defaultStoreRoot()

    private static func defaultStoreRoot() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("SkiVideoViewer", isDirectory: true)
            .appendingPathComponent("RemoteLibrary", isDirectory: true)
    }

    /// One file per root, named by a digest of the root id — see
    /// `StorageName` for why a digest rather than the id itself.
    static func storeURL(forRoot rootID: String) -> URL {
        storeRoot
            .appendingPathComponent(StorageName.forIdentifier(rootID))
            .appendingPathExtension("skiindex.json")
    }

    public func save(forRoot rootID: String) throws {
        let url = Self.storeURL(forRoot: rootID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let stored = Stored(
            version: Self.currentVersion,
            providerIdentifier: providerIdentifier,
            rootName: rootName,
            files: Array(filesByURL.values).sorted { $0.id < $1.id },
            cursor: cursor
        )
        try JSONEncoder().encode(stored).write(to: url, options: .atomic)
    }

    /// The stored index, or nil when there is none, it cannot be read, or it
    /// was written by an older version. All three mean the same thing to the
    /// caller: sweep the drive.
    public static func load(forRoot rootID: String) -> RemoteLibraryIndex? {
        guard let data = try? Data(contentsOf: storeURL(forRoot: rootID)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version >= currentVersion
        else { return nil }
        return RemoteLibraryIndex(
            providerIdentifier: stored.providerIdentifier,
            rootName: stored.rootName,
            files: stored.files,
            cursor: stored.cursor
        )
    }

    /// The index this one becomes after a refresh.
    ///
    /// Upsert by file id, so replaying a change is harmless — Drive's log is
    /// coalesced per file and a resumed cursor can hand back one already
    /// applied. A rename arrives as a change to the same id, so it replaces
    /// rather than duplicates.
    public func applying(_ changes: RemoteLibraryChanges) -> RemoteLibraryIndex {
        var byID = Dictionary(
            filesByURL.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        for file in changes.changed { byID[file.id] = file }
        for id in changes.removed { byID.removeValue(forKey: id) }
        return RemoteLibraryIndex(
            providerIdentifier: providerIdentifier,
            rootName: rootName,
            files: Array(byID.values),
            cursor: changes.cursor
        )
    }

    private struct Stored: Codable {
        let version: Int
        let providerIdentifier: String
        let rootName: String
        let files: [RemoteFile]
        let cursor: String?
    }
```

`RemoteFile` must gain `Codable` for this — add it to the declaration in `RemoteLibraryProvider.swift`:
`public struct RemoteFile: Hashable, Sendable, Codable {`

`rootName` is already a stored property from Task 3, which is what lets a reloaded index group loose clips the way the sweep that built it did.

- [ ] **Step 5: Add the change feed to the provider**

In `Sources/SkiVideoCore/GoogleDriveProvider.swift`, conform and implement:

```swift
extension GoogleDriveProvider: IncrementallyEnumerable {
    public func startCursor(forRoot rootID: String) async throws -> String {
        var components = URLComponents(
            string: "https://www.googleapis.com/drive/v3/changes/startPageToken"
        )!
        components.queryItems = [
            URLQueryItem(name: "driveId", value: rootID),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
        ]
        let response: DriveStartPageToken = try await get(components)
        return response.startPageToken
    }

    public func changes(
        since cursor: String, forRoot rootID: String
    ) async throws -> RemoteLibraryChanges {
        var changed: [DriveRecord] = []
        var removed: [String] = []
        var pageToken = cursor
        var nextCursor: String?

        // Drain until Drive hands back the token to resume from next time.
        // Page tokens never expire, so a client that has been closed for
        // months still resyncs in a bounded number of calls.
        while nextCursor == nil {
            var components = URLComponents(
                string: "https://www.googleapis.com/drive/v3/changes"
            )!
            components.queryItems = [
                URLQueryItem(name: "pageToken", value: pageToken),
                // The *drive* log, not the user log: files moved into a shared
                // drive stop appearing in the user log entirely.
                URLQueryItem(name: "driveId", value: rootID),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
                // Without both, a removal never arrives and the sidebar keeps
                // offering clips that are gone.
                URLQueryItem(name: "includeRemoved", value: "true"),
                URLQueryItem(name: "includeCorpusRemovals", value: "true"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(
                    name: "fields",
                    value: "nextPageToken,newStartPageToken,changes(fileId,removed,file(\(Self.changeFileFields)))"
                ),
            ]
            let page: DriveChangeList = try await get(components)
            for change in page.changes {
                if change.removed == true || change.file == nil {
                    removed.append(change.fileId)
                } else if let record = change.file {
                    changed.append(record)
                }
            }
            if let next = page.nextPageToken {
                pageToken = next
            } else {
                nextCursor = page.newStartPageToken
            }
        }

        // A change gives a file id and its parents, not a path. Resolving the
        // folder names needs the tree, which only a sweep has — so a changed
        // file arrives with the parent chain this page could resolve, and a
        // caller wanting more must re-sweep. In practice a new clip's folders
        // are already in the index from the last sweep.
        let folders = Dictionary(
            uniqueKeysWithValues: changed
                .filter { $0.mimeType == Self.folderMimeType }
                .map { ($0.id, $0) }
        )
        return RemoteLibraryChanges(
            changed: changed
                .filter { $0.mimeType != Self.folderMimeType }
                .map { record in
                    RemoteFile(
                        id: record.id,
                        name: record.name,
                        path: Self.folderPath(of: record, in: folders, rootID: rootID),
                        size: Int64(record.size ?? "") ?? 0,
                        contentVersion: record.headRevisionId,
                        md5: record.md5Checksum
                    )
                },
            removed: removed,
            cursor: nextCursor ?? cursor
        )
    }

    static let changeFileFields = "id,name,mimeType,size,md5Checksum,headRevisionId,parents"
}

private struct DriveStartPageToken: Decodable {
    let startPageToken: String
}

private struct DriveChangeList: Decodable {
    struct Change: Decodable {
        let fileId: String
        let removed: Bool?
        let file: DriveRecord?
    }

    let nextPageToken: String?
    let newStartPageToken: String?
    let changes: [Change]
}
```

> The extension above uses `Self.folderMimeType`, which Task 4 declared `private`. Change that single declaration from `private static let folderMimeType` to `static let folderMimeType` so the extension can see it. One constant, one declaration — do not add a second spelling of it.

- [ ] **Step 6: Run the tests**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter "RemoteLibraryIndexTests|GoogleDriveProviderTests"
```
Expected: PASS — 23 index tests, 15 provider tests.

- [ ] **Step 7: Commit**

```bash
git add SkiVideoViewer/Sources/SkiVideoCore/RemoteLibraryIndex.swift \
        SkiVideoViewer/Sources/SkiVideoCore/GoogleDriveProvider.swift \
        SkiVideoViewer/Sources/SkiVideoCore/RemoteLibraryProvider.swift \
        SkiVideoViewer/Tests/SkiVideoCoreTests/RemoteLibraryIndexTests.swift \
        SkiVideoViewer/Tests/SkiVideoCoreTests/GoogleDriveProviderTests.swift
git commit -m "Make a relaunch a delta instead of a sweep

The index persists with the cursor Drive hands back, so the next launch asks
what changed rather than listing the drive again. Page tokens never expire and
the log is coalesced per file, so an app closed for months still resyncs in a
bounded number of calls.

Changes are applied by upsert on the file id, which makes replaying one
harmless and makes a rename move a clip rather than double it. A removal drops
the clip from the library but must never delete cached bytes: Drive reports
lost access and a corpus move exactly as it reports a deletion.

The change feed is a separate protocol because only some providers have one."
```

---

### Task 6: `ClipCache`

**Files:**
- Create: `Sources/SkiVideoCore/ClipCache.swift`
- Test: `Tests/SkiVideoCoreTests/ClipCacheTests.swift`

**Interfaces:**
- Consumes: `RemoteFile`, `DownloadSource`, `ClipIdentity`.
- Produces: `ClipCache` (actor), `ClipDownloader`, `URLSessionClipDownloader`, `ClipCache.cachedURL(for:)`, `materialize(_:source:)`, `pin`/`unpin`, `setBudget`, `evictToFit`. Task 7 consumes these.

- [ ] **Step 1: Write the failing test**

Create `Tests/SkiVideoCoreTests/ClipCacheTests.swift`:

```swift
import XCTest
@testable import SkiVideoCore

/// Writes bytes to the destination without a network, and records what it was
/// asked for — including the headers, which is where the credential lives.
final class FakeClipDownloader: ClipDownloader, @unchecked Sendable {
    var bytesByFileID: [String: Data] = [:]
    var errorToThrow: Error?
    private(set) var requestedFileIDs: [String] = []
    private(set) var lastHeaders: [String: String] = [:]
    /// Blocks each download until `release()` is called, for the coalescing
    /// and cancellation tests.
    var gate: CheckedContinuation<Void, Never>?
    var shouldWait = false

    func download(_ source: DownloadSource, of file: RemoteFile, to destination: URL) async throws {
        requestedFileIDs.append(file.id)
        lastHeaders = source.headers
        if shouldWait {
            await withCheckedContinuation { gate = $0 }
        }
        if let errorToThrow { throw errorToThrow }
        try (bytesByFileID[file.id] ?? Data(repeating: 0, count: Int(file.size)))
            .write(to: destination)
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

final class ClipCacheTests: XCTestCase {
    private var root: URL!
    private var downloader: FakeClipDownloader!
    private var cache: ClipCache!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        downloader = FakeClipDownloader()
        cache = ClipCache(root: root, downloader: downloader, budget: 1_000_000)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ id: String, size: Int64 = 100, md5: String? = nil) -> RemoteFile {
        RemoteFile(id: id, name: "\(id).mp4", path: ["E", "Ada"],
                   size: size, contentVersion: "v1", md5: md5)
    }

    private var source: DownloadSource {
        DownloadSource(url: URL(string: "https://example.invalid/x")!,
                       headers: ["Authorization": "Bearer test"])
    }

    // MARK: - Materialising

    func testAClipIsNotCachedBeforeItIsMaterialised() async {
        let cached = await cache.cachedURL(for: .remote(provider: "gdrive", fileID: "a"))
        XCTAssertNil(cached)
    }

    func testMaterialisingProducesAReadableLocalFile() async throws {
        let url = try await cache.materialize(file("a"), source: source)
        XCTAssertTrue(url.isFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url).count, 100)
    }

    /// The whole point: what AVPlayer opens is an ordinary file, so every
    /// AVAssetReader-based feature works on a cloud clip.
    func testTheCachedURLIsAFileURLWithThePlayableExtension() async throws {
        let url = try await cache.materialize(file("a"), source: source)
        XCTAssertEqual(url.pathExtension, "mp4")
        XCTAssertEqual(url.scheme, "file")
    }

    func testASecondRequestReusesTheCachedFileWithoutDownloadingAgain() async throws {
        _ = try await cache.materialize(file("a"), source: source)
        _ = try await cache.materialize(file("a"), source: source)
        XCTAssertEqual(downloader.requestedFileIDs, ["a"])
    }

    /// A clip whose bytes changed in Drive must be fetched again. The key is
    /// `contentVersion` — `headRevisionId`, which changes only on a content
    /// change, so a rename does not trigger a re-download.
    func testANewContentVersionForcesAFreshDownload() async throws {
        _ = try await cache.materialize(file("a"), source: source)
        let edited = RemoteFile(id: "a", name: "a.mp4", path: ["E", "Ada"],
                                size: 100, contentVersion: "v2", md5: nil)
        _ = try await cache.materialize(edited, source: source)
        XCTAssertEqual(downloader.requestedFileIDs, ["a", "a"])
    }

    func testARenameDoesNotForceAFreshDownload() async throws {
        _ = try await cache.materialize(file("a"), source: source)
        let renamed = RemoteFile(id: "a", name: "a-final.mp4", path: ["E", "Bea"],
                                 size: 100, contentVersion: "v1", md5: nil)
        _ = try await cache.materialize(renamed, source: source)
        XCTAssertEqual(downloader.requestedFileIDs, ["a"])
    }

    /// A file with no content version can never be confirmed current, so it is
    /// re-fetched rather than trusted.
    func testAFileWithNoContentVersionIsNeverReused() async throws {
        let unversioned = RemoteFile(id: "a", name: "a.mp4", path: [],
                                     size: 100, contentVersion: nil, md5: nil)
        _ = try await cache.materialize(unversioned, source: source)
        _ = try await cache.materialize(unversioned, source: source)
        XCTAssertEqual(downloader.requestedFileIDs, ["a", "a"])
    }

    func testTheDownloaderIsGivenTheCredentialHeaders() async throws {
        _ = try await cache.materialize(file("a"), source: source)
        XCTAssertEqual(downloader.lastHeaders["Authorization"], "Bearer test")
    }

    // MARK: - Failure

    func testAFailedDownloadLeavesNothingBehind() async {
        downloader.errorToThrow = RemoteLibraryError.api("network down")
        _ = try? await cache.materialize(file("a"), source: source)

        let cached = await cache.cachedURL(for: .remote(provider: "gdrive", fileID: "a"))
        XCTAssertNil(cached, "a half-written clip must not read as cached")
    }

    /// A truncated download must not be served to AVPlayer as a whole clip.
    func testASizeMismatchIsRejected() async {
        downloader.bytesByFileID["a"] = Data(repeating: 0, count: 50)
        do {
            _ = try await cache.materialize(file("a", size: 100), source: source)
            XCTFail("expected a size mismatch to throw")
        } catch {
            let cached = await cache.cachedURL(for: .remote(provider: "gdrive", fileID: "a"))
            XCTAssertNil(cached)
        }
    }

    // MARK: - Eviction

    func testEvictionDropsTheLeastRecentlyPlayedFirst() async throws {
        await cache.setBudget(250)
        _ = try await cache.materialize(file("a"), source: source)
        _ = try await cache.materialize(file("b"), source: source)
        await cache.recordPlayback(of: .remote(provider: "gdrive", fileID: "a"))
        _ = try await cache.materialize(file("c"), source: source)

        let a = await cache.cachedURL(for: .remote(provider: "gdrive", fileID: "a"))
        let b = await cache.cachedURL(for: .remote(provider: "gdrive", fileID: "b"))
        let c = await cache.cachedURL(for: .remote(provider: "gdrive", fileID: "c"))
        XCTAssertNotNil(a, "a was played most recently")
        XCTAssertNil(b, "b was the least recently used")
        XCTAssertNotNil(c)
    }

    func testAPinnedClipSurvivesEviction() async throws {
        await cache.setBudget(250)
        _ = try await cache.materialize(file("a"), source: source)
        try await cache.pin(.remote(provider: "gdrive", fileID: "a"))
        _ = try await cache.materialize(file("b"), source: source)
        _ = try await cache.materialize(file("c"), source: source)

        let a = await cache.cachedURL(for: .remote(provider: "gdrive", fileID: "a"))
        XCTAssertNotNil(a, "a pinned clip is never evicted")
    }

    func testUnpinningLetsAClipBeEvictedAgain() async throws {
        await cache.setBudget(250)
        _ = try await cache.materialize(file("a"), source: source)
        try await cache.pin(.remote(provider: "gdrive", fileID: "a"))
        await cache.unpin(.remote(provider: "gdrive", fileID: "a"))
        _ = try await cache.materialize(file("b"), source: source)
        _ = try await cache.materialize(file("c"), source: source)

        let a = await cache.cachedURL(for: .remote(provider: "gdrive", fileID: "a"))
        XCTAssertNil(a)
    }

    /// Lowering the budget must take effect immediately, not at the next
    /// download — a coach freeing disk space expects the space back.
    func testLoweringTheBudgetEvictsImmediately() async throws {
        _ = try await cache.materialize(file("a"), source: source)
        _ = try await cache.materialize(file("b"), source: source)
        await cache.setBudget(150)

        let total = await cache.bytesOnDisk()
        XCTAssertLessThanOrEqual(total, 150)
    }

    /// A clip larger than the whole budget must still play. Refusing it would
    /// make the largest clips in the library permanently unopenable.
    func testAClipBiggerThanTheBudgetStillMaterialises() async throws {
        await cache.setBudget(50)
        let url = try await cache.materialize(file("a", size: 100), source: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Coalescing

    func testTwoRequestsForOneClipShareASingleDownload() async throws {
        downloader.shouldWait = true
        async let first = cache.materialize(file("a"), source: source)
        async let second = cache.materialize(file("a"), source: source)

        // Let both reach the actor and coalesce before releasing the gate.
        try await Task.sleep(nanoseconds: 50_000_000)
        downloader.release()

        _ = try await (first, second)
        XCTAssertEqual(downloader.requestedFileIDs, ["a"], "one download, not two")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ClipCacheTests
```
Expected: FAIL to compile — `cannot find 'ClipCache' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SkiVideoCore/ClipCache.swift`:

```swift
import CryptoKit
import Foundation

/// Fetches a clip's bytes to a local file. A seam, so the cache's own tests
/// never reach the network.
public protocol ClipDownloader: Sendable {
    func download(_ source: DownloadSource, of file: RemoteFile, to destination: URL) async throws
}

public struct URLSessionClipDownloader: ClipDownloader {
    private let session: URLSession

    /// A background session so a download survives the app being suspended,
    /// which matters on iPad far more than on a Mac.
    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func download(
        _ source: DownloadSource, of file: RemoteFile, to destination: URL
    ) async throws {
        var request = URLRequest(url: source.url)
        for (field, value) in source.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (temporary, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteLibraryError.api("The download did not return an HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            if !contentType.contains("json") && !contentType.hasPrefix("video") {
                // Drive answers an unauthenticated media request with an HTML
                // block page. Saying so beats "the file is corrupt".
                throw RemoteLibraryError.unexpectedResponseBody(
                    "Downloading \(file.name) returned a \(http.statusCode) web page rather than video."
                )
            }
            throw RemoteLibraryError.api("Downloading \(file.name) failed with HTTP \(http.statusCode).")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}

/// Clips on disk, so `AVPlayer` and `AVAssetReader` only ever see local files.
///
/// An actor because two panes of the comparison window can ask for the same
/// clip at the same moment, and the answer must be one download.
///
/// Whole files, never ranges: the library's clips are 13–61 s and p50 32 MB,
/// so a clip lands in a couple of seconds, and every scrub-heavy and
/// analysis feature in the app needs a complete local file anyway —
/// `AVAssetReader` cannot read a remote source at all.
public actor ClipCache {
    /// One entry per cached clip. `contentVersion` is what decides whether the
    /// bytes on disk are still the bytes in Drive.
    private struct Entry: Codable {
        let fileID: String
        let fileName: String
        let contentVersion: String?
        let bytes: Int64
        var lastUsed: Date
        var isPinned: Bool
    }

    private let root: URL
    private let downloader: ClipDownloader
    private var budget: Int64
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<URL, Error>] = [:]
    private let now: () -> Date

    public init(
        root: URL,
        downloader: ClipDownloader,
        budget: Int64,
        now: @escaping () -> Date = Date.init
    ) {
        self.root = root
        self.downloader = downloader
        self.budget = budget
        self.now = now
        self.entries = Self.loadManifest(at: Self.manifestURL(in: root))
    }

    // MARK: - Reading

    /// The local file for this clip, or nil when it is not on disk. Never
    /// downloads — a caller that wants the clip asks `materialize`.
    public func cachedURL(for identity: ClipIdentity) -> URL? {
        guard case let .remote(_, fileID) = identity,
              let entry = entries[fileID]
        else { return nil }
        let url = fileURL(for: entry)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // The manifest outlived the bytes: iOS may purge Caches, and a
            // coach may empty it by hand. Forget the entry rather than hand
            // back a path to nothing.
            entries.removeValue(forKey: fileID)
            return nil
        }
        return url
    }

    public func bytesOnDisk() -> Int64 {
        entries.values.reduce(0) { $0 + $1.bytes }
    }

    // MARK: - Writing

    /// The clip as a local file, downloading it if it is not already current.
    ///
    /// Concurrent calls for one clip share a single download — the comparison
    /// window asks for two clips at once and can ask for the same one twice.
    public func materialize(_ file: RemoteFile, source: DownloadSource) async throws -> URL {
        if let entry = entries[file.id],
           let version = entry.contentVersion,
           // Nil on either side means "cannot confirm this is current", and
           // an unconfirmable cache is worse than a re-download.
           version == file.contentVersion,
           FileManager.default.fileExists(atPath: fileURL(for: entry).path) {
            entries[file.id]?.lastUsed = now()
            return fileURL(for: entry)
        }

        if let existing = inFlight[file.id] {
            return try await existing.value
        }

        let task = Task<URL, Error> {
            try await fetch(file, source: source)
        }
        inFlight[file.id] = task
        defer { inFlight[file.id] = nil }
        return try await task.value
    }

    private func fetch(_ file: RemoteFile, source: DownloadSource) async throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = fileURL(fileID: file.id, fileName: file.name)
        let scratch = destination.appendingPathExtension("partial")

        do {
            try await downloader.download(source, of: file, to: scratch)
            try verify(scratch, against: file)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: scratch, to: destination)
        } catch {
            // A half-written clip must never read as cached — AVPlayer would
            // open it and show a truncated run.
            try? FileManager.default.removeItem(at: scratch)
            entries.removeValue(forKey: file.id)
            throw error
        }

        entries[file.id] = Entry(
            fileID: file.id, fileName: file.name, contentVersion: file.contentVersion,
            bytes: file.size, lastUsed: now(), isPinned: entries[file.id]?.isPinned ?? false
        )
        evictToFit()
        saveManifest()
        return destination
    }

    /// Checks the bytes landed whole. `md5Checksum` when Drive supplied one;
    /// size otherwise, which is all a caller has for a file without it.
    private func verify(_ url: URL, against file: RemoteFile) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes == file.size else {
            throw RemoteLibraryError.api(
                "\(file.name) downloaded incompletely (\(bytes) of \(file.size) bytes)."
            )
        }
        guard let expected = file.md5 else { return }
        let digest = Insecure.MD5.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw RemoteLibraryError.api("\(file.name) did not download correctly. Try again.")
        }
    }

    // MARK: - Retention

    public func recordPlayback(of identity: ClipIdentity) {
        guard case let .remote(_, fileID) = identity else { return }
        entries[fileID]?.lastUsed = now()
        saveManifest()
    }

    public func pin(_ identity: ClipIdentity) throws {
        guard case let .remote(_, fileID) = identity, entries[fileID] != nil else { return }
        entries[fileID]?.isPinned = true
        saveManifest()
    }

    public func unpin(_ identity: ClipIdentity) {
        guard case let .remote(_, fileID) = identity else { return }
        entries[fileID]?.isPinned = false
        evictToFit()
        saveManifest()
    }

    public func setBudget(_ bytes: Int64) {
        budget = bytes
        // Immediately, not at the next download: a coach freeing disk space
        // expects the space back now.
        evictToFit()
        saveManifest()
    }

    /// Drops least-recently-used clips until the total fits the budget.
    ///
    /// Never evicts a pinned clip, and never refuses to keep a clip larger
    /// than the whole budget — the biggest clips in the library would
    /// otherwise become permanently unopenable.
    public func evictToFit() {
        var total = bytesOnDisk()
        guard total > budget else { return }
        let candidates = entries.values
            .filter { !$0.isPinned }
            .sorted { $0.lastUsed < $1.lastUsed }
        for entry in candidates {
            guard total > budget, entries.count > 1 else { break }
            try? FileManager.default.removeItem(at: fileURL(for: entry))
            entries.removeValue(forKey: entry.fileID)
            total -= entry.bytes
        }
    }

    // MARK: - Layout

    /// Named by a digest of the file id, not by the clip's name: a rename in
    /// Drive then costs nothing, and two clips sharing a name cannot collide.
    /// See `StorageName` for why a digest. The extension is kept because
    /// `AVURLAsset` reads it as a type hint.
    private func fileURL(fileID: String, fileName: String) -> URL {
        let extensionOnly = URL(fileURLWithPath: fileName).pathExtension
        return root
            .appendingPathComponent(StorageName.forIdentifier(fileID))
            .appendingPathExtension(extensionOnly.isEmpty ? "mp4" : extensionOnly)
    }

    private func fileURL(for entry: Entry) -> URL {
        fileURL(fileID: entry.fileID, fileName: entry.fileName)
    }

    private static func manifestURL(in root: URL) -> URL {
        root.appendingPathComponent("clips.skicache.json")
    }

    private static func loadManifest(at url: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return entries
    }

    private func saveManifest() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: Self.manifestURL(in: root), options: .atomic)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ClipCacheTests
```
Expected: PASS, 17 tests.

- [ ] **Step 5: Commit**

```bash
git add SkiVideoViewer/Sources/SkiVideoCore/ClipCache.swift \
        SkiVideoViewer/Tests/SkiVideoCoreTests/ClipCacheTests.swift
git commit -m "Put a cloud clip on disk so the rest of the app cannot tell

AVPlayer and AVAssetReader only ever see a file:// URL, which is what makes
frame stepping, overlay compare and pose analysis work on a clip that came from
Drive — AVAssetReader cannot read a remote source at all, so this is a
precondition rather than an optimisation.

Cache validity is headRevisionId, which changes only when the bytes do, so a
rename costs nothing while an edit re-downloads. Eviction is least-recently-
played against a budget, never touching a pinned clip and never refusing a clip
larger than the whole budget, which would make the biggest runs unopenable.
Concurrent requests for one clip share one download, because the comparison
window asks for two clips at once."
```

---

### Task 7: Wire it into `ViewerModel` and delete the old client

**Files:**
- Modify: `Sources/SkiVideoCore/ViewerModel.swift`
- Delete: `Sources/SkiVideoCore/GoogleDriveSupport.swift`
- Test: `Tests/SkiVideoCoreTests/RemoteLibraryWiringTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: `ViewerModel.openRemoteLibrary(provider:root:)`, `ViewerModel.isPreparingClip`, and a `currentPlaybackURL` that resolves through the cache.

`GoogleDriveSupport.swift` should be empty after Task 2 removed the OAuth code and this task removes `DriveMedia`, `DriveLibrary` and `GoogleDriveClient`. Delete the file. `DriveError` already lives in `GoogleOAuth.swift`.

- [ ] **Step 1: Write the failing test**

Create `Tests/SkiVideoCoreTests/RemoteLibraryWiringTests.swift`:

```swift
import XCTest
@testable import SkiVideoCore

@MainActor
final class RemoteLibraryWiringTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func model(files: [RemoteFile]) -> (ViewerModel, FakeRemoteProvider, ClipCache) {
        let provider = FakeRemoteProvider(files: files)
        let cache = ClipCache(root: root, downloader: FakeClipDownloader(), budget: 1_000_000)
        let model = ViewerModel(
            input: FakeInputSource(),
            folderPicker: FakeFolderPicker(),
            oauthPresenter: FakeOAuthPresenter()
        )
        return (model, provider, cache)
    }

    private func file(_ id: String, _ name: String, _ path: [String]) -> RemoteFile {
        RemoteFile(id: id, name: name, path: path, size: 100, contentVersion: "v1", md5: nil)
    }

    func testOpeningARemoteLibraryFillsTheSidebar() async throws {
        let (model, provider, cache) = self.model(files: [
            file("a", "run1.mp4", ["Neuss 2026", "Ada"]),
            file("b", "run1.mp4", ["Neuss 2026", "Bea"]),
        ])

        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )

        XCTAssertEqual(model.athletes.map(\.name), ["Ada", "Bea"])
        XCTAssertEqual(model.athletes.map(\.event), ["Neuss 2026", "Neuss 2026"])
    }

    /// The heart of this plan: what playback receives is an ordinary file, not
    /// an HTTPS URL with a token in it.
    func testThePlaybackURLIsALocalFileNotARemoteURL() async throws {
        let (model, provider, cache) = self.model(files: [
            file("a", "run1.mp4", ["Neuss 2026", "Ada"]),
        ])
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )

        try await model.prepareCurrentClip()

        let url = try XCTUnwrap(model.currentPlaybackURL)
        XCTAssertTrue(url.isFileURL, "got \(url)")
        XCTAssertFalse(url.absoluteString.contains("access_token"))
        XCTAssertFalse(url.absoluteString.contains("googleapis.com"))
    }

    /// Before the bytes land there is nothing to play. The model must say it
    /// is working rather than hand back a URL to a file that is not there.
    func testAClipNotYetOnDiskReportsThatItIsBeingPrepared() async throws {
        let (model, provider, cache) = self.model(files: [
            file("a", "run1.mp4", ["Neuss 2026", "Ada"]),
        ])
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )

        XCTAssertNil(model.currentPlaybackURL)
        try await model.prepareCurrentClip()
        XCTAssertNotNil(model.currentPlaybackURL)
    }

    /// A local library must keep working exactly as before — its URLs are
    /// already files and must not be routed through the cache.
    func testALocalLibraryStillPlaysDirectlyFromItsOwnFiles() throws {
        let directory = root.appendingPathComponent("Neuss/Ada", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clip = directory.appendingPathComponent("run1.mp4")
        try Data().write(to: clip)

        let (model, _, _) = self.model(files: [])
        model.openDirectory(root)

        XCTAssertEqual(model.currentPlaybackURL, clip)
    }

    /// The comparison window gets the same treatment — a pane must never be
    /// handed a remote URL.
    func testTheComparisonPickerOffersOnlyLocalURLs() async throws {
        let (model, provider, cache) = self.model(files: [
            file("a", "run1.mp4", ["Neuss 2026", "Ada"]),
        ])
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )
        try await model.prepareCurrentClip()

        let choice = try XCTUnwrap(model.comparisonLibrary.first?.videos.first)
        XCTAssertTrue(choice.playbackURL.isFileURL, "got \(choice.playbackURL)")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter RemoteLibraryWiringTests
```
Expected: FAIL to compile — `value of type 'ViewerModel' has no member 'openRemoteLibrary'`.

- [ ] **Step 3: Change `ViewerModel`**

Replace the Drive members. Remove `driveMediaByURL`, `driveFolderID`, `clientSecretsPath`, `isConnectingToDrive`, `chooseClientSecretsFile()` and `connectGoogleDrive()` — the sheet that drove them is replaced in plan 3, and `ContentView` must be updated in this task to stop referencing them.

Add:

```swift
    /// The cloud library, when one is open. Nil for a local folder.
    private var remoteIndex: RemoteLibraryIndex?
    private var remoteProvider: (any RemoteLibraryProvider)?
    private var clipCache: ClipCache?

    @Published public private(set) var isUsingRemoteLibrary = false
    /// True while the current clip's bytes are being fetched. The view shows
    /// progress instead of an empty player.
    @Published public private(set) var isPreparingClip = false

    /// Opens a cloud library: index it, group it, show it. No bytes are
    /// fetched — a clip downloads when it is selected.
    public func openRemoteLibrary(
        provider: any RemoteLibraryProvider,
        root: RemoteFolder,
        cache: ClipCache
    ) async throws {
        status = "Listing \(root.name)…"
        var files: [RemoteFile] = []
        for try await file in provider.enumerate(root) {
            files.append(file)
        }
        let index = RemoteLibraryIndex(
            providerIdentifier: type(of: provider).identifier,
            rootName: root.name,
            files: files
        )
        guard !index.athletes.isEmpty else { throw ViewerError.noVideos }

        endSlowMotion()
        player.pause()
        directory = nil
        remoteIndex = index
        remoteProvider = provider
        clipCache = cache
        isUsingRemoteLibrary = true
        athletes = index.athletes
        activeAthleteID = nil
        selectedAthleteID = index.athletes[0].id
        athleteQuery = ""
        zoom.reset()
        selectAthlete(index.athletes[0].id)
        status = "\(root.name) — \(files.count) clips"
    }

    /// Brings the selected clip's bytes to disk, so playback and analysis have
    /// a real file. A no-op for a local library.
    public func prepareCurrentClip() async throws {
        guard let currentVideo,
              let remoteIndex, let remoteProvider, let clipCache,
              let file = remoteIndex.file(for: currentVideo)
        else { return }

        isPreparingClip = true
        defer { isPreparingClip = false }
        status = "Fetching \(file.name)…"
        let source = try await remoteProvider.downloadSource(for: file)
        _ = try await clipCache.materialize(file, source: source)
        await clipCache.recordPlayback(
            of: file.identity(inProvider: remoteIndex.providerIdentifier)
        )
        status = file.name
    }
```

Change `currentPlaybackURL` (`ViewerModel.swift:176-179`) to resolve through the cache:

```swift
    /// What playback opens. A local library's URLs are already files; a cloud
    /// library's resolve to whatever the cache holds, and to nil until the
    /// bytes land — there is nothing to play before then, and handing back a
    /// path to a missing file would show an error instead of progress.
    public var currentPlaybackURL: URL? {
        guard let currentVideo else { return nil }
        guard let remoteIndex, let file = remoteIndex.file(for: currentVideo) else {
            return currentVideo
        }
        return cachedRemoteURL(for: file)
    }
```

`cachedRemoteURL` needs a synchronous answer from an actor, which it cannot have. Keep a plain dictionary of what has already been materialised, written by `prepareCurrentClip`:

```swift
    /// Mirrors the cache for synchronous reads. `currentPlaybackURL` and
    /// `comparisonLibrary` are computed properties a SwiftUI view reads
    /// directly, so neither can await an actor.
    private var materialisedByFileID: [String: URL] = [:]

    private func cachedRemoteURL(for file: RemoteFile) -> URL? {
        materialisedByFileID[file.id]
    }
```

and in `prepareCurrentClip`, after `materialize` returns:
```swift
        materialisedByFileID[file.id] = try await clipCache.materialize(file, source: source)
```

Change `comparisonLibrary` (`:181-199`) the same way: a remote clip's `playbackURL` is `materialisedByFileID[file.id] ?? video`, and the comparison window prepares a clip before loading it (plan 3 wires that button; for now the test drives `prepareCurrentClip`).

Clear all three on `openDirectory`: `remoteIndex = nil`, `remoteProvider = nil`, `clipCache = nil`, `materialisedByFileID = [:]`, `isUsingRemoteLibrary = false`.

- [ ] **Step 4: Delete the old client**

`Sources/SkiVideoCore/GoogleDriveSupport.swift` now holds only `DriveMedia`, `DriveLibrary` and `GoogleDriveClient`, all unreferenced. Delete the file.

```bash
git rm SkiVideoViewer/Sources/SkiVideoCore/GoogleDriveSupport.swift
grep -rn "DriveMedia\|GoogleDriveClient\|DriveLibrary\|driveMediaByURL\|connectGoogleDrive\|clientSecretsPath\|driveFolderID" Sources/ Tests/
```
Expected: the grep prints nothing. Update `ContentView.swift` and `GoogleDriveSheet.swift` if they still reference the removed members — the sheet is replaced wholesale in plan 3, so for now reduce it to a placeholder that says sign-in is not yet wired, rather than deleting a view `ContentView` presents.

- [ ] **Step 5: Run the full suite**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -5
```
Expected: green. Any pre-existing Drive test that no longer compiles should be **deleted with its subject**, not rewritten to pass — say so in the report.

- [ ] **Step 6: Commit**

```bash
git add -A SkiVideoViewer/Sources SkiVideoViewer/Tests
git commit -m "Play a cloud clip from disk, and delete the client that could not

The seam was already in the right place: a library URL resolved to a playback
URL through a dictionary. It pointed at an HTTPS URL with a token in it, which
Drive refuses on the media path and which AVAssetReader could never have read.
It now points at a cached file, so comparison, overlay, frame stepping and pose
analysis all work on a Drive clip without knowing one is involved.

The old client goes with it. Its recursive walk, its query-string credential
and its synthesised URLs are all replaced rather than repaired."
```

---

## Definition of done

- [ ] `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` passes in full.
- [ ] No test reaches the network: `grep -rn "URLSessionTransport()\|URLSessionClipDownloader()" Tests/` prints nothing.
- [ ] No test writes to the real Application Support or Caches directory.
- [ ] No pre-existing test was edited to accommodate a change.
- [ ] `CorePurityTests` passes.
- [ ] `grep -rn "access_token" Sources/` prints nothing.
- [ ] The 10 pre-existing warnings are unchanged in count and location; no new ones in the files this plan touches.
- [ ] A local library behaves exactly as before.

## What this plan deliberately does not do

- **Sign-in.** `GoogleDriveProvider.connect` throws `.notSignedIn`. Plan 3 owns the two OAuth client registrations, `ASWebAuthenticationSession`, the loopback-versus-custom-scheme split, and the Shared Drive picker. Until then the provider takes a token closure.
- **Prefetch.** Clips materialise on demand only. Plan 3 adds the next-two-and-previous-one policy and the compare partner.
- **Pinning UI.** `ClipCache.pin` exists and is tested; nothing calls it yet.
- **Writing analysis back to Drive.** Out of scope in the spec, and this plan adds no write scope.
- **The `-` join in `ClipIdentity.pairKey`.** Carried deliberately from plan 1: the obvious fix would be a regression, because Drive ids are base64url and legitimately contain both `-` and `_`. The invariant is documented there.
