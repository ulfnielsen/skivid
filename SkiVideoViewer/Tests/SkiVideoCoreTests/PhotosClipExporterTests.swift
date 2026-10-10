import AVFoundation
import XCTest
@testable import SkiVideoCore

/// A pick that hands over a real file the way `loadFileRepresentation` does:
/// a URL that is only good inside the closure.
private struct FakePick: PickedMovie {
    let suggestedName: String?
    let file: URL?

    func withFile(_ body: @escaping @Sendable (URL) throws -> Void) async throws {
        guard let file else { throw CocoaError(.fileReadNoSuchFile) }
        try body(file)
    }
}

final class PhotosClipExporterTests: XCTestCase {
    private var work: URL!
    private var scratch: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotosClipExporterTests-\(UUID().uuidString)", isDirectory: true)
        scratch = work.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    private func fixture(_ name: String, seconds: Double = 1) throws -> URL {
        try makeRealVideoFile(in: work, name: name, seconds: seconds)
    }

    private func exporter(
        captureDate: @escaping @Sendable (URL) async -> Date? = { _ in nil }
    ) -> PhotosClipExporter {
        PhotosClipExporter(scratchRoot: scratch, captureDate: captureDate)
    }

    private func names(in folder: URL) throws -> [String] {
        try SortingLibrary.rawVideos(in: folder).map(\.lastPathComponent)
    }

    func testTwoPicksYieldTwoReadableMoviesWithDistinctNames() async throws {
        let a = try fixture("a.mov", seconds: 1)
        let b = try fixture("b.mov", seconds: 2)

        let folder = try await exporter().export([
            FakePick(suggestedName: "IMG_0413", file: a),
            FakePick(suggestedName: "IMG_0414", file: b),
        ])

        XCTAssertEqual(try names(in: folder), ["IMG_0413.mov", "IMG_0414.mov"])
        for (url, seconds) in zip(try SortingLibrary.rawVideos(in: folder), [1.0, 2.0]) {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            XCTAssertEqual(duration, seconds, accuracy: 0.2, "\(url.lastPathComponent) must be a readable movie")
        }
    }

    func testPicksSharingAFilenameStayDistinct() async throws {
        let a = try fixture("a.mov")
        let b = try fixture("b.mov")

        let folder = try await exporter().export([
            FakePick(suggestedName: "IMG_0001", file: a),
            FakePick(suggestedName: "img_0001", file: b),
        ])

        let found = try names(in: folder)
        XCTAssertEqual(found.count, 2, "a clash must not overwrite the first pick")
        XCTAssertEqual(Set(found.map { $0.lowercased() }).count, 2)
    }

    func testNameIsSanitisedAndExtensionFollowsTheFile() async throws {
        let a = try fixture("a.mov")

        let folder = try await exporter().export([FakePick(suggestedName: "Run 1/2: fast", file: a)])

        XCTAssertEqual(try names(in: folder), ["Run 1-2- fast.mov"])
    }

    func testUnnamedPicksAreOrderedByCaptureDateNotByPickOrder() async throws {
        let later = try fixture("later.mov", seconds: 1)
        let earlier = try fixture("earlier.mov", seconds: 2)
        let dates: [String: Date] = [
            "later": Date(timeIntervalSince1970: 1_800_000_600),
            "earlier": Date(timeIntervalSince1970: 1_800_000_000),
        ]

        let folder = try await exporter(captureDate: { url in
            // Keyed by length, since the exporter renames what it copies.
            let seconds = try? await AVURLAsset(url: url).load(.duration).seconds
            return (seconds ?? 0) > 1.5 ? dates["earlier"] : dates["later"]
        }).export([
            FakePick(suggestedName: nil, file: later),
            FakePick(suggestedName: "", file: earlier),
        ])

        let urls = try SortingLibrary.rawVideos(in: folder)
        XCTAssertEqual(urls.count, 2)
        let firstDuration = try await AVURLAsset(url: urls[0]).load(.duration).seconds
        XCTAssertEqual(firstDuration, 2, accuracy: 0.2, "the earlier capture must sort first")
        XCTAssertTrue(urls[0].lastPathComponent.hasPrefix("Photos "), urls[0].lastPathComponent)
    }

    func testCaptureDateBecomesTheFilesCreationDate() async throws {
        // `SortingLibrary.suggestedEventDate` reads this, so the event date
        // defaults to the day filmed rather than the day imported.
        let a = try fixture("a.mov")
        let filmed = Date(timeIntervalSince1970: 1_700_000_000)

        let folder = try await exporter(captureDate: { _ in filmed })
            .export([FakePick(suggestedName: "IMG_1", file: a)])

        let url = try XCTUnwrap(SortingLibrary.rawVideos(in: folder).first)
        XCTAssertEqual(SortingLibrary.suggestedEventDate(from: url), filmed)
    }

    func testUnnamedPicksWithoutAnyDateFallBackToPickOrder() async throws {
        let a = try fixture("a.mov")
        let b = try fixture("b.mov")

        let folder = try await exporter().export([
            FakePick(suggestedName: nil, file: a),
            FakePick(suggestedName: nil, file: b),
        ])

        XCTAssertEqual(try names(in: folder), ["Photos clip 01.mov", "Photos clip 02.mov"])
    }

    func testANewExportReplacesTheLastOne() async throws {
        let a = try fixture("a.mov")
        let exporter = exporter()
        _ = try await exporter.export([FakePick(suggestedName: "OLD", file: a)])

        let folder = try await exporter.export([FakePick(suggestedName: "NEW", file: a)])

        XCTAssertEqual(try names(in: folder), ["NEW.mov"])
    }

    func testAFailedPickLeavesNothingBehind() async throws {
        let a = try fixture("a.mov")

        do {
            _ = try await exporter().export([
                FakePick(suggestedName: "OK", file: a),
                FakePick(suggestedName: "BAD", file: nil),
            ])
            XCTFail("expected the export to throw")
        } catch {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path),
                       "a half-exported session must not stay on disk")
    }

    func testClearRemovesTheScratchFolder() async throws {
        let a = try fixture("a.mov")
        let exporter = exporter()
        _ = try await exporter.export([FakePick(suggestedName: "IMG_1", file: a)])

        exporter.clear()

        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
    }

    func testDefaultScratchRootIsUnderCaches() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        XCTAssertTrue(PhotosClipExporter.defaultScratchRoot().path.hasPrefix(caches.path))
    }
}
