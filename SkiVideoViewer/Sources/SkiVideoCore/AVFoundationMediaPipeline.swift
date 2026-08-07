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
// Deliberately does NOT declare `: MediaPipeline` yet — the protocol also
// requires `writeMetadata(athlete:to:)`, which Task 2 adds. Declaring
// conformance here would not compile. Task 2 adds both the method and the
// conformance in one step.
public struct AVFoundationMediaPipeline {
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
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
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

        await Self.pump(input: videoInput, from: videoOutput)
        if let audioInput, let audioOutput {
            await Self.pump(input: audioInput, from: audioOutput)
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw MediaPipelineError.exportFailed(writer.error?.localizedDescription ?? "the resize did not complete")
        }
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

    /// Drive one reader output into one writer input until the reader runs dry.
    ///
    /// `requestMediaDataWhenReady` re-invokes its block whenever the input
    /// drains, and AVFoundation does not guarantee it stops the instant
    /// `markAsFinished()` returns — so the `finished` flag makes a second
    /// invocation a no-op. Resuming a `CheckedContinuation` twice traps.
    /// The block is serialised on `queue`, so the flag needs no other lock.
    private static func pump(input: AVAssetWriterInput, from output: AVAssetReaderTrackOutput) async {
        let queue = DispatchQueue(label: "media-pipeline.\(input.mediaType.rawValue)")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            nonisolated(unsafe) var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    guard let buffer = output.copyNextSampleBuffer() else {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    if !input.append(buffer) {
                        // The writer failed mid-stream; `writer.status` carries
                        // the reason and `resize` turns it into an error.
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }
}
