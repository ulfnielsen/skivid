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
    private func makeOAuthBackedProvider() -> GoogleDriveProvider {
        GoogleDriveProvider(
            configuration: GoogleOAuthConfiguration(
                clientID: "test-client.apps.googleusercontent.com",
                clientSecret: nil,
                redirectKind: .loopback
            ),
            transport: transport,
            tokenStore: InMemoryOAuthTokenStore()
        )
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
}
