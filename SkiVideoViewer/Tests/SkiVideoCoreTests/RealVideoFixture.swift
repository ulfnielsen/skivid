import AVFoundation
import XCTest

/// A real H.264 clip of a known length, generated rather than checked in.
///
/// Zero-byte fixtures give `AVPlayerItem.duration` a NaN, so every bounds and
/// duration branch silently never executes. That is exactly how the comparison
/// screen's sync-point clamping defect survived four task reviews and a task
/// that recorded it as "reasoned to, never observed". Any test that touches
/// duration, seek bounds or the scrubber must use this.
///
/// 160×90 at 30fps keeps a 20s clip to 600 tiny frames, which encodes in a
/// fraction of a second; the per-frame grey level changes so the encoder cannot
/// collapse the clip into something with a different duration than asked for.
extension XCTestCase {
    func makeRealVideoFile(
        in directory: URL,
        name: String,
        seconds: Double,
        fps: Int32 = 30,
        width: Int = 160,
        height: Int = 90
    ) throws -> URL {
        try writeVideoFixture(
            in: directory,
            name: name,
            seconds: seconds,
            fps: fps,
            width: width,
            height: height,
            transform: .identity
        )
    }

    /// A fixture with a rotation transform, for the one property that generated
    /// media otherwise cannot exercise: every clip written by
    /// `makeRealVideoFile` has an identity transform, so a pipeline that drops
    /// `preferredTransform` passes every other test in the suite.
    func makeRotatedVideoFile(
        in directory: URL,
        name: String,
        seconds: Double,
        degrees: Double,
        fps: Int32 = 30
    ) throws -> URL {
        try writeVideoFixture(
            in: directory,
            name: name,
            seconds: seconds,
            fps: fps,
            width: 160,
            height: 90,
            transform: CGAffineTransform(rotationAngle: degrees * .pi / 180)
        )
    }

    private func writeVideoFixture(
        in directory: URL,
        name: String,
        seconds: Double,
        fps: Int32,
        width: Int,
        height: Int,
        transform: CGAffineTransform
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        XCTAssertTrue(writer.startWriting(), "could not start writing the fixture: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)

        let frames = Int(seconds * Double(fps))
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
            let pool = try XCTUnwrap(adaptor.pixelBufferPool, "the writer gave no pixel buffer pool")
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer), kCVReturnSuccess)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            if let base = CVPixelBufferGetBaseAddress(pixels) {
                memset(base, Int32(frame % 251), CVPixelBufferGetBytesPerRow(pixels) * CVPixelBufferGetHeight(pixels))
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: fps))

        let written = expectation(description: "fixture written")
        writer.finishWriting { written.fulfill() }
        wait(for: [written], timeout: 60)
        XCTAssertEqual(writer.status, .completed, "fixture encode failed: \(String(describing: writer.error))")
        return url
    }
}
