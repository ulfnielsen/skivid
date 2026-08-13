import XCTest
@testable import SkiVideoCore

final class RemoteLibraryIndexTests: XCTestCase {
    private func file(
        _ id: String, _ name: String, _ path: [String], size: Int64 = 1
    ) -> RemoteFile {
        RemoteFile(id: id, name: name, path: path, size: size,
                   contentVersion: "v1", md5: nil)
    }

    // MARK: - Library URLs

    /// The folder path rides in the URL path, which is what `LibraryGrouping`
    /// sorts on. Without it, Drive clips sort by file name alone and sibling
    /// folders interleave — the defect `GoogleDriveSupport` documented.
    func testALibraryURLCarriesTheFolderPathAndTheFileID() {
        let url = RemoteLibraryIndex.libraryURL(
            for: file("1AbC", "run 3.mp4", ["Neuss 2026", "Ada Lovelace"]),
            providerIdentifier: "gdrive"
        )
        XCTAssertEqual(url.scheme, "gdrive")
        XCTAssertEqual(url.host, "1AbC")
        XCTAssertEqual(url.path, "/Neuss 2026/Ada Lovelace/run 3.mp4")
        XCTAssertEqual(url.lastPathComponent, "run 3.mp4")
    }

    /// Two clips sharing a name in different folders must be different URLs,
    /// or the index would lose one of them.
    func testTwoClipsWithOneNameInDifferentFoldersAreDifferentURLs() {
        let a = RemoteLibraryIndex.libraryURL(
            for: file("a", "run.mp4", ["E", "Ada"]), providerIdentifier: "gdrive")
        let b = RemoteLibraryIndex.libraryURL(
            for: file("b", "run.mp4", ["E", "Bea"]), providerIdentifier: "gdrive")
        XCTAssertNotEqual(a, b)
    }

    /// A file id is base64url and contains `-` and `_`. Verified against
    /// Foundation: both survive as a URL host.
    func testAFileIDWithBase64URLCharactersSurvives() {
        let url = RemoteLibraryIndex.libraryURL(
            for: file("1A_bC-dEf", "run.mp4", ["E", "Ada"]), providerIdentifier: "gdrive")
        XCTAssertEqual(url.host, "1A_bC-dEf")
    }

    // MARK: - Grouping

    func testAthleteAndEventComeFromTheLastTwoPathComponents() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive",
            files: [file("a", "run.mp4", ["Neuss 2026", "Ada"])]
        )
        XCTAssertEqual(index.athletes.map(\.name), ["Ada"])
        XCTAssertEqual(index.athletes.map(\.event), ["Neuss 2026"])
    }

    /// A clip one level down has an athlete but no event, exactly as a local
    /// library does for `root/Athlete/clip.mp4`.
    func testAClipOneLevelDownHasAnAthleteButNoEvent() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive",
            files: [file("a", "run.mp4", ["Ada"])]
        )
        XCTAssertEqual(index.athletes.map(\.name), ["Ada"])
        XCTAssertNil(index.athletes[0].event)
    }

    /// A clip loose in the root has neither. It is grouped under the root's
    /// own name, which is the closest analogue to what the local scanner does.
    func testALooseClipIsGroupedUnderTheRootName() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive",
            rootName: "Club Footage",
            files: [file("a", "run.mp4", [])]
        )
        XCTAssertEqual(index.athletes.map(\.name), ["Club Footage"])
        XCTAssertNil(index.athletes[0].event)
    }

    /// Clips deeper than event/athlete take the two folders nearest them, so
    /// an extra organisational layer above does not break grouping.
    func testDeeperClipsUseTheTwoFoldersNearestThem() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive",
            files: [file("a", "run.mp4", ["2026", "Neuss 2026", "Ada"])]
        )
        XCTAssertEqual(index.athletes.map(\.name), ["Ada"])
        XCTAssertEqual(index.athletes.map(\.event), ["Neuss 2026"])
    }

    /// Within an athlete, clips sort by folder path then name — the local
    /// scanner's order, which the old flat URL could not produce.
    func testClipsSortByFolderPathThenName() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive",
            files: [
                file("c", "b.mp4", ["E", "Ada"]),
                file("a", "a.mp4", ["E", "Ada"]),
            ]
        )
        XCTAssertEqual(
            index.athletes[0].videos.map(\.lastPathComponent), ["a.mp4", "b.mp4"]
        )
    }

    // MARK: - Filtering

    func testOnlyPlayableExtensionsAreIndexed() {
        let index = RemoteLibraryIndex(
            providerIdentifier: "gdrive",
            files: [
                file("a", "run.mp4", ["E", "Ada"]),
                file("b", "notes.txt", ["E", "Ada"]),
                file("c", "old.mkv", ["E", "Ada"]),
            ]
        )
        XCTAssertEqual(index.athletes[0].videos.map(\.lastPathComponent), ["run.mp4"])
    }

    /// The same list the local scanner uses, not a copy of it. Drive kept its
    /// own set until 2026-08-08 and offered files `AVPlayer` cannot open.
    func testTheExtensionListIsTheLocalScannersOwn() {
        XCTAssertEqual(
            RemoteLibraryIndex.supportedExtensions, VideoLibrary.supportedExtensions
        )
    }

    // MARK: - Lookup

    func testAFileCanBeFoundBackFromItsLibraryURL() {
        let indexed = file("1AbC", "run.mp4", ["E", "Ada"])
        let index = RemoteLibraryIndex(providerIdentifier: "gdrive", files: [indexed])
        let url = index.athletes[0].videos[0]
        XCTAssertEqual(index.file(for: url)?.id, "1AbC")
    }

    func testAnUnknownURLFindsNothing() {
        let index = RemoteLibraryIndex(providerIdentifier: "gdrive", files: [])
        XCTAssertNil(index.file(for: URL(fileURLWithPath: "/tmp/run.mp4")))
    }
}
