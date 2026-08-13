# Sign-in, the Drive Picker, and Fetching on Select Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **A note on the tests below, and why they read the way they do.** Across
> plans 1 and 2, five tests passed while being unable to fail — every one from
> a fixture too small to express the case it claimed to test: one file for a
> mid-stream failure, two clips in one folder for a folder-ordering test, a
> version fixture that failed to decode before reaching the version check, a
> one-clip library for a picker invariant, and a characterisation test that
> never instantiated the model it characterised.
>
> So several tests here carry a sentence naming the implementation change that
> would make them fail, and several use deliberately awkward fixtures — five
> clips rather than two, two drives rather than one, an assertion that a clip
> was *not* fetched. Those are the requirement, not decoration. If a fixture
> here looks larger than it needs to be, that is the reason.

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

- [ ] **Step 1: Extend the fake so a sign-in can fail**

`FakeRemoteProvider` currently always connects. Add to it:

```swift
    /// Thrown by `connect`, so a test can exercise a refused sign-in without
    /// a network or a real Google account.
    var connectError: Error?
```

and make `connect` throw it before incrementing the counter.

- [ ] **Step 2: Write the failing test**

Create `Tests/SkiVideoViewerTests/SignInWiringTests.swift`:

```swift
import XCTest
@testable import SkiVideoCore

@MainActor
final class SignInWiringTests: XCTestCase {
    /// Two drives, not one. An implementation that returned only the first —
    /// or that stopped at the first page — passes a single-drive fixture, and
    /// a club with an archive drive would silently see half its footage.
    func testSigningInOffersEveryDriveTheAccountCanSee() async throws {
        let (model, provider, _) = try remoteModel(files: [])
        provider.rootsToReturn = [
            RemoteFolder(id: "d1", name: "Club Footage"),
            RemoteFolder(id: "d2", name: "Archive"),
        ]

        await model.signIn(with: provider)

        XCTAssertEqual(model.availableRoots.map(\.name), ["Club Footage", "Archive"])
        XCTAssertNil(model.signInError)
    }

    func testChoosingADriveFillsTheSidebar() async throws {
        let (model, provider, cache) = try remoteModel(files: [
            remoteFile("a", "run1.mp4", ["Neuss 2026", "Ada"]),
        ])
        await model.signIn(with: provider)

        await model.chooseRoot(RemoteFolder(id: "d1", name: "Club"), cache: cache)

        XCTAssertEqual(model.athletes.map(\.name), ["Ada"])
    }

    /// An account outside the club's Workspace is refused outright by Google —
    /// there is no request-access prompt — so the message must name the
    /// account, not say "sign-in failed". Asserted on the specific wording:
    /// a generic error string cannot satisfy it.
    func testAnAccountOutsideTheClubGetsThatMessageNotAGenericFailure() async throws {
        let (model, provider, _) = try remoteModel(files: [])
        provider.connectError = DriveError.notInOrganisation

        await model.signIn(with: provider)

        let message = try XCTUnwrap(model.signInError)
        XCTAssertTrue(message.lowercased().contains("account"), "got \(message)")
        XCTAssertTrue(model.availableRoots.isEmpty, "a refused sign-in must offer nothing")
    }

    /// Signing in must not fetch a single byte. The library is 74 GB; an
    /// implementation that materialised eagerly would download it on connect.
    /// Asserted on the downloader, which is the only thing that can tell.
    func testSigningInAndChoosingADriveDownloadsNothing() async throws {
        let (model, provider, cache, downloader) = try remoteModelWithDownloader(files: [
            remoteFile("a", "run1.mp4", ["Neuss 2026", "Ada"]),
            remoteFile("b", "run2.mp4", ["Neuss 2026", "Ada"]),
        ])
        await model.signIn(with: provider)
        await model.chooseRoot(RemoteFolder(id: "d1", name: "Club"), cache: cache)

        XCTAssertEqual(
            downloader.requestedFileIDs, [],
            "listing a library must not fetch its clips"
        )
    }
}
```

> `remoteModelWithDownloader(files:)` returns the same tuple as `remoteModel` plus the `FakeClipDownloader`, so a test can assert on what was fetched. Add it to `RemoteLibraryTestSupport.swift` (Task 1) and have `remoteModel` call through to it.

- [ ] **Step 3: Run test to verify it fails**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter SignInWiringTests
```
Expected: FAIL to compile — `value of type 'ViewerModel' has no member 'signIn'`.

- [ ] **Step 4: Write minimal implementation**

Add to `ViewerModel`:

```swift
    /// The drives sign-in found, or empty before signing in and after a
    /// failure. The sheet shows a button while this is empty and a list once
    /// it is not, so the two states need no separate flag.
    @Published public private(set) var availableRoots: [RemoteFolder] = []
    /// Why the last sign-in failed, for the sheet to show inline. Nil clears
    /// it on the next attempt.
    @Published public private(set) var signInError: String?

    /// Signs in and asks which drives this account can see. Fetches nothing:
    /// the library is gigabytes and a coach has picked no clip yet.
    public func signIn(with provider: any RemoteLibraryProvider) async {
        signInError = nil
        do {
            try await provider.connect(presenter: oauthPresenter)
            availableRoots = try await provider.roots()
            remoteProvider = provider
            status = availableRoots.isEmpty
                ? "No shared drives are visible to this account."
                : "Choose a drive"
        } catch {
            availableRoots = []
            signInError = error.localizedDescription
            status = "Could not sign in"
        }
    }

    /// Opens the chosen drive's library. Separate from `signIn` because a
    /// coach in several drives picks one, and because the picker must be able
    /// to reappear without signing in again.
    public func chooseRoot(_ root: RemoteFolder, cache: ClipCache) async {
        guard let remoteProvider else { return }
        do {
            try await openRemoteLibrary(provider: remoteProvider, root: root, cache: cache)
            availableRoots = []
        } catch {
            signInError = error.localizedDescription
        }
    }
```

- [ ] **Step 5: Rewrite the sheet**

`Sources/SkiVideoViewer/Shared/GoogleDriveSheet.swift` becomes: a **Sign in with Google** button while `model.availableRoots.isEmpty`; a list of drive names once it is not, each choosing that root and dismissing; `model.signInError` shown inline in red when set. No text field of any kind — the client-secret path and the pasted folder id are both gone.

In `ContentView.swift`, the toolbar label becomes **Open Club Library…**.

The sheet needs a `ClipCache` to pass to `chooseRoot`. Construct one where `ContentView` builds the model, with the budget from the spec — 20 GB on macOS, 5 GB on iPadOS — and hand it down. Put the cache root under `Caches` and the pinned root under Application Support, as `ClipCache` documents.

- [ ] **Step 6: Run the suite and commit**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -5
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | tail -3
git add -A SkiVideoViewer/Sources SkiVideoViewer/Tests
git commit -m "Offer the drives a coach can see, instead of asking for an id

The sheet asked for an OAuth client-secret file and a pasted folder id, which
meant only the person who set it up could ever connect. It now signs in and
lists the drives the account can actually see.

Listing fetches nothing. The library is 74 GB and the coach has not chosen a
clip yet, so a connect that materialised eagerly would download all of it."
```

---

### Task 5: Relaunch as a delta

**Files:**
- Modify: `Sources/SkiVideoCore/ViewerModel.swift`
- Test: `Tests/SkiVideoViewerTests/SignInWiringTests.swift`

Plan 2 built `RemoteLibraryIndex.save`/`load`/`applying` and the changes cursor, and nothing calls them.

- [ ] **Step 1: Make the fake incremental**

`FakeRemoteProvider` must adopt `IncrementallyEnumerable` — this is also the protocol's first exercise by anything but its own unit tests. Add to `Tests/SkiVideoCoreTests/FakeRemoteProvider.swift`:

```swift
extension FakeRemoteProvider: IncrementallyEnumerable {
    func startCursor(forRoot rootID: String) async throws -> String {
        cursorsIssued += 1
        return "cursor-\(cursorsIssued)"
    }

    func changes(since cursor: String, forRoot rootID: String) async throws -> RemoteLibraryChanges {
        changesRequestedSince.append(cursor)
        return pendingChanges ?? RemoteLibraryChanges(changed: [], removed: [], cursor: cursor)
    }
}
```

with stored properties `var cursorsIssued = 0`, `private(set) var changesRequestedSince: [String] = []`, `var pendingChanges: RemoteLibraryChanges?`, and an `private(set) var enumerateCallCount = 0` incremented in `enumerate`.

- [ ] **Step 2: Write the failing test**

Append to `Tests/SkiVideoViewerTests/SignInWiringTests.swift`:

```swift
    // MARK: - Relaunch

    /// The whole point of the cursor: a second open must not list the drive
    /// again. Asserted on the enumeration count, which is the only thing that
    /// distinguishes "loaded the stored index" from "swept and got the same
    /// answer" — the sidebar looks identical either way.
    func testOpeningTheSameDriveTwiceSweepsOnce() async throws {
        try withTemporaryIndexStore {
            let (model, provider, cache) = try remoteModel(files: [
                remoteFile("a", "run1.mp4", ["Neuss 2026", "Ada"]),
            ])
            let root = RemoteFolder(id: "d1", name: "Club")

            try await model.openRemoteLibrary(provider: provider, root: root, cache: cache)
            try await model.openRemoteLibrary(provider: provider, root: root, cache: cache)

            XCTAssertEqual(provider.enumerateCallCount, 1)
            XCTAssertEqual(provider.changesRequestedSince.count, 1, "the second open asks for a delta")
            XCTAssertEqual(model.athletes.map(\.name), ["Ada"])
        }
    }

    /// A clip uploaded while the app was closed appears without a re-sweep.
    /// The new clip is what proves the change was applied rather than the
    /// stored index simply reloaded.
    func testAClipAddedInDriveAppearsFromTheChangeFeed() async throws {
        try withTemporaryIndexStore {
            let (model, provider, cache) = try remoteModel(files: [
                remoteFile("a", "run1.mp4", ["Neuss 2026", "Ada"]),
            ])
            let root = RemoteFolder(id: "d1", name: "Club")
            try await model.openRemoteLibrary(provider: provider, root: root, cache: cache)

            provider.pendingChanges = RemoteLibraryChanges(
                changed: [remoteFile("b", "run2.mp4", ["Neuss 2026", "Ada"])],
                removed: [], cursor: "cursor-2"
            )
            try await model.openRemoteLibrary(provider: provider, root: root, cache: cache)

            XCTAssertEqual(provider.enumerateCallCount, 1, "still no re-sweep")
            XCTAssertEqual(
                model.athletes.first?.videos.map(\.lastPathComponent),
                ["run1.mp4", "run2.mp4"]
            )
        }
    }

    /// A `removed` change must drop the clip from the library and leave its
    /// bytes alone. Drive reports lost access and a corpus move exactly as it
    /// reports a deletion, so a coach who regains access must not pay to
    /// download a clip that never left the disk.
    ///
    /// Fails if the removal path calls anything on the cache: the assertion is
    /// on the file existing, which only survives if nothing deleted it.
    func testARemovedClipLeavesTheLibraryButNotTheDisk() async throws {
        try withTemporaryIndexStore {
            let (model, provider, cache) = try remoteModel(files: [
                remoteFile("a", "run1.mp4", ["Neuss 2026", "Ada"]),
                remoteFile("b", "run2.mp4", ["Neuss 2026", "Ada"]),
            ])
            let root = RemoteFolder(id: "d1", name: "Club")
            try await model.openRemoteLibrary(provider: provider, root: root, cache: cache)
            try await model.prepareCurrentClip()
            let cached = try XCTUnwrap(model.currentPlaybackURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path))

            provider.pendingChanges = RemoteLibraryChanges(
                changed: [], removed: ["a"], cursor: "cursor-2"
            )
            try await model.openRemoteLibrary(provider: provider, root: root, cache: cache)

            XCTAssertEqual(
                model.athletes.first?.videos.map(\.lastPathComponent), ["run2.mp4"],
                "the removed clip leaves the sidebar"
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: cached.path),
                "its bytes must stay: Drive reports lost access the same way"
            )
        }
    }
```

> `withTemporaryIndexStore` points `RemoteLibraryIndex.storeRoot` at a temp directory and restores it in `defer`, exactly as `RemoteLibraryIndexTests` does. Put it in `RemoteLibraryTestSupport.swift` and have both suites use the one copy — it exists in three places already, which the plan-2 reviews flagged.

- [ ] **Step 3: Run test to verify it fails**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter SignInWiringTests
```
Expected: FAIL — `enumerateCallCount` is 2, because nothing loads or saves an index yet.

- [ ] **Step 4: Write minimal implementation**

In `ViewerModel.openRemoteLibrary`, before sweeping:

```swift
        // A stored index plus a cursor makes a relaunch a delta. Page tokens
        // never expire and Drive coalesces its change log per file, so an app
        // closed for months still resyncs in a bounded number of calls — where
        // a re-sweep would list the whole drive every time.
        var index = RemoteLibraryIndex.load(forRoot: root.id)
        if let stored = index,
           let cursor = stored.cursor,
           let incremental = provider as? IncrementallyEnumerable {
            let changes = try await incremental.changes(since: cursor, forRoot: root.id)
            // Bytes are never deleted here. A `removed` change means the clip
            // left *this library*, which Drive also reports for lost access
            // and a corpus move — evicting on it would make a coach pay to
            // re-download a clip that never went anywhere.
            index = stored.applying(changes)
        } else if index == nil {
            var files: [RemoteFile] = []
            for try await file in provider.enumerate(root) { files.append(file) }
            var swept = RemoteLibraryIndex(
                providerIdentifier: type(of: provider).identifier,
                rootName: root.name, files: files
            )
            if let incremental = provider as? IncrementallyEnumerable {
                swept = swept.withCursor(try await incremental.startCursor(forRoot: root.id))
            }
            index = swept
        }
```

then use that index for the rest of the method and `try? index?.save(forRoot: root.id)` before returning — a failure to persist is a slower next launch, not a reason to refuse the library the coach can already see.

`RemoteLibraryIndex` needs a `withCursor(_:)` returning a copy carrying it; `applying` already sets one.

- [ ] **Step 5: Run the suite and commit**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -5
git add -A SkiVideoViewer/Sources SkiVideoViewer/Tests
git commit -m "Ask what changed instead of listing the drive again

Plan 2 built the index persistence and the change cursor and called neither, so
every launch swept the whole drive. A second open now drains changes.list from
the stored cursor instead.

A removal drops the clip from the sidebar and leaves its bytes alone. Drive
reports lost access and a corpus move exactly as it reports a deletion, and a
coach who regains access should not pay to download a clip that never left."
```

---

### Task 6: Selecting a clip fetches it

**Files:**
- Modify: `Sources/SkiVideoCore/ViewerModel.swift`
- Modify: `Sources/SkiVideoCore/ComparisonModel.swift`
- Test: `Tests/SkiVideoViewerTests/FetchOnSelectTests.swift` (create)

**Interfaces:**
- Produces: fetch-on-select for the viewer and for a comparison pane; prefetch of the neighbouring clips.

- [ ] **Step 1: Write the failing test**

Create `Tests/SkiVideoViewerTests/FetchOnSelectTests.swift`:

```swift
import XCTest
@testable import SkiVideoCore

@MainActor
final class FetchOnSelectTests: XCTestCase {
    private func fiveClips() -> [RemoteFile] {
        (1...5).map { remoteFile("f\($0)", "run\($0).mp4", ["Neuss 2026", "Ada"]) }
    }

    /// Selecting a clip is what asks for it. Nothing else in the app calls
    /// `prepareCurrentClip`, so without this a coach clicks a clip and watches
    /// an empty pane forever.
    func testChangingTheSelectedClipFetchesIt() async throws {
        let (model, provider, cache, downloader) = try remoteModelWithDownloader(files: fiveClips())
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )

        _ = model.changeVideo(by: 1)
        try await model.settleFetches()

        XCTAssertTrue(
            downloader.requestedFileIDs.contains("f2"),
            "got \(downloader.requestedFileIDs)"
        )
    }

    /// Prefetch reaches the next two and the previous one — and stops.
    /// Selecting clip 3 of 5 must leave clip 5 alone. A test asserting only
    /// that the neighbours *were* fetched would pass an implementation that
    /// fetched the whole athlete, which on a 74 GB library is the difference
    /// between a warm cache and a flooded connection.
    func testPrefetchReachesTheNeighboursAndNoFurther() async throws {
        let (model, provider, cache, downloader) = try remoteModelWithDownloader(files: fiveClips())
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )

        _ = model.changeVideo(by: 2)          // now on run3
        try await model.settleFetches()

        let fetched = Set(downloader.requestedFileIDs)
        XCTAssertTrue(fetched.isSuperset(of: ["f2", "f3", "f4"]), "got \(fetched)")
        XCTAssertFalse(fetched.contains("f5"), "prefetch reached too far: \(fetched)")
    }

    /// A comparison pane must fetch the clip it was given. This closes the gap
    /// plan 2 pinned deliberately: before this, a pane was handed the raw
    /// library URL and could open nothing.
    func testChoosingAClipForAComparisonPaneFetchesIt() async throws {
        let (model, provider, cache, downloader) = try remoteModelWithDownloader(files: fiveClips())
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )
        let choice = try XCTUnwrap(model.comparisonLibrary.first?.videos.last)

        let comparison = ComparisonModel()
        await comparison.load(choice, side: .left, fetching: model)

        XCTAssertTrue(downloader.requestedFileIDs.contains("f5"), "got \(downloader.requestedFileIDs)")
        XCTAssertEqual(comparison.playbackURL(for: .left)?.isFileURL, true)
    }

    /// Moving twice quickly must load what was selected *last*, not whichever
    /// download happened to finish last. The gate holds the first fetch open
    /// past the second selection, which is the ordering that would otherwise
    /// leave the wrong clip on screen.
    func testMovingTwiceQuicklyLoadsTheClipSelectedLast() async throws {
        let (model, provider, cache, downloader) = try remoteModelWithDownloader(files: fiveClips())
        try await model.openRemoteLibrary(
            provider: provider, root: RemoteFolder(id: "d1", name: "Club"), cache: cache
        )
        downloader.shouldWait = true

        _ = model.changeVideo(by: 1)          // run2, blocked
        _ = model.changeVideo(by: 1)          // run3, blocked
        downloader.release("f2")              // the stale one finishes first
        downloader.release("f3")
        try await model.settleFetches()

        XCTAssertEqual(model.currentPlaybackURL?.lastPathComponent.contains("f3"), true,
                       "got \(String(describing: model.currentPlaybackURL))")
        XCTAssertFalse(model.isPreparingClip, "the flag must clear once both finish")
    }
}
```

> `settleFetches()` is a test-facing seam: `ViewerModel` starts fetches in detached tasks, and a test needs to await them. Add it as an internal (not public) method that awaits the outstanding fetch tasks, and say in your report how you implemented it. **Do not use `Task.sleep`** — plan 2 already carries one timing-dependent test and a second would be worse.
>
> `comparison.playbackURL(for:)` may not exist; if `ComparisonModel` exposes the per-side URL under another name, use that and say so.

- [ ] **Step 2: Run test to verify it fails**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter FetchOnSelectTests
```
Expected: FAIL — nothing fetches, so `requestedFileIDs` is empty.

- [ ] **Step 3: Make a stale token survive the download too**

Task 3 gave the provider a 401-and-refresh retry, but only for the API calls it makes itself. The **bytes** are fetched by `ClipCache`'s downloader, outside the provider — `downloadSource(for:)` hands over whatever token is cached, and a 401 there becomes a plain failure with no refresh.

That leaves the original defect on the path that matters most. A coach reviewing for over an hour can list the library fine and fail to open a clip, which is the same "token expires mid-session and cannot be replaced" this whole design exists to escape.

Where fetching is triggered — `prepareCurrentClip` — treat an unauthorised download as retryable exactly once:

```swift
        // Task 3's refresh covers the provider's own requests; the bytes are
        // fetched by the cache, which has no provider to ask. So a download
        // refused for credentials is retried once with a freshly minted
        // source. Once, not in a loop: a second refusal is a real failure,
        // and retrying it forever would hammer Drive with a bad token.
        do {
            materialisedByFileID[file.id] = try await clipCache.materialize(file, source: source)
        } catch RemoteLibraryError.unauthorised {
            let retried = try await remoteProvider.downloadSource(for: file)
            materialisedByFileID[file.id] = try await clipCache.materialize(file, source: retried)
        }
```

This needs `RemoteLibraryError` to carry an `unauthorised` case and `URLSessionClipDownloader` to throw it on a 401 rather than folding it into `.api`. Add both.

Test it with a downloader that refuses once and succeeds after: assert the clip ends up cached, and that exactly two download attempts were made. **A test asserting only that it eventually succeeded would pass without any retry**, so assert the attempt count.

- [ ] **Step 4: Write minimal implementation**

In `ViewerModel`, after any change of selection (`changeVideo`, `changeAthlete`, `selectAthlete`), start a fetch of the current clip and a prefetch of its neighbours:

```swift
    /// The clips worth having before they are asked for: the two a coach is
    /// about to step forward onto, and the one behind them. Bounded on
    /// purpose — the library is 74 GB, and "fetch the whole athlete" is a
    /// flooded connection on a hill.
    private func neighboursToPrefetch() -> [RemoteFile] {
        guard let athlete = currentAthlete, let remoteIndex else { return [] }
        return [videoIndex - 1, videoIndex + 1, videoIndex + 2]
            .filter { athlete.videos.indices.contains($0) }
            .compactMap { remoteIndex.file(for: athlete.videos[$0]) }
    }
```

Prefetch must not block the selected clip: start it after `prepareCurrentClip` has begun, and let `ClipCache`'s coalescing handle a clip that is both prefetched and selected.

For the comparison pane, give `ComparisonModel.load(_:side:)` an overload taking the model that can fetch, so choosing a clip materialises it before loading. Then **invert the second assertion of `testTheComparisonPickerOffersAFileOnlyForAPreparedClip`** and delete its "KNOWN GAP" message — the gap is closed. Say so explicitly in your report; that is a deliberate change to a pre-existing test whose subject changed, not a test edited to pass.

Also remove the corresponding entry from the plan-2 document's "What this plan deliberately does not do" list, so the two documents do not disagree.

- [ ] **Step 5: Run the suite and commit**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -5
git add -A SkiVideoViewer/Sources SkiVideoViewer/Tests SkiVideoViewer/docs
git commit -m "Fetch the clip a coach just asked for, and the ones they are about to

Nothing called prepareCurrentClip, so clicking a clip showed an empty pane.
Selection now fetches, and reaches one clip back and two forward — bounded,
because the library is 74 GB and fetching a whole athlete on a hill is worse
than waiting two seconds.

A comparison pane fetches the clip it is given, which closes the gap plan 2
pinned: before this, a pane was handed a library URL it could not open."
```

---

### Task 7: iPad signs in too

**Files:**
- Replace: `Sources/SkiVideoViewer/iOS/UnavailableOAuthPresenter.swift` with `IOSOAuthPresenter.swift`
- Modify: `project.yml` (register the reverse-DNS URL scheme)
- Test: `Tests/SkiVideoViewerTests/…` — only the redirect-URI construction is testable

`ASWebAuthenticationSession` hands off to a system browser, which is what Google requires: embedded webviews are blocked with `disallowed_useragent`, `WKWebView` named explicitly.

- [ ] **Step 1: Write the failing test**

Only the redirect construction is testable without a browser and a human. Create `Tests/SkiVideoViewerTests/IOSRedirectTests.swift`:

```swift
import XCTest
@testable import SkiVideoCore

final class IOSRedirectTests: XCTestCase {
    /// An iOS client's redirect is its client id reversed, and Google matches
    /// it exactly. Built from the id rather than written out twice, so the two
    /// cannot drift.
    ///
    /// Fails if the reversal is wrong or the path is dropped — asserted on the
    /// whole string, not on a prefix.
    func testTheRedirectIsTheReversedClientIDWithACallbackPath() {
        let configuration = GoogleOAuthConfiguration(
            clientID: "123-abc.apps.googleusercontent.com",
            clientSecret: nil,
            redirectKind: .customScheme("com.googleusercontent.apps.123-abc")
        )
        XCTAssertEqual(
            GoogleOAuth.redirectURI(for: configuration),
            "com.googleusercontent.apps.123-abc:/oauth2redirect"
        )
    }

    /// macOS keeps the loopback form. Loopback is blocked for iOS clients and
    /// a custom scheme is not offered to Desktop clients, so the two platforms
    /// genuinely differ and this pins that they do.
    func testALoopbackConfigurationStillProducesALoopbackRedirect() {
        let configuration = GoogleOAuthConfiguration(
            clientID: "123.apps.googleusercontent.com",
            clientSecret: "shh",
            redirectKind: .loopback
        )
        XCTAssertTrue(
            GoogleOAuth.redirectURI(for: configuration).hasPrefix("http://127.0.0.1"),
            "got \(GoogleOAuth.redirectURI(for: configuration))"
        )
    }

    /// The scheme the app registers must be the one the flow asks Google to
    /// redirect to. These are declared in two different files — `project.yml`
    /// and the configuration — and nothing but this connects them.
    func testTheRegisteredSchemeMatchesTheConfiguredOne() throws {
        let projectYML = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let scheme = IOSOAuthPresenter.callbackScheme
        XCTAssertTrue(
            projectYML.contains(scheme),
            "project.yml does not register \(scheme); a redirect Google accepts would never reach the app"
        )
    }
}
```

> `GoogleOAuth.redirectURI(for:)` for the loopback case needs a port, which only a running listener has. Either give it a placeholder the presenter substitutes, or take the port as a parameter — pick one and say which. `#filePath` navigation in the third test assumes the test file sits at `Tests/SkiVideoViewerTests/`; adjust the number of `deletingLastPathComponent()` calls if it does not resolve, and confirm by asserting the file exists before reading it.

- [ ] **Step 2: Implement**

Replace `Sources/SkiVideoViewer/iOS/UnavailableOAuthPresenter.swift` with `IOSOAuthPresenter.swift`:

```swift
import AuthenticationServices
import Foundation
import SkiVideoCore

/// Signs in on iPad.
///
/// `ASWebAuthenticationSession` rather than a webview inside the app: Google
/// blocks authorization requests from embedded webviews with
/// `disallowed_useragent`, naming WKWebView explicitly. And a custom scheme
/// rather than the Mac's loopback listener, because loopback redirects have
/// been blocked for iOS OAuth clients since 21 October 2022.
@MainActor
final class IOSOAuthPresenter: NSObject, OAuthPresenter {
    /// Must match the scheme registered in `project.yml`, or Google redirects
    /// to something the app never receives. Pinned by `IOSRedirectTests`.
    static let callbackScheme = "com.googleusercontent.apps.REPLACE-WITH-IOS-CLIENT-ID"
    …
}
```

Register the same scheme in `project.yml` under the iPad target's `CFBundleURLTypes`, then `cd SkiVideoViewer && xcodegen generate`.

- [ ] **Step 3: Verify what can be verified, and say what cannot**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter IOSRedirectTests
cd SkiVideoViewer && xcodegen generate && cd ..
./SkiVideoViewer/scripts/ipad-smoke.sh
```

> **This task cannot be verified end to end without an iOS-type Google Cloud OAuth client** registered against bundle id `ch.ski.video-viewer.ipad`. Until that exists, `callbackScheme` holds a placeholder and no real sign-in can succeed. Implement, unit-test the redirect construction, run the smoke script — and then **report the task as BLOCKED on that registration**. Do not report it as done, and do not substitute a plausible-looking client id.

- [ ] **Step 4: Commit**

```bash
git add -A SkiVideoViewer/Sources SkiVideoViewer/Tests SkiVideoViewer/project.yml
git commit -m "Sign in on iPad, where loopback is not allowed

Loopback redirects have been blocked for iOS OAuth clients since October 2022,
and Google refuses an authorization request from an embedded webview outright,
naming WKWebView. So iPad gets a custom scheme and ASWebAuthenticationSession
rather than the Mac's loopback listener.

The scheme is declared in two files that nothing else connects, so a test reads
project.yml and checks they agree — a mismatch would send Google's redirect
somewhere the app never sees it."
```

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
