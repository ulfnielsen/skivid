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
    func testAFailingEnumerationThrowsRatherThanEndingEarly() async {
        let provider = FakeRemoteProvider(files: [
            RemoteFile(id: "a", name: "1.mp4", path: ["E", "A"], size: 1, contentVersion: nil, md5: nil),
        ])
        provider.errorAfter = 1

        do {
            for try await _ in provider.enumerate(RemoteFolder(id: "root", name: "Drive")) {}
            XCTFail("expected the enumeration to throw")
        } catch {
            XCTAssertTrue(error is RemoteLibraryError)
        }
    }
}
