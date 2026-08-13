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
