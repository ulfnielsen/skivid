import XCTest
@testable import SkiVideoCore

/// Rename, move, bin and list, asserted on the requests — the mistakes that
/// matter (a missing `supportsAllDrives`, an unescaped id) fail silently.
final class GoogleDriveItemUpdateTests: XCTestCase {
    private var transport: FakeHTTPTransport!
    private var provider: GoogleDriveProvider!

    override func setUp() {
        super.setUp()
        transport = FakeHTTPTransport()
        provider = GoogleDriveProvider(transport: transport, token: { "test-token" })
    }

    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testRenamePatchesTheNameOnASharedDrive() async throws {
        transport.responses = [.init(json: #"{"id":"f1","name":"2026-02-14_Hoch-Ybrig"}"#)]
        try await provider.rename(itemID: "f1", to: "2026-02-14_Hoch-Ybrig")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/drive/v3/files/f1")
        XCTAssertEqual(transport.queryItems(of: 0)["supportsAllDrives"], "true")
        XCTAssertEqual(try json(request)["name"] as? String, "2026-02-14_Hoch-Ybrig")
    }

    func testMoveSwapsParentsKeepingTheID() async throws {
        transport.responses = [.init(json: #"{"id":"c1","name":"IMG_1.mov"}"#)]
        try await provider.move(itemID: "c1", from: "old", to: "new")
        let query = transport.queryItems(of: 0)
        XCTAssertEqual(transport.requests[0].httpMethod, "PATCH")
        XCTAssertEqual(transport.requests[0].url?.path, "/drive/v3/files/c1")
        XCTAssertEqual(query["addParents"], "new")
        XCTAssertEqual(query["removeParents"], "old")
        XCTAssertEqual(query["supportsAllDrives"], "true")
    }

    func testTrashSetsTrashedRatherThanDeleting() async throws {
        transport.responses = [.init(json: #"{"id":"f1","name":"old"}"#)]
        try await provider.trash(itemID: "f1")
        XCTAssertEqual(transport.requests[0].httpMethod, "PATCH")
        XCTAssertEqual(try json(transport.requests[0])["trashed"] as? Bool, true)
        XCTAssertEqual(transport.queryItems(of: 0)["supportsAllDrives"], "true")
    }

    func testListChildrenPagesAndTellsFoldersFromFiles() async throws {
        transport.responses = [
            .init(json: #"{"nextPageToken":"p2","files":[{"id":"a","name":"Anna","mimeType":"application/vnd.google-apps.folder"}]}"#),
            .init(json: #"{"files":[{"id":"b","name":"IMG_1.mov","mimeType":"video/quicktime"}]}"#),
        ]
        let children = try await provider.listChildren(of: "ev1")
        XCTAssertEqual(children, [RemoteChild(id: "a", name: "Anna", isFolder: true),
                                  RemoteChild(id: "b", name: "IMG_1.mov", isFolder: false)])
        XCTAssertEqual(transport.queryItems(of: 0)["q"], "'ev1' in parents and trashed = false")
        XCTAssertEqual(transport.queryItems(of: 1)["pageToken"], "p2")
        XCTAssertEqual(transport.queryItems(of: 0)["supportsAllDrives"], "true")
    }

    func testAnEmptyFolderListsNothing() async throws {
        // Drive omits `files` entirely when nothing matches.
        transport.responses = [.init(json: #"{"kind":"drive#fileList","incompleteSearch":false}"#)]
        let children = try await provider.listChildren(of: "ev1")
        XCTAssertEqual(children, [])
    }

    func testAnIncompleteListingIsAnErrorNotAnEmptyFolder() async throws {
        transport.responses = [.init(json: #"{"incompleteSearch":true,"files":[]}"#)]
        do {
            _ = try await provider.listChildren(of: "ev1")
            XCTFail("an incomplete listing must throw")
        } catch {}
    }

    func testNoEditAccessStopsRatherThanRetries() async throws {
        transport.responses = [.init(status: 403, json: #"{"error":{"code":403,"message":"The user does not have sufficient permissions for this file."}}"#)]
        do {
            try await provider.rename(itemID: "f1", to: "x")
            XCTFail("a 403 must throw")
        } catch let error as RemoteUploadError {
            // The plain permission body carries no errors[].reason, so
            // `forbidden` falls to "no edit access".
            guard case .noWriteAccess = error else { return XCTFail("expected noWriteAccess, got \(error)") }
        }
    }
}
