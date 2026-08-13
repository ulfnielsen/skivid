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
    ///
    /// Two files and `errorAfter = 1`, so the failure lands *part-way through*.
    /// One file would prove only that a stream can throw, which is not the
    /// behaviour at risk: the dangerous case is a sweep that yields some clips
    /// and then dies, because a caller that swallowed it would show a partial
    /// library as if it were whole. Asserting what was yielded first is what
    /// makes this a mid-stream test rather than a "does it throw" test.
    func testAFailingEnumerationThrowsAfterYieldingWhatItCould() async {
        let provider = FakeRemoteProvider(files: [
            RemoteFile(id: "a", name: "1.mp4", path: ["E", "A"], size: 1, contentVersion: nil, md5: nil),
            RemoteFile(id: "b", name: "2.mp4", path: ["E", "A"], size: 2, contentVersion: nil, md5: nil),
        ])
        provider.errorAfter = 1

        var seen: [String] = []
        do {
            for try await file in provider.enumerate(RemoteFolder(id: "root", name: "Drive")) {
                seen.append(file.id)
            }
            XCTFail("expected the enumeration to throw")
        } catch {
            XCTAssertTrue(error is RemoteLibraryError)
        }
        XCTAssertEqual(seen, ["a"], "the failure must come after what could be yielded, not instead of it")
    }
}
