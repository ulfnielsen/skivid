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

    // MARK: - Sign-in fixture

    /// `setUp`'s `provider` is built from a `token:` closure that always
    /// answers — the seam plan 2's tests use to stay off the network. These
    /// sign-in tests need the opposite: a provider actually wired to
    /// `GoogleOAuth`, starting with no stored credential. A second factory
    /// rather than changing `setUp`, so the pre-existing tests above keep
    /// their fixture untouched.
    /// The account key every stored refresh token is filed under — the client
    /// id, which is what `GoogleOAuth` uses. Named here so the resume tests can
    /// seed and inspect a store without repeating the literal.
    private static let clientID = "test-client.apps.googleusercontent.com"

    private func makeOAuthBackedProvider(
        tokenStore: OAuthTokenStore = InMemoryOAuthTokenStore()
    ) -> GoogleDriveProvider {
        GoogleDriveProvider(
            configuration: GoogleOAuthConfiguration(
                clientID: Self.clientID,
                clientSecret: nil,
                redirectKind: .loopback
            ),
            transport: transport,
            tokenStore: tokenStore
        )
    }

    /// A store already holding a refresh token, as a previous session's
    /// successful sign-in would have left it.
    private func storeHolding(_ refreshToken: String) throws -> InMemoryOAuthTokenStore {
        let store = InMemoryOAuthTokenStore()
        try store.save(refreshToken, account: Self.clientID)
        return store
    }

    // MARK: - Sign-in

    /// `connect` must run the flow and leave the provider able to authorize —
    /// asserted by a subsequent request carrying the bearer token, not by
    /// `connect` merely returning. A no-op `connect` would pass the second
    /// check alone.
    /// `@MainActor` because `FakeOAuthPresenter` is — it stands in for
    /// `ASWebAuthenticationSession`/`AppKitOAuthPresenter`, both UI-bound.
    @MainActor
    func testConnectLeavesTheProviderAbleToAuthorizeRequests() async throws {
        provider = makeOAuthBackedProvider()
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
        provider = makeOAuthBackedProvider()
        do {
            _ = try await provider.roots()
            XCTFail("expected .notSignedIn")
        } catch let error as RemoteLibraryError {
            XCTAssertEqual(error, .notSignedIn)
        } catch {
            XCTFail("expected RemoteLibraryError, got \(error)")
        }
    }

    /// Google's access tokens last about an hour — well inside a coach's
    /// review session. A cached token going stale mid-session must not force
    /// an interactive re-sign-in: one 401 must trigger exactly one silent
    /// refresh (`GoogleOAuth.accessToken`, not another `connect`), and the
    /// retried request must carry the refreshed token. Reproduces, one layer
    /// up, the exact failure this app moved off streaming to avoid — a token
    /// that expires mid-session with no way to replace it.
    @MainActor
    func testA401TriggersExactlyOneRefreshAndRetriesWithTheNewToken() async throws {
        provider = makeOAuthBackedProvider()
        let presenter = FakeOAuthPresenter()
        presenter.callbackToReturn = URL(string: "http://127.0.0.1:1/?code=abc&state=STATE")!
        transport.responses = [.init(json: #"{"access_token":"at-1","refresh_token":"rt-1"}"#)]
        try await provider.connect(presenter: presenter)
        let requestsBeforeRefresh = transport.requests.count

        transport.responses = [
            .init(status: 401, json: #"{"error":{"code":401,"message":"Invalid Credentials"}}"#),
            .init(json: #"{"access_token":"at-2"}"#),
            .init(json: #"{"drives":[]}"#),
        ]

        _ = try await provider.roots()

        let newRequests = transport.requests.suffix(from: requestsBeforeRefresh)
        XCTAssertEqual(newRequests.count, 3, "expected the 401, one refresh, and the retry")
        XCTAssertEqual(
            newRequests.filter { $0.url?.host == "oauth2.googleapis.com" }.count, 1,
            "expected exactly one refresh call"
        )
        XCTAssertEqual(
            transport.requests.last?.value(forHTTPHeaderField: "Authorization"),
            "Bearer at-2"
        )
    }

    /// Two requests that both find the same stale token must share one
    /// refresh rather than each triggering their own — several panes open on
    /// one expired token must not turn into a stampede of refresh calls.
    @MainActor
    func testConcurrentRequestsThatBothHit401ShareOneRefresh() async throws {
        provider = makeOAuthBackedProvider()
        let presenter = FakeOAuthPresenter()
        presenter.callbackToReturn = URL(string: "http://127.0.0.1:1/?code=abc&state=STATE")!
        transport.responses = [.init(json: #"{"access_token":"at-1","refresh_token":"rt-1"}"#)]
        try await provider.connect(presenter: presenter)
        let requestsBeforeRefresh = transport.requests.count

        transport.responses = [
            .init(status: 401, json: #"{"error":{"code":401,"message":"Invalid Credentials"}}"#),
            .init(status: 401, json: #"{"error":{"code":401,"message":"Invalid Credentials"}}"#),
            .init(json: #"{"access_token":"at-2"}"#),
            .init(json: #"{"drives":[]}"#),
            .init(json: #"{"drives":[]}"#),
        ]

        async let first = provider.roots()
        async let second = provider.roots()
        _ = try await (first, second)

        let newRequests = transport.requests.suffix(from: requestsBeforeRefresh)
        XCTAssertEqual(newRequests.count, 5, "expected two 401s, one shared refresh, and two retries")
        XCTAssertEqual(
            newRequests.filter { $0.url?.host == "oauth2.googleapis.com" }.count, 1,
            "expected the two concurrent 401s to share one refresh, not one each"
        )
    }

    /// A refresh that fails outright — the refresh token itself revoked, not
    /// merely the access token stale — must surface as `.notSignedIn`, the
    /// same message an actually-unconnected provider gives, rather than a raw
    /// exchange error the coach has no way to act on.
    @MainActor
    func testARefreshThatFailsSurfacesAsNotSignedIn() async throws {
        provider = makeOAuthBackedProvider()
        let presenter = FakeOAuthPresenter()
        presenter.callbackToReturn = URL(string: "http://127.0.0.1:1/?code=abc&state=STATE")!
        transport.responses = [.init(json: #"{"access_token":"at-1","refresh_token":"rt-1"}"#)]
        try await provider.connect(presenter: presenter)

        transport.responses = [
            .init(status: 401, json: #"{"error":{"code":401,"message":"Invalid Credentials"}}"#),
            .init(status: 400, json: #"{"error":{"message":"invalid_grant"}}"#),
        ]

        do {
            _ = try await provider.roots()
            XCTFail("expected .notSignedIn")
        } catch let error as RemoteLibraryError {
            XCTAssertEqual(error, .notSignedIn)
        } catch {
            XCTFail("expected RemoteLibraryError, got \(error)")
        }
    }

    // MARK: - Resuming a previous session

    /// The complaint this exists for: "I don't understand why I have to login
    /// with google every time I run the app."
    ///
    /// A refresh token left by an earlier session must produce a working
    /// session with no browser involved. Asserted by handing `resumeSession`
    /// no presenter at all — it takes none, so an implementation that fell
    /// back to the interactive flow could not compile — and then by a
    /// subsequent request carrying the bearer the refresh actually minted,
    /// which a `resumeSession` that returned true without exchanging anything
    /// would fail.
    func testAStoredRefreshTokenResumesTheSessionWithoutTheInteractiveFlow() async throws {
        let store = try storeHolding("rt-1")
        let provider = makeOAuthBackedProvider(tokenStore: store)
        transport.responses = [
            .init(json: #"{"access_token":"at-1"}"#),
            .init(json: #"{"drives":[]}"#),
        ]

        let resumed = await provider.resumeSession()

        XCTAssertTrue(resumed)
        XCTAssertEqual(transport.requests.first?.url?.host, "oauth2.googleapis.com",
                       "the one request must be the non-interactive token exchange")
        _ = try await provider.roots()
        XCTAssertEqual(
            transport.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer at-1"
        )
    }

    /// Nothing stored: nothing to resume, and — the part worth pinning — not
    /// even a round trip spent discovering that. The caller falls through to
    /// the ordinary sign-in prompt.
    func testNoStoredTokenFallsThroughWithoutReachingTheNetwork() async {
        let provider = makeOAuthBackedProvider()

        let resumed = await provider.resumeSession()

        XCTAssertFalse(resumed)
        XCTAssertTrue(transport.requests.isEmpty, "there is nothing to ask Google about")
    }

    /// A provider built from the `token:` closure supplies its credentials
    /// entirely on its own — there is no refresh token to exchange and no
    /// configuration to exchange it under. It must answer honestly rather than
    /// unwrap a nil `signIn`.
    func testAProviderWithNoSignInFlowCannotResumeAndSaysSo() async {
        // `setUp`'s provider is exactly that one.
        let resumed = await provider.resumeSession()

        XCTAssertFalse(resumed)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    /// Google refusing a stored grant — access revoked, password changed, the
    /// roughly six-month idle expiry — is an HTTP 400 `invalid_grant` per RFC
    /// 6749 §5.2. That token is dead: keeping it means every later attempt
    /// spends a round trip and falls back to the browser anyway.
    func testARefreshTokenGoogleRejectsIsClearedFromTheStore() async throws {
        let store = try storeHolding("rt-dead")
        let provider = makeOAuthBackedProvider(tokenStore: store)
        transport.responses = [
            .init(status: 400, json: #"{"error":{"message":"Token has been expired or revoked."}}"#),
        ]

        let resumed = await provider.resumeSession()

        XCTAssertFalse(resumed)
        XCTAssertNil(store.load(account: Self.clientID), "a grant Google refused must not be kept")
    }

    /// The load-bearing half of the same rule, and the only thing here that can
    /// lose a coach's session for a reason they cannot diagnose: a request that
    /// never completed says nothing about whether the token is good. A second
    /// of dropped wifi at a race must not sign the operator out.
    ///
    /// Asserted twice over, because "the string is still in the store" would
    /// also pass against an implementation that had corrupted it: the same
    /// stored token must go on to resume successfully once the network is back.
    func testAResumeThatNeverReachedGoogleLeavesTheStoredTokenUsable() async throws {
        let store = try storeHolding("rt-1")
        let provider = makeOAuthBackedProvider(tokenStore: store)
        transport.responses = [
            .init(failure: URLError(.notConnectedToInternet)),
            .init(json: #"{"access_token":"at-2"}"#),
        ]

        let offline = await provider.resumeSession()

        XCTAssertFalse(offline, "a resume that could not complete has not resumed")
        XCTAssertEqual(store.load(account: Self.clientID), "rt-1", "the token is untouched")

        let backOnline = await provider.resumeSession()

        XCTAssertTrue(backOnline, "the kept token must still work, not merely still be present")
    }

    /// The sharp edge between the two rules above. A 429 or a 5xx *did*
    /// complete — unlike a dropped connection — but is Google's own side
    /// failing, not a verdict on the token. A rule reading "any HTTP error
    /// means rejected", or "any 4xx", discards a perfectly good session the
    /// first time Drive rate-limits or hiccups.
    func testAThrottledOrFailingTokenEndpointDoesNotClearTheStoredToken() async throws {
        for status in [429, 500, 503] {
            let store = try storeHolding("rt-1")
            transport = FakeHTTPTransport()
            let provider = makeOAuthBackedProvider(tokenStore: store)
            transport.responses = [
                .init(status: status, json: #"{"error":{"message":"Backend Error"}}"#),
            ]

            let resumed = await provider.resumeSession()

            XCTAssertFalse(resumed, "HTTP \(status) is not a session")
            XCTAssertEqual(
                store.load(account: Self.clientID), "rt-1",
                "HTTP \(status) is Google failing, not Google refusing the token"
            )
        }
    }

    /// `connect`'s own resume attempt — it tries the stored token before
    /// opening a browser — has to obey the same rule, and did not: it cleared
    /// the token on *any* failure. So one dropped connection at the moment a
    /// coach opened the sheet discarded a good refresh token for good, and the
    /// browser came back on every launch after that. Invisible when it happens,
    /// because the interactive flow that follows succeeds.
    ///
    /// The presenter is made to fail so the store's contents can only reflect
    /// the clear-or-keep decision, not a fresh token written over the top.
    @MainActor
    func testConnectKeepsAStoredTokenWhenItsResumeNeverReachedGoogle() async throws {
        let store = try storeHolding("rt-good")
        let provider = makeOAuthBackedProvider(tokenStore: store)
        let presenter = FakeOAuthPresenter()
        presenter.errorToThrow = DriveError.oauthCallback("no browser here")
        transport.responses = [.init(failure: URLError(.timedOut))]

        do {
            try await provider.connect(presenter: presenter)
            XCTFail("expected the presenter's failure to surface")
        } catch {}

        XCTAssertEqual(
            store.load(account: Self.clientID), "rt-good",
            "a resume that never reached Google says nothing about the token"
        )
    }

    /// The companion that stops the fix above from becoming "never clear
    /// anything": a grant Google actually refused is still dropped on the
    /// `connect` path, so a revoked token does not sit in the Keychain costing
    /// a round trip on every future attempt.
    @MainActor
    func testConnectClearsAStoredTokenGoogleRefused() async throws {
        let store = try storeHolding("rt-dead")
        let provider = makeOAuthBackedProvider(tokenStore: store)
        let presenter = FakeOAuthPresenter()
        presenter.errorToThrow = DriveError.oauthCallback("no browser here")
        transport.responses = [
            .init(status: 400, json: #"{"error":{"message":"Token has been expired or revoked."}}"#),
        ]

        do {
            try await provider.connect(presenter: presenter)
            XCTFail("expected the presenter's failure to surface")
        } catch {}

        XCTAssertNil(store.load(account: Self.clientID))
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

    /// 100 is the API's maximum page size, so an account in more drives than
    /// that needs paging — the same silent truncation `pageSize` guards
    /// against, one level up.
    func testRootsFollowsItsOwnPageTokens() async throws {
        transport.responses = [
            .init(json: #"{"nextPageToken":"p2","drives":[{"id":"d1","name":"One"}]}"#),
            .init(json: #"{"drives":[{"id":"d2","name":"Two"}]}"#),
        ]

        let roots = try await provider.roots()

        XCTAssertEqual(roots.map(\.id), ["d1", "d2"])
        XCTAssertEqual(transport.queryItems(of: 1)["pageToken"], "p2")
    }

    // MARK: - The sweep

    /// The `fields` list is the only thing that makes Drive return
    /// `headRevisionId` and `md5Checksum` at all, and the cache's validity
    /// check and integrity check depend on them. A typo would compile, pass
    /// every other test — the fake answers regardless of what was asked — and
    /// silently break re-download detection against the real API.
    func testTheSweepAsksForTheFieldsTheCacheDependsOn() async throws {
        transport.responses = [.init(json: #"{"files":[]}"#)]
        for try await _ in provider.enumerate(RemoteFolder(id: "d1", name: "Club")) {}

        let fields = try XCTUnwrap(transport.queryItems(of: 0)["fields"])
        for required in ["id", "name", "mimeType", "size", "md5Checksum", "headRevisionId", "parents"] {
            XCTAssertTrue(fields.contains(required), "fields is missing \(required): \(fields)")
        }
        XCTAssertTrue(fields.contains("incompleteSearch"), "fields is missing incompleteSearch")
    }

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

    // MARK: - Video metadata

    /// Drive returns width, height and duration in the sweep the app already
    /// performs, so `ClipWeight` costs no extra request and no download.
    ///
    /// Note `durationMillis` arrives as a *string* while width and height are
    /// numbers. That asymmetry is Drive's, not ours, and decoding it as
    /// anything else is how the change feed's `fileId` bug happened.
    func testASweepCarriesVideoMetadataThrough() async throws {
        transport.responses = [.init(json: """
        {"files":[
          {"id":"f1","name":"run.mp4","mimeType":"video/mp4","parents":["d1"],
           "size":"400000000",
           "videoMediaMetadata":{"width":1920,"height":1080,"durationMillis":"30000"}}
        ]}
        """)]

        var files: [RemoteFile] = []
        for try await file in provider.enumerate(RemoteFolder(id: "d1", name: "Club")) {
            files.append(file)
        }

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].width, 1920)
        XCTAssertEqual(files[0].height, 1080)
        XCTAssertEqual(files[0].durationMillis, 30_000)
    }

    /// Drive fills the block in asynchronously after an upload, so a freshly
    /// uploaded clip arrives without it. That must not fail the sweep, and it
    /// must leave `ClipWeight` with nothing to judge rather than a zero.
    func testASweepWithoutVideoMetadataStillYieldsTheFile() async throws {
        transport.responses = [.init(json: """
        {"files":[
          {"id":"f1","name":"run.mp4","mimeType":"video/mp4","parents":["d1"],"size":"1000"}
        ]}
        """)]

        var files: [RemoteFile] = []
        for try await file in provider.enumerate(RemoteFolder(id: "d1", name: "Club")) {
            files.append(file)
        }

        XCTAssertEqual(files.count, 1)
        XCTAssertNil(files[0].width)
        XCTAssertNil(files[0].height)
        XCTAssertNil(files[0].durationMillis)
    }

    /// The field mask is the whole reason the data arrives. A sweep that
    /// stopped asking for it would silently stop flagging anything — no error,
    /// no failing assertion anywhere else, just a feature that quietly does
    /// nothing.
    func testTheSweepAsksDriveForVideoMetadata() async throws {
        transport.responses = [.init(json: #"{"files":[]}"#)]

        for try await _ in provider.enumerate(RemoteFolder(id: "d1", name: "Club")) {}

        let asked = transport.requests.first?.url?.absoluteString ?? ""
        XCTAssertTrue(asked.contains("videoMediaMetadata"), asked)
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

    /// The spec records that `files.list` results can shift mid-pagination,
    /// so a folder can legitimately appear twice in one sweep. Reproduced
    /// against the unfixed code: `Dictionary(uniqueKeysWithValues:)` traps
    /// with "Fatal error: Duplicate values for key" and kills the process —
    /// a crash on a routine refresh, from data outside our control.
    func testADuplicateFolderIDInASweepDoesNotCrash() async throws {
        transport.responses = [.init(json: """
        {"files":[
          {"id":"f1","name":"Neuss 2026","mimeType":"application/vnd.google-apps.folder","parents":["d1"]},
          {"id":"f1","name":"Neuss 2026","mimeType":"application/vnd.google-apps.folder","parents":["d1"]},
          {"id":"f3","name":"run.mp4","mimeType":"video/mp4","parents":["f1"],"size":"1"}
        ]}
        """)]

        var files: [RemoteFile] = []
        for try await file in provider.enumerate(RemoteFolder(id: "d1", name: "Club")) {
            files.append(file)
        }

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, ["Neuss 2026"])
    }

    /// The other of the two duplicate-key sites: a multi-page `changes.list`
    /// drain can report one file twice across pages. Reproduced against the
    /// unfixed code the same way as the sweep above — a trap, not a thrown
    /// error.
    func testADuplicateFolderIDAcrossTwoChangePagesDoesNotCrash() async throws {
        transport.responses = [
            .init(json: """
            {"nextPageToken":"p2","changes":[
              {"fileId":"f1","removed":false,
               "file":{"id":"f1","name":"Neuss 2026","mimeType":"application/vnd.google-apps.folder","parents":["d1"]}}
            ]}
            """),
            .init(json: """
            {"newStartPageToken":"t2","changes":[
              {"fileId":"f1","removed":false,
               "file":{"id":"f1","name":"Neuss 2026","mimeType":"application/vnd.google-apps.folder","parents":["d1"]}},
              {"fileId":"f3","removed":false,
               "file":{"id":"f3","name":"run.mp4","mimeType":"video/mp4","parents":["f1"],"size":"1"}}
            ]}
            """),
        ]

        let changes = try await provider.changes(since: "t1", forRoot: "d1")

        XCTAssertEqual(changes.changed.map(\.id), ["f3"])
        XCTAssertEqual(changes.changed[0].path, ["Neuss 2026"])
    }

    /// **The 63 orphans.** Measured in the operator's own cached index
    /// (`995fa97fce4dc6ed.skiindex.json`, 2026-08-19): 407 files, 63 of them
    /// stored with `path: []` — real clips such as `Nora1_resized.MP4`, 20 of
    /// whose names also appear among properly foldered files, in a drive with
    /// no loose videos in its root at all. They are what the re-encode pass
    /// touched: rewriting a clip's bytes changes the file and not the folders
    /// above it, so the change page carried the clip and none of its parents,
    /// the walk stopped at the first unknown id, and `RemoteLibraryIndex`
    /// grouped the pathless result under the root's own name — an athlete
    /// called "Videos" with 63 clips in it.
    ///
    /// The fixture is that exact shape: a changed clip whose two parent
    /// folders are nowhere in the page. Against the unfixed code its path is
    /// `[]`.
    func testAChangedClipWhoseFoldersDidNotChangeKeepsThem() async throws {
        transport.responses = [
            .init(json: """
            {"newStartPageToken":"t2","changes":[
              {"fileId":"f1","removed":false,
               "file":{"id":"f1","name":"Nora1_resized.MP4","mimeType":"video/mp4",
                       "parents":["event"],"size":"1","headRevisionId":"r2"}}
            ]}
            """),
            .init(json: """
            {"id":"event","name":"2026-01-14_Brunni",
             "mimeType":"application/vnd.google-apps.folder","parents":["athlete"]}
            """),
            .init(json: """
            {"id":"athlete","name":"Nora Nielsen",
             "mimeType":"application/vnd.google-apps.folder","parents":["d1"]}
            """),
        ]

        let changes = try await provider.changes(since: "t1", forRoot: "d1")

        XCTAssertEqual(changes.changed[0].path, ["Nora Nielsen", "2026-01-14_Brunni"])
    }

    /// The cost of the fetch above, bounded. Three clips re-encoded in one
    /// folder must ask Drive for that folder once, not once each — the
    /// operator's 63 orphans sit in a couple of dozen folders, so a per-clip
    /// lookup would turn one refresh into 63 extra round trips.
    ///
    /// Asserted on the request count, which is the only thing that tells a
    /// cached lookup from a repeated one: the resolved paths are identical
    /// either way.
    func testAnUnknownParentIsFetchedOncePerDrainNotOncePerClip() async throws {
        transport.responses = [
            .init(json: """
            {"newStartPageToken":"t2","changes":[
              {"fileId":"f1","removed":false,
               "file":{"id":"f1","name":"a.mp4","mimeType":"video/mp4","parents":["athlete"],"size":"1"}},
              {"fileId":"f2","removed":false,
               "file":{"id":"f2","name":"b.mp4","mimeType":"video/mp4","parents":["athlete"],"size":"1"}},
              {"fileId":"f3","removed":false,
               "file":{"id":"f3","name":"c.mp4","mimeType":"video/mp4","parents":["athlete"],"size":"1"}}
            ]}
            """),
            .init(json: """
            {"id":"athlete","name":"Nora Nielsen",
             "mimeType":"application/vnd.google-apps.folder","parents":["d1"]}
            """),
        ]

        let changes = try await provider.changes(since: "t1", forRoot: "d1")

        XCTAssertEqual(changes.changed.map(\.path), [["Nora Nielsen"], ["Nora Nielsen"], ["Nora Nielsen"]])
        XCTAssertEqual(transport.requests.count, 2, "one change page and one folder lookup")
    }

    /// Drive answers 404 both for a folder that was trashed and for one this
    /// account may not see — it deliberately does not distinguish them. Either
    /// way the clip is kept with what could be resolved, the same rule the
    /// sweep applies to a parent missing from its listing: losing a clip is
    /// worse than filing it one level shallow.
    func testAParentDriveWillNotShowLeavesTheClipShallowRatherThanFailing() async throws {
        transport.responses = [
            .init(json: """
            {"newStartPageToken":"t2","changes":[
              {"fileId":"f1","removed":false,
               "file":{"id":"f1","name":"a.mp4","mimeType":"video/mp4","parents":["gone"],"size":"1"}}
            ]}
            """),
            .init(status: 404, json: #"{"error":{"code":404,"message":"File not found: gone."}}"#),
        ]

        let changes = try await provider.changes(since: "t1", forRoot: "d1")

        XCTAssertEqual(changes.changed.map(\.id), ["f1"])
        XCTAssertEqual(changes.changed[0].path, [])
    }

    /// A 404 is data; anything else is not. Drive answers 403 for rate limits
    /// and quota, and a refresh that read one of those as "that folder does not
    /// exist" would file a whole page of clips under no folder and *persist*
    /// it — the exact defect this lookup exists to fix, re-entered through the
    /// error path. Failing leaves the stored index and its cursor untouched, so
    /// the next attempt resolves the same clips properly.
    func testARefusedParentLookupFailsTheRefreshRatherThanFilingTheClipShallow() async {
        transport.responses = [
            .init(json: """
            {"newStartPageToken":"t2","changes":[
              {"fileId":"f1","removed":false,
               "file":{"id":"f1","name":"a.mp4","mimeType":"video/mp4","parents":["athlete"],"size":"1"}}
            ]}
            """),
            .init(
                status: 403,
                json: #"{"error":{"code":403,"message":"User rate limit exceeded."}}"#
            ),
        ]

        do {
            let changes = try await provider.changes(since: "t1", forRoot: "d1")
            XCTFail("expected a 403 to throw, got \(changes.changed.map(\.path))")
        } catch {
            XCTAssertTrue("\(error)".contains("rate limit"), "got \(error)")
        }
    }

    /// A parent id that turns out to name a file, not a folder, must not become
    /// a path component: Drive would then have invented a folder that does not
    /// exist, and the clip would group under it.
    func testAParentThatIsNotAFolderIsNotUsedAsAPathComponent() async throws {
        transport.responses = [
            .init(json: """
            {"newStartPageToken":"t2","changes":[
              {"fileId":"f1","removed":false,
               "file":{"id":"f1","name":"a.mp4","mimeType":"video/mp4","parents":["odd"],"size":"1"}}
            ]}
            """),
            .init(json: #"{"id":"odd","name":"notes.txt","mimeType":"text/plain","parents":["d1"]}"#),
        ]

        let changes = try await provider.changes(since: "t1", forRoot: "d1")

        XCTAssertEqual(changes.changed[0].path, [])
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

    /// A clip trashed in Drive must leave the library. Drive's docs define
    /// `removed` only as "deletion or loss of access" and say nothing about
    /// trashing, so the client treats a `trashed` file as removed rather than
    /// betting on which way Drive reports it.
    func testATrashedFileIsTreatedAsRemoved() async throws {
        transport.responses = [.init(json: """
        {"newStartPageToken":"t2","changes":[
          {"fileId":"f1","removed":false,
           "file":{"id":"f1","name":"run.mp4","mimeType":"video/mp4","parents":["d1"],
                   "size":"1","headRevisionId":"r1","trashed":true}}
        ]}
        """)]

        let changes = try await provider.changes(since: "t1", forRoot: "d1")

        XCTAssertEqual(changes.removed, ["f1"])
        XCTAssertTrue(changes.changed.isEmpty)
    }

    /// Without `trashed` in the field list Drive omits it, and a trashed clip
    /// is indistinguishable from a live one.
    func testTheChangeFeedAsksForTheTrashedField() async throws {
        transport.responses = [.init(json: #"{"newStartPageToken":"t2","changes":[]}"#)]
        _ = try await provider.changes(since: "t1", forRoot: "d1")
        let fields = try XCTUnwrap(transport.queryItems(of: 0)["fields"])
        XCTAssertTrue(fields.contains("trashed"), "fields is missing trashed: \(fields)")
    }

    /// A page carrying neither a next-page nor a new-start token would leave
    /// `pageToken` unchanged and re-issue the same request forever, which is
    /// the one way the drain loop's "bounded number of calls" claim fails.
    func testAChangePageWithNoTokensFailsRatherThanSpinning() async {
        transport.responses = [.init(json: #"{"changes":[]}"#)]
        do {
            _ = try await provider.changes(since: "t1", forRoot: "d1")
            XCTFail("expected a page with no tokens to throw")
        } catch {
            XCTAssertTrue("\(error)".contains("neither"), "got \(error)")
        }
    }

    /// A server repeating a page token is the other way that loop could spin.
    func testARepeatedChangePageTokenFailsRatherThanSpinning() async {
        transport.responses = [
            .init(json: #"{"nextPageToken":"t1","changes":[]}"#),
        ]
        do {
            _ = try await provider.changes(since: "t1", forRoot: "d1")
            XCTFail("expected a repeated page token to throw")
        } catch {
            XCTAssertTrue("\(error)".contains("repeated"), "got \(error)")
        }
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

    /// The bug a coach met as "Google Drive returned an unexpected reply: no
    /// `fileId` in the reply, at `changes.Index 38`." — the Open Club Library
    /// sheet then showed no library at all.
    ///
    /// Drive's change log is not only file changes: a change to the shared
    /// drive itself (`changeType: "drive"` — renamed, sharing settings edited)
    /// carries `driveId`/`drive` and no `fileId`. Under the old field mask
    /// such a record arrived carrying none of the requested keys, so a
    /// non-optional `fileId` threw `keyNotFound` — and because one page decodes
    /// as a unit, a single drive-level record anywhere in a 1000-item page took
    /// the whole library open with it. Index 38 was simply where the operator's
    /// first one landed.
    ///
    /// The record is placed mid-page with real files either side, so this also
    /// proves the neighbours survive rather than the page being abandoned at
    /// the first oddity.
    func testADriveLevelChangeRecordIsSkippedRatherThanFailingTheWholePage() async throws {
        transport.responses = [.init(json: """
        {"newStartPageToken":"t2","changes":[
          {"fileId":"f1","removed":false,
           "file":{"id":"f1","name":"before.mp4","mimeType":"video/mp4","parents":["d1"],"size":"1"}},
          {},
          {"fileId":"f3","removed":false,
           "file":{"id":"f3","name":"after.mp4","mimeType":"video/mp4","parents":["d1"],"size":"1"}}
        ]}
        """)]

        let changes = try await provider.changes(since: "t1", forRoot: "d1")

        XCTAssertEqual(changes.changed.map(\.id), ["f1", "f3"])
        XCTAssertTrue(changes.removed.isEmpty, "a record naming no file is no clip's removal")
        XCTAssertEqual(changes.cursor, "t2")
    }

    /// Without `changeType` in the mask the client can only say a key was
    /// absent; with it, a skip can say what the record was. It is also the
    /// only way to recognise a non-file record that *does* carry a `fileId`.
    func testTheChangeFeedAsksForTheChangeType() async throws {
        transport.responses = [.init(json: #"{"newStartPageToken":"t2","changes":[]}"#)]
        _ = try await provider.changes(since: "t1", forRoot: "d1")
        let fields = try XCTUnwrap(transport.queryItems(of: 0)["fields"])
        XCTAssertTrue(fields.contains("changeType"), "fields is missing changeType: \(fields)")
    }

    /// The sibling of the bug above, and the worse one. A non-file record that
    /// carries a `fileId` — Drive stamps a drive-level change with the drive's
    /// own id, and the drive id is a folder id — would fall into the
    /// `file == nil` branch and be reported as a *removal*, silently evicting
    /// whatever that id names from the index. Skipping on `changeType` as well
    /// as on a missing `fileId` is what stops that.
    func testANonFileChangeCarryingAFileIDIsNotReportedAsARemoval() async throws {
        transport.responses = [.init(json: """
        {"newStartPageToken":"t2","changes":[
          {"changeType":"drive","fileId":"d1","driveId":"d1"},
          {"fileId":"f3","removed":false,
           "file":{"id":"f3","name":"after.mp4","mimeType":"video/mp4","parents":["d1"],"size":"1"}}
        ]}
        """)]

        let changes = try await provider.changes(since: "t1", forRoot: "d1")

        XCTAssertEqual(changes.removed, [], "a drive-level change removes no file")
        XCTAssertEqual(changes.changed.map(\.id), ["f3"])
    }

    // MARK: - An empty answer is not a failure

    /// The bug a coach met as "Google Drive returned an unexpected reply: The
    /// data couldn't be read because it is missing."
    ///
    /// Google omits an empty collection rather than sending `[]`: a `files.list`
    /// that matches nothing answers `{"kind": "drive#fileList",
    /// "incompleteSearch": false}` with no `files` key at all. Against a
    /// non-optional array that is `keyNotFound`, and the sign-in, the folder
    /// list and the drive were all working — the library was simply empty.
    func testAFolderWithNoFilesIsEmptyRatherThanAnError() async throws {
        transport.responses = [
            .init(json: #"{"kind":"drive#fileList","incompleteSearch":false}"#)
        ]

        var files: [RemoteFile] = []
        for try await file in provider.enumerate(RemoteFolder(id: "drive-id", name: "Videos")) {
            files.append(file)
        }
        XCTAssertTrue(files.isEmpty)
    }

    /// The same omission on the drive list, which is what an account with no
    /// shared drives answers.
    func testAnAccountWithNoSharedDrivesIsEmptyRatherThanAnError() async throws {
        transport.responses = [.init(json: #"{"kind":"drive#driveList"}"#)]
        let roots = try await provider.roots()
        XCTAssertTrue(roots.isEmpty)
    }

    /// And on the change feed, which answers this whenever nothing has changed
    /// since the cursor — the common case for a library that is up to date.
    func testAQuietChangeFeedIsEmptyRatherThanAnError() async throws {
        transport.responses = [
            .init(json: #"{"kind":"drive#changeList","newStartPageToken":"99"}"#)
        ]
        let result = try await provider.changes(since: "98", forRoot: "drive-id")
        XCTAssertTrue(result.changed.isEmpty, "\(result)")
    }

    /// When a decode does fail, it has to say what was wrong with the reply.
    /// `DecodingError.localizedDescription` is "The data couldn't be read
    /// because it is missing" whatever the fault and wherever it was — the
    /// message the coach saw, which named neither the field nor the call.
    func testADecodeFailureNamesTheFieldRatherThanSayingSomethingIsMissing() async {
        transport.responses = [.init(json: #"{"kind":"drive#driveList","drives":[{"name":"No id"}]}"#)]

        do {
            _ = try await provider.roots()
            XCTFail("a drive with no id should not decode")
        } catch let RemoteLibraryError.api(message) {
            XCTAssertTrue(message.contains("id"), "the field has to be named: \(message)")
            XCTAssertFalse(message.contains("couldn\u{2019}t be read"),
                           "the useless phrasing is what this replaces: \(message)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
