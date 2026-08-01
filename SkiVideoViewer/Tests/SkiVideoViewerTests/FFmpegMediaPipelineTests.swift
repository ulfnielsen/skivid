import AVFoundation
import XCTest
@testable import SkiVideoViewer

final class FFmpegMediaPipelineTests: XCTestCase {
    private var workingDirectory: URL!

    /// Every test here shells out to ffmpeg. Without it the fixture generation
    /// fails and `testFailureSurfacesFFmpegStderr` would "pass" on env's own
    /// "ffmpeg: No such file or directory". Make the dependency explicit.
    private static var ffmpegIsInstalled: Bool = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }()

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(Self.ffmpegIsInstalled, "ffmpeg is not on PATH")
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
    private func makeFixture(named name: String, pixelFormat: String = "yuv420p") throws -> URL {
        let url = workingDirectory.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=duration=1:size=640x360:rate=15",
            "-c:v", "libx264", "-pix_fmt", pixelFormat,
            url.path,
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "fixture generation failed")
        return url
    }

    /// The video stream's pixel format, straight from ffprobe.
    private func probePixelFormat(of url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffprobe", "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=pix_fmt",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path,
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "ffprobe failed for \(url.lastPathComponent)")
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

    /// Resized clips are played back on iPhone and iPad, where VideoToolbox only
    /// decodes 8-bit 4:2:0 h264. Without an explicit `-pix_fmt` ffmpeg lets a modern
    /// x264 pick its "best" supported format and carries a wide source straight
    /// through, producing High 4:4:4 Predictive / 10-bit files that fail to decode
    /// with kVTVideoDecoderBadDataErr (-8969).
    ///
    /// The fixture is deliberately yuv444p10le -- exactly the format observed in a
    /// broken output -- so that dropping `-pix_fmt yuv420p` from the pipeline makes
    /// this test fail. A yuv420p fixture would pass either way and prove nothing.
    func testResizeNormalizesWideSourcesToAnIOSDecodablePixelFormat() async throws {
        let source = try makeFixture(named: "wide.mp4", pixelFormat: "yuv444p10le")
        XCTAssertEqual(
            try probePixelFormat(of: source),
            "yuv444p10le",
            "the fixture must start out in a format iOS cannot decode, or this test proves nothing"
        )

        let destination = workingDirectory
            .appendingPathComponent("out", isDirectory: true)
            .appendingPathComponent("resized.mp4")

        try await FFmpegMediaPipeline().resize(
            source: source,
            destination: destination,
            athlete: "Idun"
        )

        XCTAssertEqual(
            try probePixelFormat(of: destination),
            "yuv420p",
            "resized clips must be 8-bit 4:2:0 or iOS/iPadOS cannot decode them"
        )
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
            let message = error.localizedDescription
            XCTAssertFalse(message.isEmpty, "the ffmpeg error message must reach the caller")
            // ffmpeg's own diagnostic names the input it could not open. Asserting
            // on it is what separates a genuine ffmpeg failure from env failing to
            // find ffmpeg at all, which reports the same "No such file or directory".
            XCTAssertTrue(
                message.contains(missing.lastPathComponent),
                "expected ffmpeg's diagnostic about \(missing.lastPathComponent), got: \(message)"
            )
            XCTAssertFalse(
                message.contains("env: ffmpeg"),
                "this is env failing to find ffmpeg, not ffmpeg reporting a bad input: \(message)"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: destination.path),
                "a failed resize must not leave a partial output behind"
            )
        }
    }
}
