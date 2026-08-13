# Clip Identity and Analysis Stores Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give clips an identity independent of their file path, so analysis and alignment results have somewhere to live for clips that are not local files.

**Architecture:** A `ClipIdentity` enum with two cases — `.local(URL)` and `.remote(provider:fileID:)`. `ClipAnalysisStore` and `AlignmentTrackStore` gain identity-taking entry points. Local clips keep writing sidecars beside the footage exactly as today, byte for byte; identities without a folder of their own resolve to a keyed store under Application Support. The existing URL-taking methods stay as thin wrappers so the ~30 call sites in the test suite do not churn.

**Tech Stack:** Swift 6.1 toolchain, SwiftPM, XCTest. No new dependencies.

This is plan 1 of 3 from `docs/superpowers/specs/2026-08-13-cloud-video-library-design.md`. It is deliberately self-contained: nothing here imports a network, and the cloud work in plans 2 and 3 consumes `ClipIdentity` without modifying it.

## Global Constraints

- **Test command is not plain `swift test`.** `xcode-select -p` points at `/Library/Developer/CommandLineTools`, which has no XCTest module, so `swift test` fails with `error: no such module 'XCTest'` before running anything. Every test command in this plan is prefixed:
  `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test …`
  Verified working 2026-08-13 (5 tests passed under `--filter ClipAnalysisStoreTests`).
- **Run all commands from `/Users/ulfnielsen/Ski/script/SkiVideoViewer`.** The git root is one level up at `/Users/ulfnielsen/Ski/script`, so `git add` paths in commit steps are written relative to the repo root.
- **`Sources/SkiVideoCore` may not contain `import AppKit`, `import UIKit`, `import SwiftUI`, or `Process(`.** Enforced by `CorePurityTests.testCoreSourcesAvoidPlatformSpecificAPIs`. Foundation is fine.
- **Swift language mode is v5** (`Package.swift`, `swiftLanguageModes: [.v5]`), so a mutable `static var` does not raise a concurrency error. Do not add `@MainActor` or `nonisolated(unsafe)` to work around something that is not being diagnosed.
- **Platforms: macOS 13, iOS 17.**
- **Existing local behaviour must not change.** Sidecar names, locations, encoder settings and the "unreadable reads as absent" rule all stay. The existing tests are the specification; none of them should need editing.

## File Structure

| File | Responsibility |
| --- | --- |
| Create `Sources/SkiVideoCore/ClipIdentity.swift` | The `ClipIdentity` enum, its filesystem-safe key, and the Application Support root for keyed sidecars |
| Modify `Sources/SkiVideoCore/ClipAnalysisStore.swift` | Identity-taking `load`/`save`; URL-taking versions delegate |
| Modify `Sources/SkiVideoCore/AlignmentTrackStore.swift` | Same, for clip *pairs*, including the mixed-pair rule |
| Modify `Sources/SkiVideoCore/SubjectSessionModel.swift:73,163` | Call through identity |
| Modify `Sources/SkiVideoCore/AlignmentSessionModel.swift:158,220` | Call through identity |
| Create `Tests/SkiVideoCoreTests/ClipIdentityTests.swift` | Key stability, escaping, equality |
| Modify `Tests/SkiVideoCoreTests/ClipAnalysisStoreTests.swift` | Add remote-identity cases; leave existing cases untouched |
| Modify `Tests/SkiVideoCoreTests/AlignmentTrackTests.swift` | Add remote and mixed-pair cases |

---

### Task 1: `ClipIdentity`

**Files:**
- Create: `Sources/SkiVideoCore/ClipIdentity.swift`
- Test: `Tests/SkiVideoCoreTests/ClipIdentityTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ClipIdentity` (`.local(URL)`, `.remote(provider: String, fileID: String)`), `ClipIdentity.init(_ clip: URL)`, `ClipIdentity.storeKey: String?`, `ClipIdentity.keyedStoreRoot: URL` (settable static).

- [ ] **Step 1: Write the failing test**

Create `Tests/SkiVideoCoreTests/ClipIdentityTests.swift`:

```swift
import XCTest
@testable import SkiVideoCore

final class ClipIdentityTests: XCTestCase {
    func testLocalIdentityHasNoStoreKey() {
        // A local clip's analysis sits beside the footage, so it never needs a
        // key. Nil is the signal that the keyed store does not apply.
        let identity = ClipIdentity(URL(fileURLWithPath: "/tmp/Anna/run1.mp4"))
        XCTAssertNil(identity.storeKey)
    }

    func testLocalIdentityStandardisesItsURL() {
        // Two spellings of one path must be one identity, or a clip opened via
        // a trailing-slash or dot component would get a second sidecar.
        XCTAssertEqual(
            ClipIdentity(URL(fileURLWithPath: "/tmp/Anna/./run1.mp4")),
            ClipIdentity(URL(fileURLWithPath: "/tmp/Anna/run1.mp4"))
        )
    }

    func testRemoteIdentityKeyJoinsProviderAndFileID() {
        let identity = ClipIdentity.remote(provider: "gdrive", fileID: "1AbC")
        XCTAssertEqual(identity.storeKey, "gdrive-1AbC")
    }

    func testRemoteIdentityKeyEscapesPathSeparators() {
        // Drive ids are URL-safe base64 today, but nothing in this type may
        // assume that: a "/" reaching the filename would silently write into a
        // sibling directory, or fail.
        let identity = ClipIdentity.remote(provider: "gdrive", fileID: "a/b..c")
        let key = try! XCTUnwrap(identity.storeKey)
        XCTAssertFalse(key.contains("/"))
        XCTAssertFalse(key.contains(".."))
    }

    func testRemoteIdentitiesDifferingOnlyByProviderDoNotCollide() {
        XCTAssertNotEqual(
            ClipIdentity.remote(provider: "gdrive", fileID: "x").storeKey,
            ClipIdentity.remote(provider: "dropbox", fileID: "x").storeKey
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ClipIdentityTests
```
Expected: FAIL to compile, `cannot find 'ClipIdentity' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SkiVideoCore/ClipIdentity.swift`:

```swift
import CryptoKit
import Foundation

/// What a clip *is*, independent of where its bytes currently sit.
///
/// A local clip is its standardised file URL, which is what every store in
/// this module keyed on before cloud libraries existed. A remote clip has no
/// path at all — only the provider that owns it and that provider's stable
/// file id — so anything derived from it has to be keyed rather than placed.
public enum ClipIdentity: Hashable, Sendable {
    case local(URL)
    case remote(provider: String, fileID: String)

    /// The identity of a clip the app already holds as a file.
    ///
    /// Standardised, so `/a/./b.mp4` and `/a/b.mp4` are one identity rather
    /// than two sidecars.
    public init(_ clip: URL) {
        self = .local(clip.standardizedFileURL)
    }

    /// A filesystem-safe name for this identity in the keyed store, or nil
    /// when the identity has a folder of its own and needs no key.
    ///
    /// Nil for `.local` is deliberate and load-bearing: it is how the stores
    /// tell "put this beside the footage" from "put this in the keyed store",
    /// rather than each of them re-matching on the case.
    public var storeKey: String? {
        switch self {
        case .local: return nil
        case .remote: return pairKey
        }
    }

    /// A filesystem-safe name for this identity that is safe to *combine* with
    /// another into one filename.
    ///
    /// Defined for local identities too, unlike `storeKey`, because a pair can
    /// straddle the two: comparing a cloud clip against one on disk files the
    /// track under both halves.
    ///
    /// The local half is a digest of the path, not an escaped copy of it.
    /// Escaping is lossy — every character outside `[A-Za-z0-9-]` becomes `_`,
    /// so `/Ski Team 2026/run.mp4` and `/Ski_Team_2026/run.mp4` would name the
    /// same file and one alignment track would silently overwrite the other's.
    /// A digest also bounds the length, which an escaped absolute path does
    /// not: a deep path can exceed a filesystem's 255-byte name limit.
    public var pairKey: String {
        switch self {
        case let .local(clip):
            let digest = SHA256.hash(data: Data(clip.path.utf8))
            return "local-" + digest.prefix(8)
                .map { String(format: "%02x", $0) }
                .joined()
        case let .remote(provider, fileID):
            return "\(Self.escape(provider))-\(Self.escape(fileID))"
        }
    }

    /// Anything that is not unreserved-URL-safe becomes an underscore.
    ///
    /// Drive's file ids are URL-safe base64 today and would survive
    /// unescaped, but a key is a *filename*: one "/" in an id that a future
    /// provider hands back would write outside the store, and ".." would climb
    /// out of it. Escaping here costs nothing and removes the question.
    private static func escape(_ value: String) -> String {
        String(value.map { character in
            character.isLetter || character.isNumber || character == "-"
                ? character
                : "_"
        })
    }

    /// Where keyed sidecars live.
    ///
    /// A `var` so tests can point it at a temporary directory; nothing in the
    /// app writes to it. Application Support rather than Caches because an
    /// analysis is minutes of computation over a clip that may no longer be
    /// cached, and losing it to a cache purge would be a bad trade.
    public static var keyedStoreRoot: URL = defaultKeyedStoreRoot()

    private static func defaultKeyedStoreRoot() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("SkiVideoViewer", isDirectory: true)
            .appendingPathComponent("ClipAnalysis", isDirectory: true)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ClipIdentityTests
```
Expected: PASS, 5 tests.

- [ ] **Step 5: Confirm core purity still holds**

Run:
```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter CorePurityTests
```
Expected: PASS. (`ClipIdentity.swift` imports only Foundation, but this test scans every file in the directory, so it is the cheap guard against a stray import arriving with a later edit.)

- [ ] **Step 6: Commit**

```bash
git add SkiVideoViewer/Sources/SkiVideoCore/ClipIdentity.swift \
        SkiVideoViewer/Tests/SkiVideoCoreTests/ClipIdentityTests.swift
git commit -m "Give a clip an identity that does not depend on a path

A remote clip has no folder to keep its analysis in, so the stores need
something to key on that a file URL cannot provide. Local identities return a
nil store key, which is how the stores tell 'beside the footage' from 'in the
keyed store' without re-matching the case in each of them."
```

---

### Task 2: `ClipAnalysisStore` accepts an identity

**Files:**
- Modify: `Sources/SkiVideoCore/ClipAnalysisStore.swift`
- Test: `Tests/SkiVideoCoreTests/ClipAnalysisStoreTests.swift`

**Interfaces:**
- Consumes: `ClipIdentity`, `ClipIdentity.storeKey`, `ClipIdentity.keyedStoreRoot` from Task 1.
- Produces: `ClipAnalysisStore.load(for: ClipIdentity) -> ClipAnalysis?`, `ClipAnalysisStore.save(_ analysis: ClipAnalysis, for: ClipIdentity) throws`, `ClipAnalysisStore.sidecarURL(for: ClipIdentity) -> URL`. The existing `load(for: URL)`, `save(_:for: URL)` and `sidecarURL(for: URL)` keep their exact signatures and behaviour.

- [ ] **Step 1: Write the failing test**

Append to `Tests/SkiVideoCoreTests/ClipAnalysisStoreTests.swift`, inside the existing `final class`. Do not edit the tests already there — they are the specification for local behaviour and must keep passing untouched.

```swift
    // MARK: - Identity-keyed storage

    /// Points the keyed store at a temporary directory for one test and puts
    /// it back afterwards, so a test run never writes into real Application
    /// Support and two tests cannot see each other's sidecars.
    private func withTemporaryKeyedStore(_ body: (URL) throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let previous = ClipIdentity.keyedStoreRoot
        ClipIdentity.keyedStoreRoot = root
        defer {
            ClipIdentity.keyedStoreRoot = previous
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }

    // `withTemporaryKeyedStore` is `rethrows`, so a test whose closure calls
    // nothing throwing must omit both `try` and `throws` — otherwise the
    // compiler warns "no calls to throwing functions occur within 'try'".
    func testRemoteSidecarLivesInTheKeyedStoreUnderItsKey() {
        withTemporaryKeyedStore { root in
            let identity = ClipIdentity.remote(provider: "gdrive", fileID: "1AbC")
            let url = ClipAnalysisStore.sidecarURL(for: identity)
            XCTAssertEqual(url.deletingLastPathComponent().path, root.path)
            XCTAssertEqual(url.lastPathComponent, "gdrive-1AbC.skianalysis.json")
        }
    }

    func testRemoteAnalysisRoundTrips() throws {
        try withTemporaryKeyedStore { _ in
            let identity = ClipIdentity.remote(provider: "gdrive", fileID: "1AbC")
            try ClipAnalysisStore.save(sample, for: identity)
            XCTAssertEqual(ClipAnalysisStore.load(for: identity)?.parameters.fps, 25)
        }
    }

    /// The store directory does not exist on a fresh install. Saving has to
    /// create it rather than throw, or the first analysis a coach ever runs on
    /// a cloud clip is lost.
    func testSavingRemoteAnalysisCreatesTheStoreDirectory() throws {
        try withTemporaryKeyedStore { root in
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
            try ClipAnalysisStore.save(
                sample, for: .remote(provider: "gdrive", fileID: "1AbC")
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        }
    }

    func testMissingRemoteAnalysisReadsAsAbsent() {
        withTemporaryKeyedStore { _ in
            XCTAssertNil(
                ClipAnalysisStore.load(for: .remote(provider: "gdrive", fileID: "nope"))
            )
        }
    }

    /// Two providers that happen to issue the same file id must not share a
    /// sidecar.
    func testRemoteAnalysisIsScopedToItsProvider() throws {
        try withTemporaryKeyedStore { _ in
            try ClipAnalysisStore.save(
                sample, for: .remote(provider: "gdrive", fileID: "shared")
            )
            XCTAssertNil(
                ClipAnalysisStore.load(for: .remote(provider: "dropbox", fileID: "shared"))
            )
        }
    }

    /// The URL-taking API is the identity-taking one with `.local` supplied —
    /// not a second implementation that could drift from it.
    func testLocalIdentityResolvesToTheSameSidecarAsTheURLAPI() {
        XCTAssertEqual(
            ClipAnalysisStore.sidecarURL(for: ClipIdentity(clip())),
            ClipAnalysisStore.sidecarURL(for: clip())
        )
    }
```

> The existing suite already provides everything these tests use: `clip(_:)` at
> line 18 (a method with a default name), `sample` at line 21 (a computed
> property), and a per-test `directory` from `setUpWithError`. Do not redeclare
> any of them.

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ClipAnalysisStoreTests
```
Expected: FAIL to compile — `cannot convert value of type 'ClipIdentity' to expected argument type 'URL'`.

- [ ] **Step 3: Write minimal implementation**

Replace the body of `Sources/SkiVideoCore/ClipAnalysisStore.swift` between `public static let fileExtension` and the private `encoder`, keeping the file's existing doc comment at the top:

```swift
    public static let fileExtension = "skianalysis.json"

    /// Where this identity's analysis is written.
    ///
    /// A local clip's sidecar sits beside the footage, which is the whole
    /// reason this store exists in this shape: copy an athlete's folder to
    /// another machine and the analysis travels with it. An identity with no
    /// folder of its own falls back to the keyed store.
    public static func sidecarURL(for identity: ClipIdentity) -> URL {
        switch identity {
        case let .local(clip):
            return clip.deletingPathExtension().appendingPathExtension(fileExtension)
        case .remote:
            // Non-nil for every case that reaches here; `.local` returned above.
            let key = identity.storeKey ?? "unkeyed"
            return ClipIdentity.keyedStoreRoot
                .appendingPathComponent(key)
                .appendingPathExtension(fileExtension)
        }
    }

    public static func sidecarURL(for clip: URL) -> URL {
        sidecarURL(for: ClipIdentity(clip))
    }

    /// The stored analysis, or nil when there is none or it cannot be read.
    ///
    /// An unreadable sidecar reads as absent rather than as an error: it may be
    /// a newer version or hand-edited, and the caller's only sensible response
    /// is to offer analysis again. `save` must never overwrite one it could not
    /// parse — see its note.
    public static func load(for identity: ClipIdentity) -> ClipAnalysis? {
        guard let data = try? Data(contentsOf: sidecarURL(for: identity)) else { return nil }
        return try? decoder.decode(ClipAnalysis.self, from: data)
    }

    public static func load(for clip: URL) -> ClipAnalysis? {
        load(for: ClipIdentity(clip))
    }

    /// Writes the sidecar, throwing if it cannot. Callers surface the failure
    /// to the operator once and carry on using the analysis in memory — an
    /// unwritable footage folder is a persistence problem, not an analysis
    /// failure.
    public static func save(_ analysis: ClipAnalysis, for identity: ClipIdentity) throws {
        let url = sidecarURL(for: identity)
        // Only the keyed store can be missing. A local clip's folder exists by
        // definition — the clip is in it — and creating directories under a
        // footage folder is not this store's business.
        if identity.storeKey != nil {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        }
        try encoder.encode(analysis).write(to: url, options: .atomic)
    }

    public static func save(_ analysis: ClipAnalysis, for clip: URL) throws {
        try save(analysis, for: ClipIdentity(clip))
    }
```

- [ ] **Step 4: Run the whole store suite**

Run:
```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ClipAnalysisStoreTests
```
Expected: PASS — the 5 pre-existing tests plus the 6 new ones, 11 total. If any pre-existing test now fails, local behaviour has changed and the implementation is wrong; do not edit the old test to match.

- [ ] **Step 5: Run every suite that touches this store**

Run:
```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -20
```
Expected: PASS. `SubjectSessionModelTests`, `ClipAnalysisTests`, `SubjectSyncEndToEndTests`, `CorrectedStartWiringTests`, `StoredRunStartReuseTests` and `StoredRunStartReuseEndToEndTests` all call this store through the URL API and must be unaffected.

- [ ] **Step 6: Commit**

```bash
git add SkiVideoViewer/Sources/SkiVideoCore/ClipAnalysisStore.swift \
        SkiVideoViewer/Tests/SkiVideoCoreTests/ClipAnalysisStoreTests.swift
git commit -m "Give a clip analysis somewhere to live when there is no folder

A clip streamed from a provider has no directory to sit a sidecar in, so the
store now resolves an identity rather than a path. Local clips are untouched:
the URL API is the identity API with .local supplied, so the two cannot drift."
```

---

### Task 3: `AlignmentTrackStore` accepts identities, including mixed pairs

**Files:**
- Modify: `Sources/SkiVideoCore/AlignmentTrackStore.swift`
- Test: `Tests/SkiVideoCoreTests/AlignmentTrackTests.swift`

**Interfaces:**
- Consumes: `ClipIdentity` from Task 1.
- Produces: `AlignmentTrackStore.load(left: ClipIdentity, right: ClipIdentity) -> AlignmentTrack?`, `AlignmentTrackStore.save(_:left: ClipIdentity, right: ClipIdentity) throws`, `AlignmentTrackStore.sidecarURL(left: ClipIdentity, right: ClipIdentity) -> URL`. URL-taking versions keep their exact signatures.

The rule that is new here, because comparison can straddle libraries: a pair sits beside the **left** clip only when **both** sides are local. Any pair with a remote side goes to the keyed store, named from both keys.

- [ ] **Step 1: Write the failing test**

Append to the existing `final class` in `Tests/SkiVideoCoreTests/AlignmentTrackTests.swift`:

```swift
    // MARK: - Identity-keyed pairs

    private func withTemporaryKeyedStore(_ body: (URL) throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let previous = ClipIdentity.keyedStoreRoot
        ClipIdentity.keyedStoreRoot = root
        defer {
            ClipIdentity.keyedStoreRoot = previous
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }

    // `withTemporaryKeyedStore` is `rethrows`, so a test whose closure calls
    // nothing throwing must omit both `try` and `throws` — otherwise the
    // compiler warns "no calls to throwing functions occur within 'try'".
    func testRemotePairLivesInTheKeyedStoreNamedFromBothSides() {
        withTemporaryKeyedStore { root in
            let url = AlignmentTrackStore.sidecarURL(
                left: .remote(provider: "gdrive", fileID: "L"),
                right: .remote(provider: "gdrive", fileID: "R")
            )
            XCTAssertEqual(url.deletingLastPathComponent().path, root.path)
            XCTAssertEqual(url.lastPathComponent, "gdrive-L--gdrive-R.skialignment.json")
        }
    }

    /// A coach can compare a cloud clip against one on disk. That pair has no
    /// business beside the local clip — the track would be orphaned the moment
    /// the folder moved, and half of it describes a file that folder never
    /// held.
    func testMixedPairGoesToTheKeyedStoreRatherThanBesideTheLocalClip() {
        withTemporaryKeyedStore { root in
            let url = AlignmentTrackStore.sidecarURL(
                left: ClipIdentity(directory.appendingPathComponent("C0094.MP4")),
                right: .remote(provider: "gdrive", fileID: "R")
            )
            XCTAssertEqual(url.deletingLastPathComponent().path, root.path)
        }
    }

    /// Two local clips whose paths differ only by characters that a lossy
    /// escaping would fold together must not name the same sidecar. Paired
    /// against the same remote clip they both land in the keyed store, and a
    /// collision there means one coach's alignment silently overwrites
    /// another's — no error, no warning, just the wrong track.
    func testLocalPathsThatFoldAlikeDoNotShareAKeyedSidecar() {
        withTemporaryKeyedStore { _ in
            let remote = ClipIdentity.remote(provider: "gdrive", fileID: "R")
            let spaced = ClipIdentity(URL(fileURLWithPath: "/Ski Team 2026/run.mp4"))
            let scored = ClipIdentity(URL(fileURLWithPath: "/Ski_Team_2026/run.mp4"))
            XCTAssertNotEqual(
                AlignmentTrackStore.sidecarURL(left: spaced, right: remote),
                AlignmentTrackStore.sidecarURL(left: scored, right: remote)
            )
        }
    }

    /// A path deep enough that escaping it whole would breach the 255-byte
    /// limit on a filename component must still produce a usable name.
    func testADeepLocalPathStillProducesAUsableFilename() {
        withTemporaryKeyedStore { _ in
            let deep = ClipIdentity(URL(fileURLWithPath:
                "/" + Array(repeating: "averylongfoldername", count: 40).joined(separator: "/")
                    + "/run.mp4"))
            let url = AlignmentTrackStore.sidecarURL(
                left: deep, right: .remote(provider: "gdrive", fileID: "R")
            )
            XCTAssertLessThan(url.lastPathComponent.utf8.count, 255)
        }
    }

    func testRemotePairRoundTrips() throws {
        try withTemporaryKeyedStore { _ in
            let left = ClipIdentity.remote(provider: "gdrive", fileID: "L")
            let right = ClipIdentity.remote(provider: "gdrive", fileID: "R")
            try AlignmentTrackStore.save(track(), left: left, right: right)
            XCTAssertEqual(
                AlignmentTrackStore.load(left: left, right: right)?.samples.count, 2
            )
        }
    }

    /// Left and right are not interchangeable — the track describes a shift
    /// *from* one *to* the other — so the reversed pair must be a different
    /// sidecar, exactly as it is for two local clips.
    func testReversedRemotePairIsADifferentTrack() throws {
        try withTemporaryKeyedStore { _ in
            let left = ClipIdentity.remote(provider: "gdrive", fileID: "L")
            let right = ClipIdentity.remote(provider: "gdrive", fileID: "R")
            try AlignmentTrackStore.save(track(), left: left, right: right)
            XCTAssertNil(AlignmentTrackStore.load(left: right, right: left))
        }
    }

    func testTwoLocalIdentitiesResolveToTheSameSidecarAsTheURLAPI() {
        let left = directory.appendingPathComponent("C0094.MP4")
        let right = directory.appendingPathComponent("C0092.MP4")
        XCTAssertEqual(
            AlignmentTrackStore.sidecarURL(
                left: ClipIdentity(left), right: ClipIdentity(right)
            ),
            AlignmentTrackStore.sidecarURL(left: left, right: right)
        )
    }
```

> The existing suite provides `track(leftStart:)` at line 18 and a per-test
> `directory` from `setUpWithError`. `left` and `right` are declared as locals
> inside each existing test, not as properties, so declaring them locally above
> matches the file's convention.

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter AlignmentTrackTests
```
Expected: FAIL to compile — `cannot convert value of type 'ClipIdentity' to expected argument type 'URL'`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/SkiVideoCore/AlignmentTrackStore.swift`, replace `sidecarURL`, `load` and `save` with:

```swift
    /// `<leftStem>--<rightStem>.skialignment.json`, beside `left` — but only
    /// when both sides are local.
    ///
    /// A pair with a remote side has no shared folder to sit in. Putting it
    /// beside the local half would orphan the track the moment that folder
    /// moved, and would file a record half of which describes a clip the
    /// folder never held. Such pairs go to the keyed store, named from both
    /// identities so the two spellings cannot collide.
    public static func sidecarURL(left: ClipIdentity, right: ClipIdentity) -> URL {
        if let pair = localPair(left, right) {
            let leftStem = pair.left.deletingPathExtension().lastPathComponent
            let rightStem = pair.right.deletingPathExtension().lastPathComponent
            return pair.left.deletingLastPathComponent()
                .appendingPathComponent("\(leftStem)--\(rightStem)")
                .appendingPathExtension(fileExtension)
        }
        return ClipIdentity.keyedStoreRoot
            .appendingPathComponent("\(left.pairKey)--\(right.pairKey)")
            .appendingPathExtension(fileExtension)
    }

    /// The two clips when *both* are local — the only case that files beside
    /// the footage. Nil means the pair belongs in the keyed store.
    ///
    /// One function rather than a predicate plus a separate pattern match:
    /// `sidecarURL` needs the URLs and `save` needs only the decision, and
    /// deriving them separately is how the two drift apart.
    private static func localPair(
        _ left: ClipIdentity, _ right: ClipIdentity
    ) -> (left: URL, right: URL)? {
        guard case let .local(leftClip) = left,
              case let .local(rightClip) = right
        else { return nil }
        return (leftClip, rightClip)
    }

    public static func sidecarURL(left: URL, right: URL) -> URL {
        sidecarURL(left: ClipIdentity(left), right: ClipIdentity(right))
    }

    /// The stored track, or nil when there is none or it cannot be read.
    ///
    /// An unreadable sidecar reads as absent, exactly as
    /// `ClipAnalysisStore.load` does. A track written in an older convention is
    /// refused, not adapted — see the version note below.
    public static func load(left: ClipIdentity, right: ClipIdentity) -> AlignmentTrack? {
        guard let data = try? Data(contentsOf: sidecarURL(left: left, right: right))
        else { return nil }
        guard let track = try? decoder.decode(AlignmentTrack.self, from: data)
        else { return nil }
        // A track written in an older convention is refused, not adapted. Only
        // one older version exists — version 1 stored `dy` in Vision's y-up
        // space — and a reader applying it would push the two clips apart by
        // exactly the amount it should have brought them together, with nothing
        // on screen to say so. Refusing costs one recomputation; using it costs
        // the operator's trust in every alignment they look at afterwards.
        guard track.version >= AlignmentTrack.currentVersion else { return nil }
        return track
    }

    public static func load(left: URL, right: URL) -> AlignmentTrack? {
        load(left: ClipIdentity(left), right: ClipIdentity(right))
    }

    /// Writes the sidecar, throwing if it cannot. Callers surface the failure
    /// to the operator once and carry on using the track in memory — an
    /// unwritable footage folder is a persistence problem, not an alignment
    /// failure.
    public static func save(
        _ track: AlignmentTrack, left: ClipIdentity, right: ClipIdentity
    ) throws {
        let url = sidecarURL(left: left, right: right)
        // Only the keyed store can be missing. A footage folder exists by
        // definition — the clip is in it. Asks `localPair`, the same function
        // `sidecarURL` decided with, so the two cannot disagree.
        if localPair(left, right) == nil {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        }
        try encoder.encode(track).write(to: url, options: .atomic)
    }

    public static func save(_ track: AlignmentTrack, left: URL, right: URL) throws {
        try save(track, left: ClipIdentity(left), right: ClipIdentity(right))
    }
```

- [ ] **Step 4: Run the alignment suites**

Run:
```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter AlignmentTrack
```
Expected: PASS. `AlignmentTrackTests` gains 5 tests; `AlignmentTrackStore`'s existing cases and `AlignmentAnalyzerTests` must be unaffected.

- [ ] **Step 5: Commit**

```bash
git add SkiVideoViewer/Sources/SkiVideoCore/AlignmentTrackStore.swift \
        SkiVideoViewer/Tests/SkiVideoCoreTests/AlignmentTrackTests.swift
git commit -m "File an alignment track by identity, and decide where a mixed pair goes

Two local clips keep their track beside the left one. A pair with a remote side
has no shared folder, and filing it beside the local half would orphan a record
half of which describes a clip that folder never held."
```

---

### Task 4: Call the stores through identities

**Files:**
- Modify: `Sources/SkiVideoCore/SubjectSessionModel.swift:73,163`
- Modify: `Sources/SkiVideoCore/AlignmentSessionModel.swift:158,220`

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces: nothing new. This is the switch-over, and it is deliberately last so that every task before it was independently revertible.

Both models currently hold clip `URL`s and will keep doing so until plan 2 introduces a library that yields identities. This task changes only *how they reach the store*, so that plan 2's change is a type change at the model's edge rather than a rewrite of its body.

- [ ] **Step 1: Write the failing test**

Add to `Tests/SkiVideoCoreTests/SubjectSessionModelTests.swift`, inside the existing class:

```swift
    /// A *local* clip's analysis must never route to the keyed store, and the
    /// model must keep reaching the stores through an identity.
    ///
    /// Drives both call sites this task changes — `loadStored` reads,
    /// `confirm` writes — with the keyed store pointed at a directory that
    /// does not exist, so a stray write there shows up as that directory
    /// appearing. Asserting on `ClipAnalysisStore` directly would prove
    /// nothing about the model: it is the model's two calls that are being
    /// switched over, so the model is what the test has to drive.
    ///
    /// This is the assertion the pre-existing round-trip tests cannot make.
    /// `testAStoredAnalysisIsReusedWithoutAnalysingAgain` and
    /// `testConfirmingAPickWritesItToTheSidecar` would both still pass if the
    /// model *also* wrote a copy into the keyed store.
    func testTheModelNeverTouchesTheKeyedStoreForALocalClip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let previous = ClipIdentity.keyedStoreRoot
        ClipIdentity.keyedStoreRoot = root
        defer {
            ClipIdentity.keyedStoreRoot = previous
            try? FileManager.default.removeItem(at: root)
        }

        try ClipAnalysisStore.save(analysis(subject: nil), for: clip())
        let session = SubjectSessionModel()

        XCTAssertNotNil(session.loadStored(for: clip()))
        try session.confirm(
            segmentIDs: [1],
            runStart: .started(time: 4.42, baseline: 1.12, threshold: 2.02),
            for: clip()
        )

        XCTAssertEqual(ClipAnalysisStore.load(for: clip())?.subject?.segmentIDs, [1])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.path),
            "a local clip's analysis must stay beside the footage"
        )
    }
```

- [ ] **Step 2: Run test to verify it passes already**

Run:
```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter testTheModelNeverTouchesTheKeyedStoreForALocalClip
```
Expected: **PASS**. This is a characterisation test, not a red test — it pins behaviour that must survive Step 3, and it passes before the change because the URL-taking store API already delegates to `.local`. Note it in the commit message as such; a reviewer seeing a test that never failed should be told why.

- [ ] **Step 3: Change the call sites**

In `Sources/SkiVideoCore/SubjectSessionModel.swift`, line 73:

```swift
        guard let stored = ClipAnalysisStore.load(for: ClipIdentity(clip)) else {
```

and line 163:

```swift
        try ClipAnalysisStore.save(updated, for: ClipIdentity(clip))
```

In `Sources/SkiVideoCore/AlignmentSessionModel.swift`, line 158:

```swift
        guard let stored = AlignmentTrackStore.load(
            left: ClipIdentity(left), right: ClipIdentity(right)
        ) else {
```

and line 220:

```swift
                    try AlignmentTrackStore.save(
                        result, left: ClipIdentity(left), right: ClipIdentity(right)
                    )
```

- [ ] **Step 4: Run the full suite**

Run:
```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -20
```
Expected: PASS, with no test edited to accommodate the change.

- [ ] **Step 5: Commit**

```bash
git add SkiVideoViewer/Sources/SkiVideoCore/SubjectSessionModel.swift \
        SkiVideoViewer/Sources/SkiVideoCore/AlignmentSessionModel.swift \
        SkiVideoViewer/Tests/SkiVideoCoreTests/SubjectSessionModelTests.swift
git commit -m "Reach the analysis stores through an identity

No behaviour change — ClipIdentity(url) is .local(url) — but it moves the seam
to the models' edge, so a library that yields remote clips changes a type here
rather than a body. The added test passed before this change as well as after:
it pins that a local clip still uses its footage folder."
```

---

## Definition of done

- [ ] `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` passes in full.
- [ ] No pre-existing test was edited.
- [ ] `CorePurityTests` passes — no platform import reached `SkiVideoCore`.
- [ ] A local library behaves exactly as before: sidecars beside the footage, same names, same contents.
- [ ] Nothing in the app writes to `ClipIdentity.keyedStoreRoot` yet — only tests do. It is the seam plan 2 fills.

## What this plan deliberately does not do

- **It does not make analysis survive a local clip being renamed or moved.** A sidecar beside the footage is orphaned by a rename whatever the store keys on. Fixing that needs content-hash or inode keying and is not in the spec.
- **It does not sync anything to Drive.** Sharing analysis across the club is named in the spec as out of scope; the keyed store is the seam it would attach to.
- **It adds no migration.** Nothing has ever been written to the keyed store, so there is nothing to migrate.
