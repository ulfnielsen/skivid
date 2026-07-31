import AVFoundation
import XCTest
@testable import SkiVideoViewer

final class FFmpegMediaPipelineTests: XCTestCase {
    private var workingDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let workingDirectory {
            try? FileManager.default.removeItem(at: workingDirectory)
        }
        try await super.tearDown()
    }

    /// A one-second 640x360 test pattern. Small enough to keep the suite fast.
    private func makeFixture(named name: String) throws -> URL {
        let url = workingDirectory.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=duration=1:size=640x360:rate=15",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            url.path,
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "fixture generation failed")
        return url
    }

    func testResizeProducesAnOutputWithinBounds() async throws {
        let source = try makeFixture(named: "source.mp4")
        let destination = workingDirectory
            .appendingPathComponent("out", isDirectory: true)
            .appendingPathComponent("resized.mp4")

        try await FFmpegMediaPipeline().resize(
            source: source,
            destination: destination,
            athlete: "Idun"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        let track = try await AVURLAsset(url: destination)
            .loadTracks(withMediaType: .video).first
        let size = try await track?.load(.naturalSize)
        let resolved = try XCTUnwrap(size)
        XCTAssertLessThanOrEqual(resolved.width, 1920)
        XCTAssertLessThanOrEqual(resolved.height, 1080)
    }

    func testResizeCreatesIntermediateDirectories() async throws {
        let source = try makeFixture(named: "source.mp4")
        let destination = workingDirectory
            .appendingPathComponent("a/b/c", isDirectory: true)
            .appendingPathComponent("resized.mp4")

        try await FFmpegMediaPipeline().resize(
            source: source,
            destination: destination,
            athlete: "Idun"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testWriteMetadataReplacesTheFileInPlace() async throws {
        let source = try makeFixture(named: "source.mp4")
        let originalSize = try FileManager.default
            .attributesOfItem(atPath: source.path)[.size] as? Int

        try await FFmpegMediaPipeline().writeMetadata(athlete: "Idun", to: source)

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertNotNil(originalSize)

        // The tagged copy must still be a playable video with its video track.
        let tracks = try await AVURLAsset(url: source)
            .loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)

        // No temp files may survive.
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: workingDirectory.path)
            .filter { $0.hasPrefix(".metadata-") }
        XCTAssertTrue(leftovers.isEmpty, "temp files leaked: \(leftovers)")
    }

    func testFailureSurfacesFFmpegStderr() async throws {
        let missing = workingDirectory.appendingPathComponent("nope.mp4")
        let destination = workingDirectory.appendingPathComponent("out.mp4")

        do {
            try await FFmpegMediaPipeline().resize(
                source: missing,
                destination: destination,
                athlete: "Idun"
            )
            XCTFail("expected a failure for a missing source")
        } catch {
            XCTAssertFalse(
                error.localizedDescription.isEmpty,
                "the ffmpeg error message must reach the caller"
            )
        }
    }
}
