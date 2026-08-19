# Oversized Clip Detection and Repair — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Notice a Drive clip that is too big to fetch before downloading a byte of it, refuse the download, and offer to replace it in Drive with one the app's own pipeline would have produced.

**Architecture:** A pure value type decides "too big" from metadata Drive already returns for free. `RemoteFile` carries three new optional fields to feed it. The viewer and the comparison window consult it before fetching, reusing the banner `ClipPlayability` already owns. Repair downloads once, re-encodes with the existing `AVFoundationMediaPipeline`, and calls `files.update` on the same file id — behind a Drive write scope requested incrementally, only when someone first repairs something.

**Tech Stack:** Swift 6.1 toolchain, `swiftLanguageModes: [.v5]`, SwiftPM, AVFoundation, Google Drive v3 REST, XCTest.

## Global Constraints

- **Test command.** A bare `swift test` fails with `no such module 'XCTest'`. Always:
  ```bash
  swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  ```
  **Targeted filters while iterating; the full suite ONCE at the end.** A mutation check needs only the tests covering the mutated code — not a full run each. Baseline: **764 executed, 8 skipped, 0 failures**, ~120 s.
- `--filter SkiVideoCoreTests` covers everything in Tasks 1–4 and opens no windows.
- The six slowest analysis tests are skipped by default behind `SKI_SLOW_TESTS`; leave that alone.
- Read `CLAUDE.md` in the working directory first.
- `SkiVideoCore` stays platform-agnostic: `CorePurityTests` fails the build if a core source names AppKit or UIKit.
- Access levels stay narrow: `public` marks only what the app target touches.
- **Exact values.** Target bitrate is `width × height × 1.784` bits/second (`AVFoundationMediaPipeline.bitsPerPixel`). Flag when measured bitrate exceeds **2×** that, **or** when `width > 1920 || height > 1080`. Absent metadata is **never** flagged.
- This codebase documents *why* with measured evidence. Roughly fifteen claims in recent work failed under measurement, several from plans like this one. If something here is wrong when you check it, say so rather than implementing it as stated.
- Stage by explicit path; `AppBundle/` holds intentionally uncommitted artwork. Never `git add -A`.
- Commit messages: imperative, no `feat:`/`fix:` prefixes, each ending with:
  ```
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  ```

## File Structure

**Create:**
- `Sources/SkiVideoCore/ClipWeight.swift` — the rule. Dimensions, duration and size in; a verdict and an explanation out. No network, no AVFoundation.
- `Tests/SkiVideoCoreTests/ClipWeightTests.swift`

**Modify:**
- `Sources/SkiVideoCore/RemoteLibraryProvider.swift` — `RemoteFile` gains `width`, `height`, `durationMillis`.
- `Sources/SkiVideoCore/GoogleDriveProvider.swift` — field masks, `DriveRecord`, and a `replace` call.
- `Sources/SkiVideoCore/GoogleOAuth.swift` — incremental scope upgrade.
- `Sources/SkiVideoCore/ViewerModel.swift` — refuse before fetching; drive the repair.
- `Sources/SkiVideoCore/ComparisonModel.swift` — refuse before fetching.
- `Sources/SkiVideoViewer/Shared/GoogleDriveSheet.swift` — the repair action.

---

### Task 1: `ClipWeight`

The whole rule, testable with no network and no media. Nothing else changes.

**Files:**
- Create: `Sources/SkiVideoCore/ClipWeight.swift`
- Test: `Tests/SkiVideoCoreTests/ClipWeightTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public enum ClipWeight` with
  `public static func verdict(width: Int?, height: Int?, durationMillis: Int?, size: Int64) -> Verdict`
  and `public struct Verdict: Equatable` carrying `public let isTooLarge: Bool` and `public let explanation: String?`.
  Tasks 3–5 call exactly this.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SkiVideoCoreTests/ClipWeightTests.swift`:

```swift
import XCTest
@testable import SkiVideoCore

/// The "too big to fetch" rule, as pure arithmetic.
///
/// No network and no media on purpose: every claim here is about numbers, and
/// the cost of getting it wrong is either a 400MB download the operator did not
/// want or a clip they cannot open at all. Both deserve exhaustive cheap tests.
final class ClipWeightTests: XCTestCase {
    /// 1920 × 1080 × 1.784 ≈ 3.70 Mbps; the bar is twice that.
    private let hdTargetBitsPerSecond = 1920.0 * 1080.0 * 1.784

    private func size(forBitrate bitsPerSecond: Double, seconds: Double) -> Int64 {
        Int64((bitsPerSecond * seconds / 8).rounded())
    }

    func testAClipAtThePipelinesOwnBitrateIsFine() {
        let verdict = ClipWeight.verdict(
            width: 1920, height: 1080, durationMillis: 30_000,
            size: size(forBitrate: hdTargetBitsPerSecond, seconds: 30)
        )
        XCTAssertFalse(verdict.isTooLarge)
        XCTAssertNil(verdict.explanation)
    }

    /// The observed case: 400MB of 1080p footage that is seconds long.
    func testTheReportedFourHundredMegabyteClipIsFlagged() {
        let verdict = ClipWeight.verdict(
            width: 1920, height: 1080, durationMillis: 30_000, size: 400 * 1_000_000
        )
        XCTAssertTrue(verdict.isTooLarge)
        XCTAssertNotNil(verdict.explanation)
    }

    /// 2× leaves room for ordinary encoder variation, so just-above-target is
    /// deliberately left alone — flagging it would make the feature fire on
    /// clips nobody would call excessive.
    func testJustUnderTwiceTheTargetIsNotFlagged() {
        let verdict = ClipWeight.verdict(
            width: 1920, height: 1080, durationMillis: 10_000,
            size: size(forBitrate: hdTargetBitsPerSecond * 1.98, seconds: 10)
        )
        XCTAssertFalse(verdict.isTooLarge)
    }

    func testJustOverTwiceTheTargetIsFlagged() {
        let verdict = ClipWeight.verdict(
            width: 1920, height: 1080, durationMillis: 10_000,
            size: size(forBitrate: hdTargetBitsPerSecond * 2.02, seconds: 10)
        )
        XCTAssertTrue(verdict.isTooLarge)
    }

    /// The pipeline downscales anything above 1080p, so the extra pixels can
    /// never be seen — a well-compressed 4K clip still costs more to fetch than
    /// it can show.
    func testFourKIsFlaggedEvenAtAModestBitrate() {
        let verdict = ClipWeight.verdict(
            width: 3840, height: 2160, durationMillis: 30_000,
            size: size(forBitrate: 8_000_000, seconds: 30)
        )
        XCTAssertTrue(verdict.isTooLarge)
    }

    func testAClipTallerThanTenEightyIsFlagged() {
        let verdict = ClipWeight.verdict(
            width: 1080, height: 1920, durationMillis: 30_000,
            size: size(forBitrate: 3_000_000, seconds: 30)
        )
        XCTAssertTrue(verdict.isTooLarge, "portrait 1080×1920 exceeds the 1080 height bound")
    }

    /// Length alone is never a reason. At the target bitrate a 1080p clip only
    /// reaches 400MB at about 14 minutes, and a correctly encoded long clip is
    /// not the problem this rule exists for.
    func testALongClipAtTheTargetBitrateIsNotFlagged() {
        let verdict = ClipWeight.verdict(
            width: 1920, height: 1080, durationMillis: 20 * 60_000,
            size: size(forBitrate: hdTargetBitsPerSecond, seconds: 20 * 60)
        )
        XCTAssertFalse(verdict.isTooLarge)
    }

    // MARK: - Absent and degenerate metadata

    /// Drive fills `videoMediaMetadata` in asynchronously after an upload, so a
    /// clip added minutes ago carries none. Refusing what cannot be measured
    /// would strike hardest exactly when a coach has just uploaded footage.
    func testMissingMetadataIsNeverFlagged() {
        for verdict in [
            ClipWeight.verdict(width: nil, height: 1080, durationMillis: 30_000, size: 400_000_000),
            ClipWeight.verdict(width: 1920, height: nil, durationMillis: 30_000, size: 400_000_000),
            ClipWeight.verdict(width: 1920, height: 1080, durationMillis: nil, size: 400_000_000),
        ] {
            XCTAssertFalse(verdict.isTooLarge)
            XCTAssertNil(verdict.explanation)
        }
    }

    /// A zero duration would divide by zero and a zero dimension would make the
    /// target bitrate zero, so every clip would flag. Both mean "Drive told us
    /// something useless", which is the missing-metadata case.
    func testZeroDurationOrDimensionIsNeverFlagged() {
        XCTAssertFalse(
            ClipWeight.verdict(width: 1920, height: 1080, durationMillis: 0, size: 400_000_000).isTooLarge
        )
        XCTAssertFalse(
            ClipWeight.verdict(width: 0, height: 0, durationMillis: 30_000, size: 400_000_000).isTooLarge
        )
    }

    func testANegativeOrZeroSizeIsNeverFlagged() {
        XCTAssertFalse(
            ClipWeight.verdict(width: 1920, height: 1080, durationMillis: 30_000, size: 0).isTooLarge
        )
    }

    // MARK: - The explanation

    /// The operator is being refused a download, so the message has to carry
    /// the numbers that justify it — "too big" alone gives them nothing to act
    /// on or to disagree with.
    func testTheExplanationNamesTheSizeAndHowFarOverItIs() throws {
        let verdict = ClipWeight.verdict(
            width: 1920, height: 1080, durationMillis: 30_000, size: 400 * 1_000_000
        )
        let explanation = try XCTUnwrap(verdict.explanation)
        XCTAssertTrue(explanation.contains("400"), explanation)
        XCTAssertTrue(explanation.contains("×"), explanation)
    }

    func testTheExplanationForAnOversizedResolutionSaysSo() throws {
        let verdict = ClipWeight.verdict(
            width: 3840, height: 2160, durationMillis: 30_000,
            size: size(forBitrate: 8_000_000, seconds: 30)
        )
        let explanation = try XCTUnwrap(verdict.explanation)
        XCTAssertTrue(explanation.contains("3840"), explanation)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ClipWeightTests`
Expected: FAIL to compile — `cannot find 'ClipWeight' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/SkiVideoCore/ClipWeight.swift`:

```swift
import Foundation

/// Whether a clip is too heavy to be worth fetching, judged from metadata alone.
///
/// Coaches upload footage straight to the club's Shared Drive, so those clips
/// never pass through this app's resize step — one observed example is 400MB,
/// and playing it means fetching all of it.
///
/// **The bar is the app's own output.** `AVFoundationMediaPipeline` targets
/// 1.784 bits per pixel per second, which is 3.70 Mbps at 1080p, and that
/// number is measured rather than chosen: on real footage the step halved a
/// clip from 7.41 to 3.70 Mbps. A clip more than twice that is carrying detail
/// this app would not have kept.
///
/// No AVFoundation and no network here on purpose: Drive returns width, height
/// and duration in the sweep it already performs, so the whole judgement is
/// arithmetic on values the app has before it downloads anything.
public enum ClipWeight {
    /// Bits per second per output pixel — `AVFoundationMediaPipeline`'s own
    /// constant, restated here because that type is about encoding and this one
    /// is about deciding. If the pipeline's target ever moves, this must move
    /// with it or the app will refuse clips it would itself produce.
    static let targetBitsPerPixel = 1.784

    /// Room for ordinary encoder variation. At 1× a clip merely encoded a
    /// little richly than this app's own output would be refused, which is not
    /// what the feature is for.
    static let allowedMultiple = 2.0

    /// The pipeline never emits above this, so anything larger is detail the
    /// player will throw away — see `AVFoundationMediaPipeline`'s
    /// `min(1920/w, 1080/h, 1)`.
    static let maximumWidth = 1920
    static let maximumHeight = 1080

    public struct Verdict: Equatable {
        public let isTooLarge: Bool
        /// Nil when the clip is fine. Carries the numbers when it is not: the
        /// operator is being refused a download and "too big" alone gives them
        /// nothing to act on or to disagree with.
        public let explanation: String?

        static let fine = Verdict(isTooLarge: false, explanation: nil)
    }

    /// `nil` for any of the three metadata values means Drive has not told us —
    /// it fills `videoMediaMetadata` in asynchronously after an upload — and a
    /// non-positive value means it told us something useless. Both are the same
    /// answer: do not refuse what cannot be measured. Refusing then would
    /// strike hardest exactly when a coach has just uploaded footage and wants
    /// to watch it.
    public static func verdict(
        width: Int?, height: Int?, durationMillis: Int?, size: Int64
    ) -> Verdict {
        guard let width, let height, let durationMillis,
              width > 0, height > 0, durationMillis > 0, size > 0
        else {
            return .fine
        }

        if width > maximumWidth || height > maximumHeight {
            return Verdict(
                isTooLarge: true,
                explanation: """
                \(formatted(size)), \(width)×\(height) — larger than this app \
                plays (\(maximumWidth)×\(maximumHeight)), so the extra detail \
                is downloaded and then discarded.
                """
            )
        }

        let seconds = Double(durationMillis) / 1000
        let measured = Double(size) * 8 / seconds
        let target = Double(width * height) * targetBitsPerPixel
        guard measured > target * allowedMultiple else { return .fine }

        return Verdict(
            isTooLarge: true,
            explanation: """
            \(formatted(size)) — about \(String(format: "%.0f", measured / target))× \
            the bitrate this app produces for \(width)×\(height). Resizing it \
            would not change the framerate.
            """
        )
    }

    /// Megabytes in the operator's terms — Drive reports these in decimal, and
    /// a clip the Finder calls 400MB should not be described as 381.
    private static func formatted(_ size: Int64) -> String {
        "\(Int((Double(size) / 1_000_000).rounded())) MB"
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ClipWeightTests`
Expected: PASS, 12 tests.

- [ ] **Step 5: Commit**

```bash
swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SkiVideoCoreTests
git add Sources/SkiVideoCore/ClipWeight.swift Tests/SkiVideoCoreTests/ClipWeightTests.swift
git commit -m "Judge a clip's weight from metadata alone

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Carry the metadata through the Drive sweep

**Files:**
- Modify: `Sources/SkiVideoCore/RemoteLibraryProvider.swift:139-153`
- Modify: `Sources/SkiVideoCore/GoogleDriveProvider.swift:16-17`, `:712`, `:717-728`
- Test: `Tests/SkiVideoCoreTests/GoogleDriveProviderTests.swift`

**Interfaces:**
- Consumes: `ClipWeight.verdict(width:height:durationMillis:size:)` (Task 1) — not called here, but these are the fields that feed it.
- Produces: `RemoteFile.width: Int?`, `RemoteFile.height: Int?`, `RemoteFile.durationMillis: Int?`. Tasks 3–5 read them.

- [ ] **Step 1: Write the failing test**

Add to `Tests/SkiVideoCoreTests/GoogleDriveProviderTests.swift`, following the fake-transport shape already in that file:

```swift
    // MARK: - Video metadata

    /// Drive returns width, height and duration in the sweep the app already
    /// performs, so the weight check costs no extra request and no download.
    func testASweepCarriesVideoMetadataThrough() async throws {
        transport.responses = [
            .init(json: """
            {"files":[
              {"id":"f1","name":"run.mp4","mimeType":"video/mp4","parents":["d1"],
               "size":"400000000",
               "videoMediaMetadata":{"width":1920,"height":1080,"durationMillis":"30000"}}
            ]}
            """),
        ]

        var files: [RemoteFile] = []
        for try await file in provider.enumerate(RemoteFolder(id: "d1", name: "Videos")) { files.append(file) }

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].width, 1920)
        XCTAssertEqual(files[0].height, 1080)
        XCTAssertEqual(files[0].durationMillis, 30_000)
    }

    /// Drive fills the block in asynchronously after an upload, so a freshly
    /// uploaded clip arrives without it. That must not fail the sweep.
    func testASweepWithoutVideoMetadataStillYieldsTheFile() async throws {
        transport.responses = [
            .init(json: """
            {"files":[
              {"id":"f1","name":"run.mp4","mimeType":"video/mp4","parents":["d1"],"size":"1000"}
            ]}
            """),
        ]

        var files: [RemoteFile] = []
        for try await file in provider.enumerate(RemoteFolder(id: "d1", name: "Videos")) { files.append(file) }

        XCTAssertEqual(files.count, 1)
        XCTAssertNil(files[0].width)
        XCTAssertNil(files[0].durationMillis)
    }

    /// The field mask is the whole reason the data arrives; a sweep that stops
    /// asking for it would silently stop flagging anything.
    func testTheSweepAsksDriveForVideoMetadata() async throws {
        transport.responses = [.init(json: #"{"files":[]}"#)]
        for try await _ in provider.enumerate(RemoteFolder(id: "d1", name: "Videos")) {}
        let asked = transport.requests.first?.url?.absoluteString ?? ""
        XCTAssertTrue(asked.contains("videoMediaMetadata"), asked)
    }
```

**Two names in the tests above are wrong — I checked.** There is no `provider.files(inRoot:)`: the protocol exposes
`enumerate(_ folder: RemoteFolder) -> AsyncThrowingStream<RemoteFile, Error>` (`RemoteLibraryProvider.swift:81`), so collect the stream. And the fake records `requests: [URLRequest]` (`FakeHTTPTransport.swift:44`), not `requestedURLs` — read the URL off `transport.requests.first?.url`. Adjust all three tests accordingly; the assertions themselves stand.

- [ ] **Step 2: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GoogleDriveProviderTests`
Expected: FAIL — `RemoteFile` has no member `width`.

- [ ] **Step 3: Add the fields**

In `Sources/SkiVideoCore/RemoteLibraryProvider.swift`, extend `RemoteFile`:

```swift
    /// Pixel dimensions and duration as Drive reports them, or nil when it has
    /// not said. Drive fills `videoMediaMetadata` in asynchronously after an
    /// upload, so a clip added minutes ago legitimately carries none — see
    /// `ClipWeight`, which treats absent metadata as "do not judge".
    public let width: Int?
    public let height: Int?
    public let durationMillis: Int?
```

Update the memberwise initialiser with defaults of `nil` for all three, so every existing construction site — the tests, the index, the change feed — keeps compiling and keeps meaning what it meant.

In `Sources/SkiVideoCore/GoogleDriveProvider.swift`, add `videoMediaMetadata(width,height,durationMillis)` inside the `files(...)` group of `fileFields` (`:16`) and inside the `file(...)` group of `changeFileFields` (`:712`), and extend `DriveRecord` (`:717`):

```swift
    /// Drive nests these, and reports `durationMillis` as a *string* while
    /// width and height are numbers — mirroring the wire exactly rather than
    /// flattening it, because a decode that guesses at the shape is how the
    /// change feed's `fileId` bug happened.
    struct VideoMediaMetadata: Decodable {
        let width: Int?
        let height: Int?
        let durationMillis: String?
    }
    let videoMediaMetadata: VideoMediaMetadata?
```

Then carry them into every `RemoteFile(...)` construction in that file — the sweep and the change feed both.

- [ ] **Step 4: Run the tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GoogleDriveProviderTests`
Expected: PASS.

- [ ] **Step 5: Confirm the stored index round-trips the new fields**

`RemoteFile` is `Codable` and is persisted in the index. Adding optional fields is compatible with an old stored file, but check `RemoteLibraryIndex.currentVersion`: if a stored index would now be missing metadata for every clip and so silently flag nothing, bump the version so it re-sweeps. Say in the report which you chose and why.

- [ ] **Step 6: Commit**

```bash
swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SkiVideoCoreTests
git add Sources/SkiVideoCore/RemoteLibraryProvider.swift Sources/SkiVideoCore/GoogleDriveProvider.swift Tests/SkiVideoCoreTests/GoogleDriveProviderTests.swift
git commit -m "Ask Drive for the dimensions and duration it already has

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Refuse to fetch a flagged clip

**Files:**
- Modify: `Sources/SkiVideoCore/ViewerModel.swift` (around `:1031`, where `ClipPlayability.unsupportedVideoMessage` is already consulted)
- Modify: `Sources/SkiVideoCore/ComparisonModel.swift`
- Test: `Tests/SkiVideoCoreTests/ViewerModelIntentTests.swift`, `Tests/SkiVideoCoreTests/ComparisonModelTests.swift`

**Interfaces:**
- Consumes: `ClipWeight.verdict(width:height:durationMillis:size:)` (Task 1), `RemoteFile.width/height/durationMillis` (Task 2).
- Produces: nothing new for later tasks; Task 5 reads the same verdict to decide whether to offer repair.

- [ ] **Step 1: Write the failing tests**

The refusal has three claims worth pinning. Write them against the existing fakes in each file — `FakeRemoteProvider` records what was fetched, which is what makes "did not download" checkable:

```swift
    /// The point of the whole feature: a flagged clip must not start a
    /// transfer. Asserting on the provider's record rather than on a message,
    /// because the message is cosmetic and the download is the cost.
    func testSelectingAnOversizedClipDoesNotFetchIt() async throws { ... }

    /// The refusal is about the download, so a clip already on disk plays.
    /// Refusing then would be obstruction with no benefit.
    func testAnOversizedClipAlreadyInTheCacheStillPlays() async throws { ... }

    /// A clip Drive has not described cannot be judged, and must not be
    /// refused — this is the freshly-uploaded case.
    func testAClipWithNoMetadataIsFetchedNormally() async throws { ... }
```

Fill in the bodies from the fakes those files already use. Read `FakeRemoteProvider` first: if it does not record fetches, add that recording — it is the only way to assert the download did not happen, and asserting on a status string instead would pass with the fetch still running.

- [ ] **Step 2: Run to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SkiVideoCoreTests`
Expected: FAIL — the clip is fetched.

- [ ] **Step 3: Implement the refusal**

In `ViewerModel`, consult `ClipWeight.verdict(...)` on the `RemoteFile` **before** the fetch, and when it refuses, set the same surface `ClipPlayability`'s message already uses rather than adding a second one. `ViewerModel.swift:1031` shows how that message is currently produced and displayed; follow it.

In `ComparisonModel`, do the same on the load path for each side. This case matters more than it looks: a coach loading two flagged clips would otherwise start two large transfers at once.

Both must let a cached clip through. `ClipCache` already knows whether a clip is on disk — use it rather than inferring.

- [ ] **Step 4: Run the tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SkiVideoCoreTests`
Expected: PASS.

- [ ] **Step 5: Mutation-check the refusal**

Remove the `isTooLarge` check and confirm `testSelectingAnOversizedClipDoesNotFetchIt` fails. Restore. Report the output. Run only the covering tests for this — not the full suite.

- [ ] **Step 6: Commit**

```bash
git add Sources/SkiVideoCore/ViewerModel.swift Sources/SkiVideoCore/ComparisonModel.swift Tests/SkiVideoCoreTests/ViewerModelIntentTests.swift Tests/SkiVideoCoreTests/ComparisonModelTests.swift
git commit -m "Refuse to fetch a clip too big to be worth it

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Drive write access, asked for only when used

The scope change is its own task because it is the one piece with consequences outside this app: a broader consent screen, and a re-authorisation.

**Files:**
- Modify: `Sources/SkiVideoCore/GoogleOAuth.swift:79`, `:198-208`
- Test: `Tests/SkiVideoCoreTests/GoogleOAuthTests.swift` (or the OAuth tests wherever they live — find them)

**Interfaces:**
- Consumes: nothing.
- Produces: a way to authorise with the write scope and store the resulting token — name it to match the file's existing style. Task 5 calls it.

- [ ] **Step 1: Write the failing tests**

```swift
    /// Watching costs nothing extra. A coach who never repairs a clip must
    /// never see a consent screen asking for write access to their Drive.
    func testTheOrdinarySignInAsksOnlyForReadAccess() throws { ... }

    /// The upgrade asks for both, not just the new one: Google returns a token
    /// carrying exactly the scopes requested, so omitting the read scope here
    /// would trade the app's ability to read the library for its ability to
    /// write one file.
    func testTheWriteUpgradeAsksForReadAndWriteTogether() throws { ... }
```

Assert on the authorization URL's `scope` query item — that is the observable thing, and `GoogleOAuth.authorize` builds it at `:198`.

- [ ] **Step 2: Run to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SkiVideoCoreTests`

- [ ] **Step 3: Implement**

`scope` at `:79` is a single `private static let`. Make the authorize path take the scope it should request, defaulting to today's `drive.readonly` so every existing caller is unchanged, and add the write value `https://www.googleapis.com/auth/drive`.

Include `include_granted_scopes=true` in the authorization query so Google returns a token carrying the previously granted scopes as well — that is what makes this incremental rather than a replacement.

The upgraded refresh token replaces the stored one, through the same `OAuthTokenStore` the sign-in path already uses. **Do not remove the old token before the new one is stored**: a failed upgrade must leave the operator signed in and reading, not signed out.

- [ ] **Step 4: Run the tests, then commit**

```bash
swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SkiVideoCoreTests
git add Sources/SkiVideoCore/GoogleOAuth.swift Tests/SkiVideoCoreTests/
git commit -m "Ask for Drive write access only when it is needed

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Repair a clip in place

**Files:**
- Modify: `Sources/SkiVideoCore/GoogleDriveProvider.swift`
- Modify: `Sources/SkiVideoCore/ViewerModel.swift`
- Modify: `Sources/SkiVideoViewer/Shared/GoogleDriveSheet.swift`
- Test: `Tests/SkiVideoCoreTests/GoogleDriveProviderTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: a provider method that replaces a file's content by id.

- [ ] **Step 1: Write the failing tests**

```swift
    /// The file id is preserved on purpose, and this is the assertion that
    /// guards it: clip identity, the analysis sidecars, stored sync points and
    /// the on-disk cache are all keyed on it, so a delete-and-reupload would
    /// silently orphan every correction the operator has made.
    func testReplacingUploadsAgainstTheOriginalFileID() async throws { ... }

    /// Scope is necessary but not sufficient. A coach with view-only
    /// permission on the club's Shared Drive gets a 403 even after granting
    /// write access — the everyday case for anyone who is not an admin.
    func testAPermissionFailureSaysSoInsteadOfRaisingARawError() async throws { ... }
```

- [ ] **Step 2: Run to verify they fail**

- [ ] **Step 3: Implement**

Add the replace call to `GoogleDriveProvider`: an upload to
`https://www.googleapis.com/upload/drive/v3/files/{fileId}` with `uploadType=media` and `supportsAllDrives=true`, using PATCH. The file id in the path is the whole point — see the test above.

`reencode_for_ios.py:383` does the same thing with `files().update(fileId, media_body=)`; read it before writing this, because it is the proven shape in this project.

A 403 must surface as a permission message naming the situation ("you do not have permission to change this file in Drive"), not a raw API error. The flagged clip stays listed and explained rather than disappearing or appearing repaired.

Wire the action: download once, `AVFoundationMediaPipeline.resize`, replace, then refresh that clip's entry. The re-encode is the existing pipeline unchanged — the framerate is untouched, which is what a coach is judging.

Replacing changes `headRevisionId`, which the app already carries as `contentVersion`, so the clip cache invalidates itself. Verify that rather than assuming it.

- [ ] **Step 4: Run the tests, mutation-check the file id**

Point the upload at a new file rather than the original's id and confirm `testReplacingUploadsAgainstTheOriginalFileID` fails. Restore. Report the output.

- [ ] **Step 5: Full suite, once, then commit**

```bash
swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
git add Sources/SkiVideoCore/GoogleDriveProvider.swift Sources/SkiVideoCore/ViewerModel.swift Sources/SkiVideoViewer/Shared/GoogleDriveSheet.swift Tests/SkiVideoCoreTests/GoogleDriveProviderTests.swift
git commit -m "Replace an oversized clip in Drive, keeping its identity

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Check it against the real library

Unit tests cannot see a consent screen, a 403 from a real Shared Drive, or whether the refusal reads as helpful rather than broken.

**Files:** none unless a defect turns up.

- [ ] **Step 1: Build and launch**

```bash
./run.sh
```

- [ ] **Step 2: Check the detection**

| Do | Expect |
| --- | --- |
| Open the club library | flagged clips are listed, with size and reason |
| Select a flagged clip | no download starts; the explanation appears |
| Select a normal clip | plays as before |
| Select a clip uploaded minutes ago | plays — Drive has not described it yet, so it is not judged |

- [ ] **Step 3: Check the repair**

| Do | Expect |
| --- | --- |
| Repair a flagged clip, first time | Google asks for write access once |
| After it finishes | the clip plays, and is much smaller |
| Check Drive | same file, same id, new revision — not a second copy |
| Any sync points or corrections on that clip | still there |
| Repair with view-only access | a permission message, not a raw error |

- [ ] **Step 4: Report**

Write up what happened, especially the consent screen's wording and the 403 path. Nothing is committed here unless a defect turns up and is fixed.

---

## Self-Review

**Spec coverage.** The rule and its thresholds → Task 1. Free detection via `videoMediaMetadata`, absent-metadata behaviour → Tasks 1 and 2. Refusing the fetch, both screens, cached-clip exception → Task 3. Incremental write scope → Task 4. Repair in place, same file id, 403 handling, cache invalidation → Task 5. The manual checks → Task 6.

**One spec item deliberately deferred:** the spec says the explanation belongs on `ClipPlayability`'s existing banner surface. Task 3 says to reuse that surface but does not restate its code, because I have read only its entry point (`ViewerModel.swift:1031`) and not how the message reaches the view. The implementer must read that before wiring it; inventing a second banner is the failure mode to avoid.

**Placeholder scan.** Tasks 3, 4 and 5 give test *names and rationale* rather than full bodies, because they depend on fakes whose exact API I have not read (`FakeRemoteProvider`, the OAuth tests' harness). Each says explicitly what to read first and what to do if the helper does not exist. That is a deliberate limit on my knowledge, stated, rather than invented code that would not compile.

**Names checked across tasks:** `ClipWeight.verdict(width:height:durationMillis:size:)`, `ClipWeight.Verdict.isTooLarge`, `.explanation`, `RemoteFile.width/height/durationMillis`, `DriveRecord.VideoMediaMetadata`. Consistent as used.
