# Sign-in, the Drive Picker, and Fetching on Select Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **INCOMPLETE — do not execute past Task 3.** Tasks 1–3 are specified at full
> resolution: exact code, exact test bodies. **Tasks 4–7 describe their tests in
> prose only** and are not yet executable to this repo's standard.
>
> That distinction matters more here than it usually would. Across plans 1 and
> 2, five tests passed while being unable to fail, every one of them from a
> fixture *I* wrote being too small to express the case it claimed to test. An
> outline saying "assert prefetch reaches the neighbours" is exactly the shape
> that produced those. Finish tasks 4–7 to the resolution of tasks 1–3 —
> including, for each test, the sentence naming what implementation change would
> make it fail — before dispatching them.

**Goal:** A coach opens the app, signs in with their club Google account, picks the Shared Drive from a list, clicks a clip, and reviews it — with analysis filed where it survives.

**Architecture:** Three things get connected that plan 2 built but deliberately left unwired. `GoogleOAuth` becomes reachable from `GoogleDriveProvider`, so `connect(presenter:)` stops throwing. A sign-in sheet replaces the placeholder, listing Shared Drives from `drives.list` instead of asking for a pasted id. And selecting a clip fetches it, so the cache stops being a thing only tests call. One correctness fix travels with them: a cached clip must reach the analysis stores as its **remote identity**, not as its cache path, or every sidecar lands in a directory the OS may purge.

**Tech Stack:** Swift 6.1, SwiftPM, XCTest, AuthenticationServices (`ASWebAuthenticationSession`). No new dependencies.

This is plan 3 of 3 from `docs/superpowers/specs/2026-08-13-cloud-video-library-design.md`. Plans 1 and 2 are merged: `ClipIdentity` and the identity-keyed stores; the provider, index and cache.

## What plan 2 left, deliberately or otherwise

| Left | Where it is closed here |
| --- | --- |
| `GoogleDriveProvider.connect` throws `.notSignedIn` | Task 3 |
| The sheet is an honest placeholder | Task 4 |
| Nothing calls `prepareCurrentClip`, so selection does not fetch | Task 6 |
| Nothing calls `RemoteLibraryIndex.save`/`load`/`applying`, so relaunch re-sweeps | Task 5 |
| An unprepared clip is offered its raw library URL to a comparison pane | Task 6 |
| **A cached clip reaches the analysis stores as `.local(cacheURL)`** | **Task 1** |
| iPad has `UnavailableOAuthPresenter` | Task 7 |

The bolded one is a correctness defect the final whole-branch review found, not a missing feature: `ComparisonView.swift:348` passes a playback URL into `loadStored(for:)`, and for a cloud clip that is a path under `Caches`. So `ClipAnalysisStore` keys it `.local(cacheURL)` and writes the sidecar into a directory iOS may purge and eviction may orphan — defeating the identity-keyed store plan 1 built for exactly this case. It is Task 1 because it is independent of sign-in and can land on its own.

## Global Constraints

- **The test command is NOT plain `swift test`.** `xcode-select -p` points at `/Library/Developer/CommandLineTools`, which ships no XCTest, so bare `swift test` fails with `error: no such module 'XCTest'`. Every command here is prefixed:
  `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test …`
- **The repo carries 10 pre-existing warnings** in `SortingModelResizeQueueTests.swift`, `AVFoundationMediaPipelineTests.swift`, `ClipFrameReader.swift` and `ComparisonModel.swift`, and `AVFoundationMediaPipelineTests` has a known intermittent flake ("video input never became ready" — re-run once). **Do not fix either.** Check only your own files, and force recompilation, because an incremental build reports 0 falsely:
  `touch <your files> && env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --build-tests 2>&1 | grep "warning:" | grep -E "<your files>"`
- **`Sources/SkiVideoCore` may not contain `import AppKit`, `import UIKit`, `import SwiftUI`, or `Process(`.** Enforced by `CorePurityTests`. `AuthenticationServices` belongs in the platform targets, never in core.
- **No test may reach the network**, write outside a temporary directory, or touch the real Keychain.
- **No credential in a URL, ever.** Measured 2026-08-13: `?access_token=` on Drive's `alt=media` path returns a 403 HTML page; `Authorization: Bearer` returns 206 and bytes.
- **Do not edit a pre-existing test to make a change pass.** Deleting one together with its subject is different, and must be stated in the report.
- Baseline at head: **651 tests, 2 skipped, 0 failures**, app target builds. It must stay green.
- Swift language mode v5. Platforms macOS 13, iOS 17. Git root `/Users/ulfnielsen/Ski/script`; package in `SkiVideoViewer/`.

## Test discipline, because this plan's predecessors kept failing it

Across plans 1 and 2, **five tests passed while being unable to fail** — a one-file fixture for a mid-stream failure, two clips in one folder for a folder-ordering test, a version fixture that failed to decode before reaching the version check, a one-clip library for a picker invariant, and a characterisation test that never instantiated the model it characterised.

So for every test in this plan, the author of the task must be able to answer: **what change to the implementation would make this fail?** If the honest answer is "none" or "only deleting the function", the fixture is too small. Where a test's discriminating power is not obvious, this plan says so in the test's own doc comment, and that sentence is part of the requirement.

## Decisions already made, with their evidence

**The audience is Internal.** Verified against Google's docs: an app whose OAuth audience is limited to one Workspace organisation is exempt from verification *and* from the annual CASA security assessment that `drive.readonly` — a restricted scope — otherwise triggers. No 100-user cap, no 7-day refresh-token expiry. The Cloud project must sit in the organisation, and anyone outside it gets a hard `org_internal` error rather than a request-access prompt.

**Two OAuth clients, two redirect strategies.** Verified: loopback redirects (`http://127.0.0.1:port`) have been **blocked for iOS clients since 21 October 2022**, and the out-of-band paste-the-code flow is dead for every client type since 31 January 2023. macOS uses a Desktop client with the loopback listener `AppKitOAuthPresenter` already implements; iPad needs an iOS client and a reverse-DNS custom scheme. **iOS clients have no client secret at all**, which is why Task 2 makes it optional.

**Sign-in must leave the app.** Google blocks authorization requests from embedded webviews with `disallowed_useragent`, naming `WKWebView` explicitly. Task 7 uses `ASWebAuthenticationSession`.

## What this plan does not do

- **Pinning UI.** `ClipCache.pin`/`unpin` exist and are tested; no control calls them.
- **A cache-budget setting.** `setBudget` exists; the default stands.
- **Writing analysis back to Drive.** Out of scope in the spec, and this plan adds no write scope.
- **Making `ComparisonVideoChoice.playbackURL` optional.** Task 6 fetches on select instead, which is the cheaper way to keep a pane from being handed something it cannot open.

---

### Task 1: Analysis follows the clip, not the cache path

**Files:**
- Modify: `Sources/SkiVideoCore/ComparisonChoices.swift`
- Modify: `Sources/SkiVideoCore/ComparisonModel.swift`
- Modify: `Sources/SkiVideoCore/ViewerModel.swift`
- Modify: `Sources/SkiVideoViewer/Shared/ComparisonView.swift`
- Test: `Tests/SkiVideoCoreTests/ComparisonModelTests.swift`, `Tests/SkiVideoViewerTests/RemoteAnalysisIdentityTests.swift` (create)

**Interfaces:**
- Consumes: `ClipIdentity`, `RemoteLibraryIndex.file(for:)`, `RemoteFile.identity(inProvider:)`.
- Produces: `ComparisonVideoChoice.identity`, `ComparisonModel.identity(for side:)`, `ViewerModel.currentClipIdentity`.

A cloud clip's playback URL is a file under `Caches`. Passing it to `ClipAnalysisStore` files the sidecar there, where eviction orphans it and iOS may purge it. The identity has to travel with the clip.

- [ ] **Step 1: Write the failing test**

Create `Tests/SkiVideoViewerTests/RemoteAnalysisIdentityTests.swift`:

```swift
import XCTest
@testable import SkiVideoCore

@MainActor
final class RemoteAnalysisIdentityTests: XCTestCase {
    /// A cloud clip's analysis must be keyed on the clip, not on wherever its
    /// bytes happen to sit. The cache path is under `Caches`, which eviction
    /// reclaims and iOS may purge outright — a sidecar written there is gone
    /// the first time the budget is tight.
    ///
    /// This fails if `currentClipIdentity` returns `.local(playbackURL)`: the
    /// assertion names the remote case explicitly rather than checking "not
    /// nil", so returning the cache path cannot satisfy it.
    func testACloudClipIsIdentifiedByItsFileIDNotItsCachePath() async throws {
        let (model, provider, cache) = try remoteModel(
            files: [remoteFile("1AbC", "run.mp4", ["Neuss 2026", "Ada"])]
        )
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )
        try await model.prepareCurrentClip()

        // The clip really is cached — otherwise this test would pass simply
        // because nothing had been downloaded.
        XCTAssertEqual(model.currentPlaybackURL?.isFileURL, true)
        XCTAssertEqual(
            model.currentClipIdentity,
            .remote(provider: "fake", fileID: "1AbC")
        )
    }

    /// A local clip must still be identified by its own URL — the change must
    /// not route local analysis through anything new.
    func testALocalClipIsStillIdentifiedByItsOwnURL() throws {
        let (model, root) = try localModel(clipNamed: "run1.mp4")
        model.openDirectory(root)

        let identity = try XCTUnwrap(model.currentClipIdentity)
        guard case let .local(url) = identity else {
            return XCTFail("expected .local, got \(identity)")
        }
        XCTAssertEqual(url.lastPathComponent, "run1.mp4")
    }

    /// The comparison window is where the defect actually bit: it reads a
    /// per-side URL and hands it straight to the analysis stores. Each side
    /// must carry its identity so it never has to derive one from a path.
    func testEachComparisonSideCarriesItsOwnIdentity() async throws {
        let (model, provider, cache) = try remoteModel(files: [
            remoteFile("a", "run1.mp4", ["Neuss 2026", "Ada"]),
            remoteFile("b", "run2.mp4", ["Neuss 2026", "Ada"]),
        ])
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )

        let choices = try XCTUnwrap(model.comparisonLibrary.first?.videos)
        XCTAssertEqual(
            choices.map(\.identity),
            [.remote(provider: "fake", fileID: "a"), .remote(provider: "fake", fileID: "b")]
        )
    }
}
```

> The three helpers — `remoteModel(files:)`, `localModel(clipNamed:)` and `remoteFile(_:_:_:)` — do not exist yet. `RemoteLibraryWiringTests` already builds a `ViewerModel` with a `FakeRemoteProvider` and a `ClipCache` over a temp directory; extract that setup into a shared helper file `Tests/SkiVideoCoreTests/RemoteLibraryTestSupport.swift` and use it from both suites rather than copying it. Say in your report what you extracted.

- [ ] **Step 2: Run test to verify it fails**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter RemoteAnalysisIdentityTests
```
Expected: FAIL to compile — `value of type 'ViewerModel' has no member 'currentClipIdentity'`.

- [ ] **Step 3: Carry the identity on a comparison choice**

In `Sources/SkiVideoCore/ComparisonChoices.swift`, add to `ComparisonVideoChoice`:

```swift
    /// What this clip's analysis is filed under.
    ///
    /// Carried rather than derived from `playbackURL`, because for a cloud
    /// clip that URL is a path under `Caches` — a sidecar written there is
    /// reclaimed by cache eviction and may be purged by iOS outright. The
    /// identity is the one thing about a clip that does not move.
    public let identity: ClipIdentity
```

Thread it through the initialiser, and in `ViewerModel.comparisonLibrary` supply
`remoteIndex?.file(for: video).map { $0.identity(inProvider: remoteIndex!.providerIdentifier) } ?? ClipIdentity(video)`
— written as a small private helper rather than that expression, since Task 6 needs it too:

```swift
    /// What the analysis stores should file this clip under. A cloud clip is
    /// its provider and file id; a local clip is its own URL.
    func identity(of video: URL) -> ClipIdentity {
        guard let remoteIndex, let file = remoteIndex.file(for: video) else {
            return ClipIdentity(video)
        }
        return file.identity(inProvider: remoteIndex.providerIdentifier)
    }

    /// The selected clip's identity, or nil when nothing is selected.
    public var currentClipIdentity: ClipIdentity? {
        currentVideo.map(identity(of:))
    }
```

- [ ] **Step 4: Carry it through the comparison model and view**

`ComparisonModel` already tracks a left and right choice. Add `identity(for side: ComparisonSide) -> ClipIdentity?` reading the stored choice's `identity`, and in `ComparisonView`:

- `loadStoredSubject(_:)` (`ComparisonView.swift:346-349`) passes `model.identity(for: side)` to `session.loadStored(for:)` instead of the clip URL.
- `session.confirm(…, for:)` (`:466`) likewise.
- `loadStoredAlignment()` (`:233-245`) passes both sides' identities to `alignment.loadStored(left:right:)`.

`SubjectSessionModel` and `AlignmentSessionModel` already have identity-taking store calls from plan 1; give the models themselves identity-taking signatures so the view stops holding a URL for this purpose at all. **If a session model's public API cannot take an identity without a change larger than this task's file list, stop and report it** rather than converting at the call site — converting at the call site is what put a cache path in a sidecar in the first place.

- [ ] **Step 5: Run the tests**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter "RemoteAnalysisIdentityTests|ComparisonModelTests|SubjectSessionModelTests|AlignmentSessionModelTests"
```
Expected: PASS, with no pre-existing test edited.

- [ ] **Step 6: Run the full suite and commit**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -5
git add -A SkiVideoViewer/Sources SkiVideoViewer/Tests
git commit -m "File a cloud clip's analysis under the clip, not under the cache

A cached clip reaches the analysis stores as a path in Caches, so its sidecar
landed somewhere eviction reclaims and iOS may purge — which is exactly what the
identity-keyed store was built to avoid. The identity now travels with the clip
instead of being derived from wherever its bytes are sitting."
```

---

### Task 2: An OAuth flow that fits both platforms

**Files:**
- Modify: `Sources/SkiVideoCore/GoogleOAuth.swift`
- Test: `Tests/SkiVideoCoreTests/GoogleOAuthTests.swift` (create)

**Interfaces:**
- Produces: `GoogleOAuthConfiguration(clientID:clientSecret:redirectKind:)`, `GoogleOAuth.authorize(configuration:presenter:)`, `GoogleOAuth.accessToken(configuration:)`, and two new `DriveError` cases.

Two changes. The client secret becomes optional, because **iOS OAuth clients have none**. And two sign-in failures get their own cases, because both are policy problems no retry fixes and a generic message would leave a coach guessing.

- [ ] **Step 1: Write the failing test**

Create `Tests/SkiVideoCoreTests/GoogleOAuthTests.swift`:

```swift
import XCTest
@testable import SkiVideoCore

final class GoogleOAuthTests: XCTestCase {
    private func configuration(secret: String?) -> GoogleOAuthConfiguration {
        GoogleOAuthConfiguration(
            clientID: "123.apps.googleusercontent.com",
            clientSecret: secret,
            redirectKind: .loopback
        )
    }

    /// An iOS client has no secret at all, so the exchange must be able to
    /// omit it — not send an empty one, which Google rejects.
    ///
    /// Fails if the body is built by unconditionally interpolating the secret:
    /// the assertion is that the key is *absent*, not that it is empty.
    func testATokenRequestOmitsTheSecretEntirelyWhenThereIsNone() throws {
        let body = GoogleOAuth.tokenRequestBody(
            values: ["grant_type": "refresh_token"],
            configuration: configuration(secret: nil)
        )
        XCTAssertFalse(body.contains("client_secret"), "got \(body)")
        XCTAssertTrue(body.contains("client_id="))
    }

    func testATokenRequestIncludesTheSecretWhenThereIsOne() throws {
        let body = GoogleOAuth.tokenRequestBody(
            values: ["grant_type": "refresh_token"],
            configuration: configuration(secret: "shh")
        )
        XCTAssertTrue(body.contains("client_secret=shh"), "got \(body)")
    }

    /// Both of these are policy problems that no amount of retrying fixes, and
    /// a coach reading "sign-in failed" would try again forever. Each gets a
    /// message naming what has to change and who can change it.
    func testAnOrgInternalErrorSaysTheAccountIsWrongNotThatSignInFailed() {
        let message = DriveError.notInOrganisation.errorDescription ?? ""
        XCTAssertTrue(message.lowercased().contains("account"), "got \(message)")
        XCTAssertFalse(message.lowercased().contains("try again"), "got \(message)")
    }

    func testAnAdminPolicyErrorNamesTheAdministrator() {
        let message = DriveError.blockedByAdministrator.errorDescription ?? ""
        XCTAssertTrue(message.lowercased().contains("administrator"), "got \(message)")
    }

    /// The callback carries the reason in a query parameter; mapping it is how
    /// the two cases above ever get constructed.
    func testTheCallbacksErrorParameterMapsToTheSpecificCase() {
        XCTAssertEqual(
            GoogleOAuth.error(fromCallback: URL(string: "x://cb?error=org_internal")!),
            .notInOrganisation
        )
        XCTAssertEqual(
            GoogleOAuth.error(fromCallback: URL(string: "x://cb?error=admin_policy_enforced")!),
            .blockedByAdministrator
        )
        XCTAssertNil(GoogleOAuth.error(fromCallback: URL(string: "x://cb?code=abc")!))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter GoogleOAuthTests
```
Expected: FAIL to compile — `cannot find 'GoogleOAuthConfiguration' in scope`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/SkiVideoCore/GoogleOAuth.swift`, add:

```swift
/// How this platform receives the authorization redirect.
///
/// Not a detail: loopback has been blocked for iOS OAuth clients since
/// 21 October 2022, and the out-of-band paste-the-code flow is dead for every
/// client type since 31 January 2023. macOS uses a Desktop client and a
/// loopback listener; iPad uses an iOS client and a reverse-DNS scheme.
public enum GoogleRedirectKind: Sendable {
    case loopback
    case customScheme(String)
}

public struct GoogleOAuthConfiguration: Sendable {
    public let clientID: String
    /// Absent for an iOS client, which Google issues without one. The token
    /// request must then omit the field rather than send it empty.
    public let clientSecret: String?
    public let redirectKind: GoogleRedirectKind

    public init(clientID: String, clientSecret: String?, redirectKind: GoogleRedirectKind) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectKind = redirectKind
    }
}
```

Add the two `DriveError` cases with messages that name the fix:

```swift
    /// The account is outside the club's Workspace. Google refuses these
    /// outright for an Internal app — there is no request-access prompt — so
    /// the message has to say which account to use instead.
    case notInOrganisation
    /// A Workspace administrator has not allowed this app under
    /// Admin console → API controls. Nothing the coach can do.
    case blockedByAdministrator
```

with descriptions along the lines of *"This Google account is not in the club's Workspace. Sign in with your club account."* and *"A Workspace administrator has to allow this app under Admin console → API controls before it can open the club's Drive."*

Extract the form-body construction into a testable function that omits an absent secret, and add `GoogleOAuth.error(fromCallback:)` mapping the callback's `error` parameter to those cases (returning nil when there is no error). Rework `authorize` to take a `GoogleOAuthConfiguration` rather than reading a client-secrets JSON file.

- [ ] **Step 4: Run the tests, then the suite, then commit**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GoogleOAuthTests
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -5
git add SkiVideoViewer/Sources/SkiVideoCore/GoogleOAuth.swift \
        SkiVideoViewer/Tests/SkiVideoCoreTests/GoogleOAuthTests.swift
git commit -m "Let one sign-in flow serve a client with no secret

An iOS OAuth client is issued without a secret, so the token request has to omit
the field rather than send it empty. The same flow now describes its redirect
rather than assuming a loopback listener, because loopback has been blocked for
iOS clients since 2022.

Two failures get their own cases: an account outside the club's Workspace, which
Google refuses outright with no request-access prompt, and an app an
administrator has not allowed. Neither is retryable, and a generic sign-in error
would have a coach trying again forever."
```

---

### Task 3: `connect` actually connects

**Files:**
- Modify: `Sources/SkiVideoCore/GoogleDriveProvider.swift`
- Test: `Tests/SkiVideoCoreTests/GoogleDriveProviderTests.swift`

**Interfaces:**
- Produces: `GoogleDriveProvider(configuration:transport:)`, a `connect` that performs the flow and stores the refresh token, and a token source that refreshes on demand.

- [ ] **Step 1: Write the failing test**

Append to `GoogleDriveProviderTests`:

```swift
    // MARK: - Sign-in

    /// `connect` must run the flow and leave the provider able to authorize —
    /// asserted by a subsequent request carrying the bearer token, not by
    /// `connect` merely returning. A no-op `connect` would pass the second
    /// check alone.
    func testConnectLeavesTheProviderAbleToAuthorizeRequests() async throws {
        let presenter = FakeOAuthPresenter()
        presenter.callbackToReturn = URL(string: "http://127.0.0.1:1/?code=abc&state=STATE")!
        transport.responses = [
            .init(json: #"{"access_token":"at-1","refresh_token":"rt-1"}"#),
            .init(json: #"{"drives":[]}"#),
        ]

        try await provider.connect(presenter: presenter)
        _ = try await provider.roots()

        XCTAssertEqual(
            transport.requests.last?.value(forHTTPHeaderField: "Authorization"),
            "Bearer at-1"
        )
    }

    /// Before `connect`, a request must fail rather than go out unauthenticated
    /// — an unauthenticated Drive media request comes back as an HTML block
    /// page, which is a far worse thing to debug.
    func testAnUnconnectedProviderRefusesToRequestAnything() async {
        do {
            _ = try await provider.roots()
            XCTFail("expected .notSignedIn")
        } catch let error as RemoteLibraryError {
            XCTAssertEqual(error, .notSignedIn)
        } catch {
            XCTFail("expected RemoteLibraryError, got \(error)")
        }
    }
```

> `provider` in this suite is currently built with a `token:` closure that always returns a token. These two tests need one built from a `GoogleOAuthConfiguration` with no stored credential. Add a second factory in the suite rather than changing the existing `setUp`, so the pre-existing tests keep their fixture.

- [ ] **Step 2: Run to verify it fails, then implement**

Give `GoogleDriveProvider` an initialiser taking a configuration, holding the refresh token in the Keychain via the existing `KeychainTokenStore` and exchanging it for an access token on demand. `connect(presenter:)` runs `GoogleOAuth.authorize` and stores the result. Keep the `token:`-closure initialiser — plan 2's tests use it and it is the seam that keeps these tests off the network.

**The Keychain must not be touched by tests.** Inject the token store rather than calling `KeychainTokenStore` directly from the provider; if that requires a protocol, add one and say so.

- [ ] **Step 3: Run the suite and commit**

Commit message subject: `Make signing in the thing that authorizes a request`.

---

### Task 4: Sign in, then pick a drive

**Files:**
- Rewrite: `Sources/SkiVideoViewer/Shared/GoogleDriveSheet.swift`
- Modify: `Sources/SkiVideoViewer/Shared/ContentView.swift`
- Modify: `Sources/SkiVideoCore/ViewerModel.swift`
- Test: `Tests/SkiVideoViewerTests/SignInWiringTests.swift` (create)

**Interfaces:**
- Produces: `ViewerModel.signIn()`, `ViewerModel.availableRoots`, `ViewerModel.chooseRoot(_:)`, `ViewerModel.signInError`.

The sheet stops asking for a client-secret file and a pasted folder id. It offers one button, then a list.

- [ ] **Step 1: Write the failing test**

Create `Tests/SkiVideoViewerTests/SignInWiringTests.swift` with tests that:

- After `signIn()`, `availableRoots` holds what the provider's `roots()` returned — with **two** roots in the fixture, so a implementation returning only the first cannot pass.
- `chooseRoot(_:)` opens that root's library and fills the sidebar.
- A `connect` that throws `.notInOrganisation` leaves `signInError` carrying that case's message and `availableRoots` empty — asserted on the specific message, so a generic error cannot satisfy it.
- Signing in does **not** download anything: assert the fake downloader recorded no requests. This is what keeps a 74 GB library from being fetched on connect.

- [ ] **Step 2: Implement, run, commit**

The sheet shows: a **Sign in with Google** button while `availableRoots` is empty; the list of drives once it is not; and `signInError` inline when set. `ContentView`'s toolbar label becomes **Open Club Library…**.

Commit message subject: `Offer the drives a coach can see, instead of asking for an id`.

---

### Task 5: Relaunch as a delta

**Files:**
- Modify: `Sources/SkiVideoCore/ViewerModel.swift`
- Test: `Tests/SkiVideoViewerTests/SignInWiringTests.swift`

Plan 2 built `RemoteLibraryIndex.save`/`load`/`applying` and the changes cursor, and nothing calls them.

- [ ] **Step 1: Write the failing test**

Tests that:
- Opening a root twice sweeps **once**: assert the provider's enumeration count, with the second open served from the stored index.
- A stored index plus a change adding a file shows the new clip without a re-sweep — the fake provider must adopt `IncrementallyEnumerable` for this, which is also the first real exercise of that protocol.
- **A removal does not delete cached bytes.** Materialise a clip, apply a change removing it, and assert the file is still on disk. This is the rule plan 2 documented and nothing yet enforces: Drive reports lost access and a corpus move identically to a deletion.

- [ ] **Step 2: Implement, run, commit**

`openRemoteLibrary` loads a stored index first; if one exists and the provider is `IncrementallyEnumerable`, refresh via `changes(since:forRoot:)` and save; otherwise sweep, take a start cursor, and save.

Commit message subject: `Ask what changed instead of listing the drive again`.

---

### Task 6: Selecting a clip fetches it

**Files:**
- Modify: `Sources/SkiVideoCore/ViewerModel.swift`
- Modify: `Sources/SkiVideoCore/ComparisonModel.swift`
- Test: `Tests/SkiVideoViewerTests/FetchOnSelectTests.swift` (create)

**Interfaces:**
- Produces: fetch-on-select for the viewer and for a comparison pane; prefetch of the neighbouring clips.

- [ ] **Step 1: Write the failing test**

Tests that:
- Changing the selected clip fetches it without anything else asking.
- Selecting a clip in a comparison pane fetches *that* clip — closing the gap `testTheComparisonPickerOffersAFileOnlyForAPreparedClip` pins. **That test's second assertion must be inverted as part of this task**, and its "KNOWN GAP" message deleted; say so in your report.
- Prefetch reaches the next two and previous one **and no further**: a five-clip athlete with the middle selected must leave clip five unfetched. A test that only asserts neighbours *were* fetched would pass if the implementation fetched everything.
- Moving the selection twice quickly does not leave `isPreparingClip` stuck, and loads the clip that was selected last.

- [ ] **Step 2: Implement, run, commit**

Commit message subject: `Fetch the clip a coach just asked for, and the ones they are about to`.

---

### Task 7: iPad signs in too

**Files:**
- Replace: `Sources/SkiVideoViewer/iOS/UnavailableOAuthPresenter.swift` with `IOSOAuthPresenter.swift`
- Modify: `project.yml` (register the reverse-DNS URL scheme)
- Test: `Tests/SkiVideoViewerTests/…` — only the redirect-URI construction is testable

`ASWebAuthenticationSession` hands off to a system browser, which is what Google requires: embedded webviews are blocked with `disallowed_useragent`, `WKWebView` named explicitly.

- [ ] **Step 1: Implement and verify**

`prepareRedirectURI()` returns the reverse-DNS scheme (`com.googleusercontent.apps.NNN:/oauth2redirect`) rather than a loopback URL — loopback is blocked for iOS clients. `authorize` presents an `ASWebAuthenticationSession` with that callback scheme.

Register the scheme in `project.yml` under the iPad target's `CFBundleURLTypes`, then `cd SkiVideoViewer && xcodegen generate` and run `scripts/ipad-smoke.sh`.

> **This task cannot be verified end to end without a second Google Cloud OAuth client** of type iOS, registered against bundle id `ch.ski.video-viewer.ipad`. If that does not exist yet, implement and unit-test the redirect construction, and **report the task as blocked on that registration** rather than claiming it works.

Commit message subject: `Sign in on iPad, where loopback is not allowed`.

---

## Definition of done

- [ ] `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` passes in full.
- [ ] A coach can sign in, choose a Shared Drive, click a clip, and watch it.
- [ ] Analysis for a cloud clip is filed under `.remote(provider:fileID:)`, never under a cache path — assert by finding no `.skianalysis.json` under the cache directory after analysing a cloud clip.
- [ ] Opening the same drive twice sweeps once.
- [ ] Signing in downloads nothing.
- [ ] A removal in Drive does not delete cached bytes.
- [ ] No test touches the network or the real Keychain.
- [ ] The 10 pre-existing warnings are unchanged; none added.
- [ ] A local library behaves exactly as before.

## Setup this plan needs from a human

Two Google Cloud OAuth clients in a project **owned by the club's Workspace organisation**, with the consent screen's audience set to **Internal** — that is what makes `drive.readonly` exempt from verification and the annual CASA assessment:

1. **Desktop app** — for macOS, using the loopback redirect.
2. **iOS** — bundle id `ch.ski.video-viewer.ipad`, for Task 7. Issued with no client secret.

A Workspace administrator may also need to allow the app under **Admin console → API controls**; `blockedByAdministrator` exists to say so when they have not.
