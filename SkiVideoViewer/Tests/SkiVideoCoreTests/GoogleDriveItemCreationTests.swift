import XCTest
@testable import SkiVideoCore

/// The club-Drive upload's write operations, asserted on the requests the
/// fake transport saw — method, URL, query and body — because the mistakes
/// that matter (a missing `supportsAllDrives`, an unescaped quote in `q`)
/// fail silently or only for some names, never in a return value.
final class GoogleDriveItemCreationTests: XCTestCase {
    private var transport: FakeHTTPTransport!
    private var provider: GoogleDriveProvider!
    private let sessionURI = "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=SESSION1"

    override func setUp() {
        super.setUp()
        transport = FakeHTTPTransport()
        provider = GoogleDriveProvider(transport: transport, token: { "test-token" })
    }

    private func clip(_ contents: String = "0123456789", extension ext: String = "mp4") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(ext)")
        try Data(contents.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    // MARK: - Folders

    func testCreateFolderPostsAFolderIntoTheParentOnASharedDrive() async throws {
        transport.responses = [.init(json: #"{"id":"f1","name":"2026-08-23 Hill"}"#)]

        let folder = try await provider.createFolder(named: "2026-08-23 Hill", parent: "root1")

        XCTAssertEqual(folder, RemoteItem(id: "f1", name: "2026-08-23 Hill"))
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/drive/v3/files")
        XCTAssertEqual(transport.queryItems(of: 0)["supportsAllDrives"], "true")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        let body = try json(request)
        XCTAssertEqual(body["name"] as? String, "2026-08-23 Hill")
        XCTAssertEqual(body["parents"] as? [String], ["root1"])
        XCTAssertEqual(body["mimeType"] as? String, "application/vnd.google-apps.folder")
    }

    func testFindFolderQueriesNameParentAndExcludesTrash() async throws {
        transport.responses = [.init(json: #"{"files":[{"id":"f9","name":"Hill"}]}"#)]

        let found = try await provider.findFolder(named: "Hill", parent: "root1")

        XCTAssertEqual(found, RemoteItem(id: "f9", name: "Hill"))
        let query = transport.queryItems(of: 0)
        XCTAssertEqual(transport.requests[0].httpMethod, "GET")
        XCTAssertEqual(
            query["q"],
            "name = 'Hill' and 'root1' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false")
        XCTAssertEqual(query["supportsAllDrives"], "true")
        XCTAssertEqual(query["includeItemsFromAllDrives"], "true")
        XCTAssertEqual(query["corpora"], "allDrives")
    }

    func testNamesAreEscapedInTheQuery() async throws {
        transport.responses = [.init(json: #"{"kind":"drive#fileList","incompleteSearch":false}"#)]

        _ = try await provider.findFolder(named: #"O'Brien \ Co"#, parent: "root1")

        XCTAssertTrue(
            try XCTUnwrap(transport.queryItems(of: 0)["q"]).hasPrefix(#"name = 'O\'Brien \\ Co' and"#),
            "got \(transport.queryItems(of: 0)["q"] ?? "nil")")
    }

    func testFindOrCreateReusesAnExistingFolder() async throws {
        transport.responses = [.init(json: #"{"files":[{"id":"f9","name":"Hill"}]}"#)]

        let folder = try await provider.findOrCreateFolder(named: "Hill", parent: "root1")

        XCTAssertEqual(folder.id, "f9")
        XCTAssertEqual(transport.requests.count, 1, "nothing may be created when one exists")
    }

    func testFindOrCreateCreatesAfterLookingAndFindingNothing() async throws {
        transport.responses = [
            .init(json: #"{"kind":"drive#fileList","incompleteSearch":false}"#),
            .init(json: #"{"id":"new1","name":"Hill"}"#),
        ]

        let folder = try await provider.findOrCreateFolder(named: "Hill", parent: "root1")

        XCTAssertEqual(folder.id, "new1")
        XCTAssertEqual(transport.requests.map { $0.httpMethod }, ["GET", "POST"], "find first, then create")
    }

    // MARK: - Already exists

    func testFindFileSeesAnExistingFileAndIgnoresFoldersAndTrash() async throws {
        transport.responses = [.init(json: #"{"files":[{"id":"c1","name":"run.mp4"}]}"#)]

        let found = try await provider.findFile(named: "run.mp4", parent: "f9")

        XCTAssertEqual(found, RemoteItem(id: "c1", name: "run.mp4"))
        XCTAssertEqual(
            transport.queryItems(of: 0)["q"],
            "name = 'run.mp4' and 'f9' in parents and mimeType != 'application/vnd.google-apps.folder' and trashed = false")
        XCTAssertEqual(transport.queryItems(of: 0)["supportsAllDrives"], "true")
    }

    /// The size is what tells a re-run of the same clip from a different clip
    /// that happens to share its name. Drive sends `size` as a JSON string
    /// (an int64), and only when asked for it in `fields`.
    func testFindFileAsksForAndReturnsTheSize() async throws {
        transport.responses = [.init(json: #"{"files":[{"id":"c1","name":"run.mp4","size":"1234567890123"}]}"#)]

        let found = try await provider.findFile(named: "run.mp4", parent: "f9")

        XCTAssertEqual(found?.size, 1_234_567_890_123)
        XCTAssertEqual(transport.queryItems(of: 0)["fields"], "incompleteSearch,files(id,name,size)")
    }

    func testFindFileAnswersNilWhenThereIsNone() async throws {
        transport.responses = [.init(json: #"{"kind":"drive#fileList","incompleteSearch":false}"#)]
        let found = try await provider.findFile(named: "run.mp4", parent: "f9")
        XCTAssertNil(found)
    }

    // MARK: - Upload

    func testUploadOpensAResumableSessionThenSendsTheBytesToIt() async throws {
        let file = try clip("0123456789")
        transport.responses = [
            .init(status: 200, headers: ["Location": sessionURI]),
            .init(json: #"{"id":"c1","name":"run.mp4"}"#),
        ]

        let item = try await provider.upload(fileAt: file, named: "run.mp4", parent: "f9")

        XCTAssertEqual(item, RemoteItem(id: "c1", name: "run.mp4"))
        XCTAssertEqual(transport.requests.count, 2)

        let open = transport.requests[0]
        XCTAssertEqual(open.httpMethod, "POST")
        XCTAssertEqual(open.url?.path, "/upload/drive/v3/files")
        XCTAssertEqual(transport.queryItems(of: 0)["uploadType"], "resumable")
        XCTAssertEqual(transport.queryItems(of: 0)["supportsAllDrives"], "true")
        XCTAssertEqual(open.value(forHTTPHeaderField: "X-Upload-Content-Length"), "10")
        let body = try json(open)
        XCTAssertEqual(body["name"] as? String, "run.mp4")
        XCTAssertEqual(body["parents"] as? [String], ["f9"])

        let put = transport.requests[1]
        XCTAssertEqual(put.httpMethod, "PUT")
        XCTAssertEqual(put.url?.absoluteString, sessionURI)
        XCTAssertEqual(put.value(forHTTPHeaderField: "Content-Range"), "bytes 0-9/10")
        XCTAssertEqual(put.httpBody, Data("0123456789".utf8))
    }

    /// Resized and iPhone clips are QuickTime — the pipeline writes
    /// `fileType: .mov` — so labelling every upload `video/mp4` would have
    /// Drive file a `.mov` under the wrong type. Both the session's declared
    /// type and the bytes' own header must follow the file.
    func testTheContentTypeFollowsTheFilesExtension() async throws {
        for (ext, expected) in [("mov", "video/quicktime"), ("MOV", "video/quicktime"),
                                ("mp4", "video/mp4"), ("zzz", "application/octet-stream")] {
            transport = FakeHTTPTransport()
            provider = GoogleDriveProvider(transport: transport, token: { "test-token" })
            let file = try clip("0123456789", extension: ext)
            transport.responses = [
                .init(status: 200, headers: ["Location": sessionURI]),
                .init(json: #"{"id":"c1","name":"run"}"#),
            ]

            _ = try await provider.upload(fileAt: file, named: "run.\(ext)", parent: "f9")

            XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "X-Upload-Content-Type"),
                           expected, ext)
            XCTAssertEqual(transport.requests[1].value(forHTTPHeaderField: "Content-Type"),
                           expected, ext)
        }
    }

    /// A token that expires between opening the session and finishing the
    /// bytes is the likely case for a big clip. The retry must carry the
    /// refreshed token and resend the same bytes.
    func testA401MidUploadRefreshesOnceAndResendsWithTheNewToken() async throws {
        let store = InMemoryOAuthTokenStore()
        try store.save("rt-1", account: "c.apps.googleusercontent.com")
        provider = GoogleDriveProvider(
            configuration: GoogleOAuthConfiguration(
                clientID: "c.apps.googleusercontent.com", clientSecret: nil, redirectKind: .loopback),
            transport: transport, tokenStore: store)
        transport.responses = [.init(json: #"{"access_token":"at-1"}"#)]
        let resumed = await provider.resumeSession()
        XCTAssertTrue(resumed)
        let before = transport.requests.count

        transport.responses = [
            .init(status: 200, headers: ["Location": sessionURI]),
            .init(status: 401, json: #"{"error":{"code":401,"message":"Invalid Credentials"}}"#),
            .init(json: #"{"access_token":"at-2"}"#),
            .init(json: #"{"id":"c1","name":"run.mp4"}"#),
        ]

        let item = try await provider.upload(fileAt: try clip(), named: "run.mp4", parent: "f9")

        XCTAssertEqual(item.id, "c1")
        let new = Array(transport.requests.suffix(from: before))
        XCTAssertEqual(new.count, 4, "open, rejected PUT, one refresh, retried PUT")
        XCTAssertEqual(new[1].value(forHTTPHeaderField: "Authorization"), "Bearer at-1")
        XCTAssertEqual(new[3].value(forHTTPHeaderField: "Authorization"), "Bearer at-2")
        XCTAssertEqual(new[3].url?.absoluteString, sessionURI)
        XCTAssertEqual(new[3].httpBody, Data("0123456789".utf8))
    }

    func testAMidUploadFailureAsksTheServerForItsOffsetAndSendsOnlyTheRest() async throws {
        transport.responses = [
            .init(status: 200, headers: ["Location": sessionURI]),
            .init(failure: URLError(.networkConnectionLost)),
            .init(status: 308, headers: ["Range": "bytes=0-3"]),
            .init(json: #"{"id":"c1","name":"run.mp4"}"#),
        ]

        let item = try await provider.upload(fileAt: try clip("0123456789"), named: "run.mp4", parent: "f9")

        XCTAssertEqual(item.id, "c1")
        XCTAssertEqual(transport.requests.count, 4)
        let status = transport.requests[2]
        XCTAssertEqual(status.httpMethod, "PUT")
        XCTAssertEqual(status.url?.absoluteString, sessionURI)
        XCTAssertEqual(status.value(forHTTPHeaderField: "Content-Range"), "bytes */10")
        let resumed = transport.requests[3]
        XCTAssertEqual(resumed.value(forHTTPHeaderField: "Content-Range"), "bytes 4-9/10")
        XCTAssertEqual(resumed.httpBody, Data("456789".utf8), "bytes 0-3 had arrived; only the rest is sent")
    }

    func testAStatusReplyWithNoRangeMeansStartAgainFromZero() async throws {
        transport.responses = [
            .init(status: 200, headers: ["Location": sessionURI]),
            .init(status: 503, json: #"{"error":{"message":"Backend Error"}}"#),
            .init(status: 308, headers: [:]),
            .init(json: #"{"id":"c1","name":"run.mp4"}"#),
        ]

        _ = try await provider.upload(fileAt: try clip(), named: "run.mp4", parent: "f9")

        XCTAssertEqual(transport.requests[3].value(forHTTPHeaderField: "Content-Range"), "bytes 0-9/10")
    }

    func testAnUploadThatKeepsFailingGivesUpWithAnErrorInsteadOfLooping() async throws {
        let drop = FakeHTTPTransport.Response(failure: URLError(.notConnectedToInternet))
        transport.responses = [.init(status: 200, headers: ["Location": sessionURI])]
            + Array(repeating: drop, count: 20)

        do {
            _ = try await provider.upload(fileAt: try clip(), named: "run.mp4", parent: "f9")
            XCTFail("a dead network must end in an error")
        } catch let RemoteUploadError.retryClip(message) {
            XCTAssertTrue(message.contains("run.mp4"), message)
        }
        // open + (PUT + status query) per attempt; 1 + maxUploadResumes PUTs,
        // and a status query after each failed PUT but the last.
        XCTAssertEqual(
            transport.requests.count,
            1 + (1 + GoogleDriveProvider.maxUploadResumes)
                + GoogleDriveProvider.maxUploadResumes)
    }

    func testAForbiddenUploadIsNotRetried() async throws {
        transport.responses = [
            .init(status: 200, headers: ["Location": sessionURI]),
            .init(status: 403, json: #"{"error":{"message":"Insufficient permission"}}"#),
        ]

        do {
            _ = try await provider.upload(fileAt: try clip(), named: "run.mp4", parent: "f9")
            XCTFail("403 must surface")
        } catch let RemoteUploadError.stopBatch(message) {
            XCTAssertTrue(message.lowercased().contains("permission"), message)
        }
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testAnExpiredSessionIsARetryableClipNotAStop() async throws {
        transport.responses = [
            .init(status: 200, headers: ["Location": sessionURI]),
            .init(status: 404, json: #"{"error":{"message":"Not Found"}}"#),
        ]

        do {
            _ = try await provider.upload(fileAt: try clip(), named: "run.mp4", parent: "f9")
            XCTFail("an expired session must surface")
        } catch RemoteUploadError.retryClip {
        }
        XCTAssertEqual(transport.requests.count, 2, "a 404 is not resumed")
    }

    func testAnExpiredSessionFoundByTheStatusQueryIsRetryable() async throws {
        transport.responses = [
            .init(status: 200, headers: ["Location": sessionURI]),
            .init(failure: URLError(.networkConnectionLost)),
            .init(status: 404, json: #"{"error":{"message":"Not Found"}}"#),
        ]

        do {
            _ = try await provider.upload(fileAt: try clip(), named: "run.mp4", parent: "f9")
            XCTFail("an expired session must surface")
        } catch RemoteUploadError.retryClip {
        }
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testAnIncompleteSearchIsAnErrorNotAnAbsence() async throws {
        transport.responses = [.init(json: #"{"incompleteSearch":true,"files":[]}"#)]

        do {
            _ = try await provider.findFile(named: "run.mp4", parent: "f9")
            XCTFail("a partial result must not read as 'not there'")
        } catch RemoteLibraryError.api {
        }
    }

    func testFindsPreferTheOldestMatch() async throws {
        transport.responses = [.init(json: #"{"files":[]}"#)]
        _ = try await provider.findFolder(named: "Hill", parent: "root1")
        XCTAssertEqual(transport.queryItems(of: 0)["orderBy"], "createdTime")
        XCTAssertEqual(transport.queryItems(of: 0)["fields"], "incompleteSearch,files(id,name,size)")
    }
}
