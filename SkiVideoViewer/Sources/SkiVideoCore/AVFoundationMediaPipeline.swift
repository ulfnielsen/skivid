import AVFoundation
import Foundation

/// The in-process media pipeline.
///
/// Replaces an ffmpeg-backed one that ran `/usr/bin/env ffmpeg` and so depended
/// on `PATH` — which a Finder-launched app does not have `/opt/homebrew/bin` on,
/// making resize fail for everyone who did not start the app from a terminal.
/// Being in-process also means this compiles for iOS, where `Process` does not
/// exist at all.
///
/// `AVAssetReader`/`AVAssetWriter` rather than `AVAssetExportSession`: the value
/// of the resize step is bitrate reduction — measured on real footage, the
/// sampled source was already 1080p and the step halved the bitrate from 7.41 to
/// 3.70 Mbps — and an export preset would decide that number for us.
public struct AVFoundationMediaPipeline: MediaPipeline {
    public init() {}

    /// Bits per second per output pixel. 1920 × 1080 × 1.784 ≈ 3.70 Mbps, which
    /// is what the ffmpeg pipeline produced at 1080p.
    private static let bitsPerPixel = 1.784

    public func resize(source: URL, destination: URL, athlete: String) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let asset = AVURLAsset(url: source)
        guard try await asset.load(.isPlayable) else {
            throw MediaPipelineError.unreadableSource(source.lastPathComponent)
        }
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaPipelineError.noVideoTrack(source.lastPathComponent)
        }

        let natural = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let (outWidth, outHeight) = Self.outputSize(natural: natural, transform: transform)

        // Destination must not exist — AVAssetWriter refuses otherwise.
        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        writer.metadata = Self.metadata(athlete: athlete)

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: outWidth,
                AVVideoHeightKey: outHeight,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int((Double(outWidth * outHeight) * Self.bitsPerPixel).rounded()),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ]
        )
        videoInput.expectsMediaDataInRealTime = false
        // Carried, not baked in. Without this a rotated clip comes out sideways,
        // and every generated fixture has an identity transform, so nothing else
        // would notice.
        videoInput.transform = transform
        writer.add(videoInput)

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            ]
        )
        reader.add(videoOutput)

        // Audio is optional: `-map 0:a?` in the pipeline this replaces. A source
        // without audio must produce an output without audio.
        var audioInput: AVAssetWriterInput?
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128_000,
                ]
            )
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            // Decode to LPCM. With `outputSettings: nil` the reader hands back
            // the source's *compressed* samples, and appending compressed AAC
            // to an AAC-encoding input raises NSInvalidArgumentException
            // ("Input buffer must be in an uncompressed format"). Raised inside
            // the old callback-based pump it never reached the caller — the
            // continuation simply never resumed and the resize hung forever.
            // The writer input above is what re-encodes.
            let output = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            )
            reader.add(output)
            audioInput = input
            audioOutput = output
        }

        guard reader.startReading() else {
            throw MediaPipelineError.exportFailed(reader.error?.localizedDescription ?? "could not read \(source.lastPathComponent)")
        }
        guard writer.startWriting() else {
            throw MediaPipelineError.exportFailed(writer.error?.localizedDescription ?? "could not write \(destination.lastPathComponent)")
        }
        writer.startSession(atSourceTime: .zero)

        // Concurrently, not one after the other. A multi-track writer applies
        // backpressure to whichever input has run ahead, so draining video to
        // completion and only then starting audio can deadlock: video waits for
        // a readiness the writer will not grant until audio catches up, and
        // audio is not being pumped yet. Pumping both is also simply what the
        // API is designed for.
        let pumped = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await Self.pump(input: videoInput, from: videoOutput) }
            if let audioInput, let audioOutput {
                group.addTask { await Self.pump(input: audioInput, from: audioOutput) }
            }
            var allFinished = true
            for await finished in group where !finished { allFinished = false }
            return allFinished
        }
        guard pumped else {
            reader.cancelReading()
            writer.cancelWriting()
            throw MediaPipelineError.exportFailed(
                "\(source.lastPathComponent) stopped making progress and was abandoned."
            )
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw MediaPipelineError.exportFailed(writer.error?.localizedDescription ?? "the resize did not complete")
        }
    }

    /// A remux, not an encode — the equivalent of the `-c copy` this replaces —
    /// so there is no encode setting to control and a passthrough export is
    /// right. Passthrough also carries only the tracks AVFoundation recognises,
    /// which reproduces the effect of the old `-map 0:v:0 -map 0:a?`: proprietary
    /// camera telemetry tracks are dropped rather than failing the remux.
    ///
    /// No stall bound, unlike `resize`. `export()` resumes on failure and on
    /// cancellation — measured — but nothing bounds an export that simply never
    /// progresses, and `SortingModel` runs this inside a `Task.detached` that a
    /// serial `OperationQueue` thread waits on with a semaphore, so one wedged
    /// export would stop the whole sort with the UI still responsive. The
    /// bound is deliberately not added: `cancelExport()` makes one expressible,
    /// but a passthrough remux of a large clip off a slow volume can sit at one
    /// progress value for a long stretch, and a false positive would turn a
    /// working tag into an error. No hang has been observed here.
    public func writeMetadata(athlete: String, to url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else {
            throw MediaPipelineError.unreadableSource(url.lastPathComponent)
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw MediaPipelineError.exportFailed("could not tag \(url.lastPathComponent)")
        }

        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".metadata-\(UUID().uuidString).\(url.pathExtension)")
        // Keep this even though no test can currently fail without it, and do
        // not read that as dead code. Measured: on success `replaceItemAt`
        // consumes the temporary, and on a failed export AVFoundation deletes
        // its own half-written output — but a *cancelled* export leaves the
        // partial file behind, and so does a `replaceItemAt` that throws after
        // the export succeeded. Either would strew hidden `.metadata-*` files
        // through the athlete's folder, one per clip of a sort run.
        defer { try? FileManager.default.removeItem(at: temporary) }

        session.outputURL = temporary
        session.outputFileType = .mov
        session.metadata = Self.metadata(athlete: athlete)
        await session.export()
        guard session.status == .completed else {
            throw MediaPipelineError.exportFailed(session.error?.localizedDescription ?? "could not tag \(url.lastPathComponent)")
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    /// Never upscale: `s = min(1920/displayW, 1080/displayH, 1)`, applied to the
    /// *natural* size because the transform rotates the encoded buffer at
    /// playback. Both results are rounded to even numbers — H.264 4:2:0 cannot
    /// encode odd dimensions.
    static func outputSize(natural: CGSize, transform: CGAffineTransform) -> (Int, Int) {
        let display = natural.applying(transform)
        let displayWidth = abs(display.width)
        let displayHeight = abs(display.height)
        guard displayWidth > 0, displayHeight > 0 else { return (0, 0) }
        let scale = min(1920 / displayWidth, 1080 / displayHeight, 1)
        func even(_ value: Double) -> Int {
            let rounded = Int(value.rounded())
            return rounded % 2 == 0 ? rounded : rounded - 1
        }
        return (even(natural.width * scale), even(natural.height * scale))
    }

    static func metadata(athlete: String) -> [AVMetadataItem] {
        [
            (AVMetadataIdentifier.commonIdentifierTitle, athlete),
            (AVMetadataIdentifier.commonIdentifierArtist, athlete),
            (AVMetadataIdentifier.commonIdentifierDescription, "Athlete: \(athlete)"),
        ].map { identifier, value in
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            return item
        }
    }

    /// How long one input may go without accepting a single sample before the
    /// resize is treated as stalled. Generous: it is a deadlock backstop, not a
    /// performance budget. A 4K clip on a busy machine can legitimately leave an
    /// input unready for seconds at a time, but never for half a minute.
    private static let stallTimeout: TimeInterval = 30

    /// Drive one reader output into one writer input until the reader runs dry.
    /// Returns `false` if the input stopped accepting samples altogether.
    ///
    /// Polls rather than using `requestMediaDataWhenReady`, which is the
    /// idiomatic call but hands control to a callback that can only be escaped
    /// through a `CheckedContinuation` — and a continuation cannot be abandoned
    /// on a timeout without leaking it. It also swallows anything AVFoundation
    /// raises inside the block: that is how a compressed-buffer append turned
    /// into an indefinite hang instead of a crash. Polling makes the stall bound
    /// expressible, surfaces failures on the calling task, and lets two pumps
    /// interleave in a task group since each suspends when its input is unready.
    /// The inner loop still pushes as fast as the encoder accepts, so the sleep
    /// only runs when saturated.
    private static func pump(input: AVAssetWriterInput, from output: AVAssetReaderTrackOutput) async -> Bool {
        var lastProgress = Date()
        while true {
            if input.isReadyForMoreMediaData {
                guard let buffer = output.copyNextSampleBuffer() else {
                    input.markAsFinished()
                    return true
                }
                guard input.append(buffer) else {
                    // The writer failed mid-stream; `writer.status` carries the
                    // reason and `resize` turns it into an error.
                    input.markAsFinished()
                    return true
                }
                lastProgress = Date()
            } else {
                guard Date().timeIntervalSince(lastProgress) < stallTimeout else { return false }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
    }
}
