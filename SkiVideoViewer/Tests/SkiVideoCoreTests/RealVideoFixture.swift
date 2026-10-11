import AVFoundation
import XCTest

/// The audio track a fixture should carry, if any.
///
/// Deliberately not the same shape as the pipeline's output settings: a fixture
/// written at 44.1kHz mono and resized to 48kHz stereo proves the encode
/// settings were applied, which a matching pair could not.
struct FixtureAudio {
    var sampleRate: Double = 44_100
    var channels: UInt32 = 1
    /// Hz of the generated tone. Any audible value works; the content is never
    /// asserted on, only the track's existence and format.
    var toneHz: Double = 440
}

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
        height: Int = 90,
        audio: FixtureAudio? = nil
    ) throws -> URL {
        try writeVideoFixture(
            in: directory,
            name: name,
            seconds: seconds,
            frameDuration: CMTime(value: 1, timescale: fps),
            width: width,
            height: height,
            transform: .identity,
            audio: audio
        )
    }

    /// A fixture at a rational rate, e.g. `CMTime(value: 1001, timescale:
    /// 60000)` for 59.94 fps. The `Int32` overload cannot express NTSC rates,
    /// and they are the ones where a frame's presentation time is not a whole
    /// number of 1/600 s ticks — which is what made frame steps land one frame
    /// short there and nowhere else.
    func makeRealVideoFile(
        in directory: URL,
        name: String,
        seconds: Double,
        frameDuration: CMTime,
        width: Int = 160,
        height: Int = 90
    ) throws -> URL {
        try writeVideoFixture(
            in: directory,
            name: name,
            seconds: seconds,
            frameDuration: frameDuration,
            width: width,
            height: height,
            transform: .identity,
            audio: nil
        )
    }

    /// A fixture with a rotation transform, for the one property that generated
    /// media otherwise cannot exercise: every clip written by
    /// `makeRealVideoFile` has an identity transform, so a pipeline that drops
    /// `preferredTransform` passes every other test in the suite.
    ///
    /// `width`/`height` are the *encoded* size; the transform is what turns a
    /// landscape buffer into a portrait clip. They default to the same 160×90
    /// as `makeRealVideoFile`, so the signature the plan specifies still works
    /// unchanged — the parameters exist so a rotated *oversize* fixture can be
    /// made, which is the only shape that catches scaling computed from the
    /// natural size instead of the display size.
    func makeRotatedVideoFile(
        in directory: URL,
        name: String,
        seconds: Double,
        degrees: Double,
        fps: Int32 = 30,
        width: Int = 160,
        height: Int = 90
    ) throws -> URL {
        try writeVideoFixture(
            in: directory,
            name: name,
            seconds: seconds,
            frameDuration: CMTime(value: 1, timescale: fps),
            width: width,
            height: height,
            transform: CGAffineTransform(rotationAngle: degrees * .pi / 180),
            audio: nil
        )
    }

    private func writeVideoFixture(
        in directory: URL,
        name: String,
        seconds: Double,
        frameDuration: CMTime,
        width: Int,
        height: Int,
        transform: CGAffineTransform,
        audio: FixtureAudio?
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

        var audioInput: AVAssetWriterInput?
        if let audio {
            let track = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audio.sampleRate,
                AVNumberOfChannelsKey: Int(audio.channels),
            ])
            track.expectsMediaDataInRealTime = false
            writer.add(track)
            audioInput = track
        }

        XCTAssertTrue(writer.startWriting(), "could not start writing the fixture: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)

        // The epsilon keeps 2 s / (1/25 s) at 50 frames, not 49.
        let frames = Int((seconds / frameDuration.seconds + 1e-9).rounded(.down))
        // Audio goes in 0.1s chunks so the two tracks can be interleaved by
        // presentation time. Writing every video frame and only then every
        // audio chunk is what deadlocks a multi-track writer: it withholds
        // readiness on the input that has run ahead.
        let chunkSeconds = 0.1
        let chunks = audio == nil ? 0 : Int((seconds / chunkSeconds).rounded())

        var frame = 0
        var chunk = 0
        while frame < frames || chunk < chunks {
            let videoTime = Double(frame) * frameDuration.seconds
            let audioTime = Double(chunk) * chunkSeconds
            if frame < frames, chunk >= chunks || videoTime <= audioTime {
                try appendVideoFrame(frame, to: input, via: adaptor, frameDuration: frameDuration)
                frame += 1
            } else {
                try appendAudioChunk(
                    chunk,
                    to: try XCTUnwrap(audioInput),
                    audio: try XCTUnwrap(audio),
                    chunkSeconds: chunkSeconds
                )
                chunk += 1
            }
        }
        input.markAsFinished()
        audioInput?.markAsFinished()
        writer.endSession(atSourceTime: CMTimeMultiply(frameDuration, multiplier: Int32(frames)))

        let written = expectation(description: "fixture written")
        writer.finishWriting { written.fulfill() }
        wait(for: [written], timeout: 60)
        XCTAssertEqual(writer.status, .completed, "fixture encode failed: \(String(describing: writer.error))")
        return url
    }

    private func appendVideoFrame(
        _ frame: Int,
        to input: AVAssetWriterInput,
        via adaptor: AVAssetWriterInputPixelBufferAdaptor,
        frameDuration: CMTime
    ) throws {
        try waitForReadiness(of: input)
        let pool = try XCTUnwrap(adaptor.pixelBufferPool, "the writer gave no pixel buffer pool")
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddress(pixels) {
            memset(base, Int32(frame % 251), CVPixelBufferGetBytesPerRow(pixels) * CVPixelBufferGetHeight(pixels))
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTimeMultiply(frameDuration, multiplier: Int32(frame))))
    }

    /// A chunk of a sine tone as 16-bit interleaved LPCM, wrapped in a
    /// `CMSampleBuffer` the writer's AAC input can encode.
    private func appendAudioChunk(
        _ chunk: Int,
        to input: AVAssetWriterInput,
        audio: FixtureAudio,
        chunkSeconds: Double
    ) throws {
        try waitForReadiness(of: input)

        let channels = Int(audio.channels)
        let framesPerChunk = Int(audio.sampleRate * chunkSeconds)
        let firstFrame = chunk * framesPerChunk

        var asbd = AudioStreamBasicDescription(
            mSampleRate: audio.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(2 * channels),
            mChannelsPerFrame: audio.channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        XCTAssertEqual(
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &format
            ),
            noErr
        )
        let description = try XCTUnwrap(format)

        var samples = [Int16](repeating: 0, count: framesPerChunk * channels)
        for offset in 0..<framesPerChunk {
            let time = Double(firstFrame + offset) / audio.sampleRate
            let value = Int16(sin(2 * .pi * audio.toneHz * time) * 8000)
            for channel in 0..<channels {
                samples[offset * channels + channel] = value
            }
        }

        let byteCount = samples.count * MemoryLayout<Int16>.size
        var block: CMBlockBuffer?
        XCTAssertEqual(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount,
                flags: 0,
                blockBufferOut: &block
            ),
            noErr
        )
        let blockBuffer = try XCTUnwrap(block)
        try samples.withUnsafeBytes { raw in
            XCTAssertEqual(
                CMBlockBufferReplaceDataBytes(
                    with: try XCTUnwrap(raw.baseAddress),
                    blockBuffer: blockBuffer,
                    offsetIntoDestination: 0,
                    dataLength: byteCount
                ),
                noErr
            )
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(audio.sampleRate)),
            presentationTimeStamp: CMTime(
                value: CMTimeValue(firstFrame),
                timescale: CMTimeScale(audio.sampleRate)
            ),
            decodeTimeStamp: .invalid
        )
        var sampleSize = 2 * channels
        var sample: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: description,
                sampleCount: framesPerChunk,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sample
            ),
            noErr
        )
        XCTAssertTrue(input.append(try XCTUnwrap(sample)))
    }

    /// Bounded, so a fixture that cannot make progress fails the test instead of
    /// hanging the suite with no output.
    private func waitForReadiness(of input: AVAssetWriterInput) throws {
        let deadline = Date().addingTimeInterval(30)
        while !input.isReadyForMoreMediaData {
            if Date() > deadline {
                XCTFail("the fixture writer's \(input.mediaType.rawValue) input never became ready")
                throw CocoaError(.fileWriteUnknown)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }
}
