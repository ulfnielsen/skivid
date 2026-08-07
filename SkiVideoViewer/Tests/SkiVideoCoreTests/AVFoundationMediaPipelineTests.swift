import AVFoundation
import XCTest
@testable import SkiVideoCore

/// The pipeline, against real generated media.
///
/// Every assertion is on a *property* of the output — dimensions, transform,
/// duration, track presence — never on byte size or achieved bitrate.
/// VideoToolbox behaviour differs between hosts and those figures are flaky.
final class AVFoundationMediaPipelineTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        super.tearDown()
    }

    func testResizeScalesAnOversizeSourceIntoTheBox() async throws {
        let source = try makeRealVideoFile(in: root, name: "big.mov", seconds: 1, fps: 30, width: 3840, height: 2160)
        let destination = root.appendingPathComponent("out/big.mov")
        try await AVFoundationMediaPipeline().resize(source: source, destination: destination, athlete: "Idun")

        let size = try await displaySize(of: destination)
        XCTAssertEqual(size.width, 1920, accuracy: 1)
        XCTAssertEqual(size.height, 1080, accuracy: 1)
    }

    /// The rule is never-upscale, which differs from the ffmpeg pipeline this
    /// replaces: `force_original_aspect_ratio=decrease` enlarges a small source
    /// to fill the box. A 640×360 clip must come back 640×360.
    func testResizeLeavesAnUndersizeSourceAlone() async throws {
        let source = try makeRealVideoFile(in: root, name: "small.mov", seconds: 1, fps: 30, width: 640, height: 360)
        let destination = root.appendingPathComponent("out/small.mov")
        try await AVFoundationMediaPipeline().resize(source: source, destination: destination, athlete: "Idun")

        let size = try await displaySize(of: destination)
        XCTAssertEqual(size.width, 640, accuracy: 1)
        XCTAssertEqual(size.height, 360, accuracy: 1)
    }

    /// Both output dimensions must be even; H.264 4:2:0 cannot encode odd ones.
    /// 1999×1119 scaled to fit gives a fractional height, so this pins the
    /// rounding rather than the scale.
    func testResizeRoundsBothDimensionsToEvenNumbers() async throws {
        let source = try makeRealVideoFile(in: root, name: "odd.mov", seconds: 1, fps: 30, width: 1999, height: 1119)
        let destination = root.appendingPathComponent("out/odd.mov")
        try await AVFoundationMediaPipeline().resize(source: source, destination: destination, athlete: "Idun")

        let size = try await displaySize(of: destination)
        XCTAssertEqual(Int(size.width.rounded()) % 2, 0, "width \(size.width) must be even")
        XCTAssertEqual(Int(size.height.rounded()) % 2, 0, "height \(size.height) must be even")
    }

    /// The riskiest property in this work. A rotated source that loses its
    /// transform comes out sideways, and no fixture with an identity transform
    /// can catch it.
    func testResizePreservesTheSourceRotation() async throws {
        let source = try makeRotatedVideoFile(in: root, name: "portrait.mov", seconds: 1, degrees: 90)
        let destination = root.appendingPathComponent("out/portrait.mov")
        try await AVFoundationMediaPipeline().resize(source: source, destination: destination, athlete: "Idun")

        let size = try await displaySize(of: destination)
        XCTAssertGreaterThan(size.height, size.width,
                             "a 90-degree-rotated source must stay portrait; got \(size)")
    }

    /// The scale must come from the *display* size, not the encoded size. A
    /// 3840×2160 buffer with a 90-degree transform is a 2160×3840 clip: it has
    /// to shrink until its 3840 side fits 1080, not until its 3840 side fits
    /// 1920. Nothing with an identity transform can tell the two apart, and
    /// neither can a rotated clip that already fits — only a rotated oversize
    /// one does.
    func testResizeFitsARotatedOversizeSourceIntoTheBox() async throws {
        let source = try makeRotatedVideoFile(
            in: root, name: "tall.mov", seconds: 1, degrees: 90, fps: 30, width: 3840, height: 2160
        )
        let destination = root.appendingPathComponent("out/tall.mov")
        try await AVFoundationMediaPipeline().resize(source: source, destination: destination, athlete: "Idun")

        let size = try await displaySize(of: destination)
        XCTAssertLessThanOrEqual(size.width, 1920, "got \(size)")
        XCTAssertLessThanOrEqual(size.height, 1080, "got \(size)")
        XCTAssertGreaterThan(size.height, size.width, "must stay portrait; got \(size)")
    }

    /// `even` cannot be pinned through the written file: handed an odd height,
    /// VideoToolbox rounds it down itself, so the output is 1074 whether we
    /// asked for 1074 or 1075. Verified — with the rounding removed,
    /// `outputSize` returns 1075 and the written track is still 1074. The rule
    /// is real (what we hand the encoder is ours to get right, and other
    /// codecs are less forgiving), so it is pinned at the function instead.
    func testOutputSizeRoundsBothDimensionsToEvenNumbers() {
        let (width, height) = AVFoundationMediaPipeline.outputSize(
            natural: CGSize(width: 1999, height: 1119), transform: .identity
        )
        XCTAssertEqual(width % 2, 0, "width \(width) must be even")
        XCTAssertEqual(height % 2, 0, "height \(height) must be even")
    }

    func testResizePreservesTheFrameRate() async throws {
        let source = try makeRealVideoFile(in: root, name: "fast.mov", seconds: 2, fps: 50, width: 1280, height: 720)
        let destination = root.appendingPathComponent("out/fast.mov")
        try await AVFoundationMediaPipeline().resize(source: source, destination: destination, athlete: "Idun")

        // `XCTUnwrap` takes a non-async autoclosure, so the load has to happen
        // first — `try await XCTUnwrap(… loadTracks …)` does not compile.
        let tracks = try await AVURLAsset(url: destination).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let rate = try await track.load(.nominalFrameRate)
        XCTAssertEqual(rate, 50, accuracy: 2, "forcing 30fps would silently drop half the frames")
    }

    func testResizePreservesTheDuration() async throws {
        let source = try makeRealVideoFile(in: root, name: "len.mov", seconds: 3, fps: 30, width: 1280, height: 720)
        let destination = root.appendingPathComponent("out/len.mov")
        try await AVFoundationMediaPipeline().resize(source: source, destination: destination, athlete: "Idun")

        let duration = try await AVURLAsset(url: destination).load(.duration).seconds
        XCTAssertEqual(duration, 3, accuracy: 0.2)
    }

    func testResizeCreatesIntermediateDirectories() async throws {
        let source = try makeRealVideoFile(in: root, name: "nested.mov", seconds: 1, fps: 30, width: 1280, height: 720)
        let destination = root.appendingPathComponent("a/b/c/nested.mov")
        try await AVFoundationMediaPipeline().resize(source: source, destination: destination, athlete: "Idun")

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testResizeWritesTheAthleteMetadata() async throws {
        let source = try makeRealVideoFile(in: root, name: "meta.mov", seconds: 1, fps: 30, width: 1280, height: 720)
        let destination = root.appendingPathComponent("out/meta.mov")
        try await AVFoundationMediaPipeline().resize(source: source, destination: destination, athlete: "Idun")

        let items = try await AVURLAsset(url: destination).load(.metadata)
        let values = items.compactMap { $0.stringValue }
        XCTAssertTrue(values.contains("Idun"), "expected the athlete in the metadata; got \(values)")
    }

    /// A source with no audio must produce an output with no audio, not a
    /// failure and not a silent track. Screen-recording trims and some drone
    /// footage arrive this way, and `makeRealVideoFile` writes video only —
    /// so every other test in this file is already exercising that path.
    func testResizeOfASilentSourceProducesNoAudioTrack() async throws {
        let source = try makeRealVideoFile(in: root, name: "silent.mov", seconds: 1, fps: 30, width: 1280, height: 720)
        let destination = root.appendingPathComponent("out/silent.mov")
        try await AVFoundationMediaPipeline().resize(source: source, destination: destination, athlete: "Idun")

        let audio = try await AVURLAsset(url: destination).loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty)
    }

    func testResizeOfAnUnreadableSourceReportsTheFilename() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("broken.mkv")
        try Data("not a video".utf8).write(to: source)
        let destination = root.appendingPathComponent("out/broken.mov")

        do {
            try await AVFoundationMediaPipeline().resize(source: source, destination: destination, athlete: "Idun")
            XCTFail("an unreadable source must throw")
        } catch let error as MediaPipelineError {
            XCTAssertEqual(error, .unreadableSource("broken.mkv"))
        }
    }

    // MARK: - helpers

    /// The size the viewer sees: natural size with the preferred transform
    /// applied. Reading `naturalSize` alone would pass a rotated output.
    private func displaySize(of url: URL) async throws -> CGSize {
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformed = natural.applying(transform)
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }
}
