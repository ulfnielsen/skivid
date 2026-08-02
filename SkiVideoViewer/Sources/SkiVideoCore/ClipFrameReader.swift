import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

/// Decodes a clip's frames sequentially at a target rate and width.
///
/// Sequential decode through `AVAssetReader`, not per-frame seeking: a
/// 46s clip at 25fps is ~1160 frames, and building an asset and generator
/// per frame to seek to it is orders of magnitude slower than reading the
/// track through once and keeping the frames that land on the sample grid.
public enum ClipFrameReader {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    public struct ReadError: Error, CustomStringConvertible {
        public let description: String

        public init(description: String) {
            self.description = description
        }
    }

    /// Returns frames at approximately `fps`, scaled so the widest side is
    /// `targetWidth`, covering `[from, to]` (the whole clip when `to` is nil).
    ///
    /// Holds every frame in memory. Fine at the 320px detection width; at the
    /// 1280px validation width a 46s clip would be several gigabytes, so that
    /// path uses `forEachFrame` instead.
    public static func frames(
        from url: URL,
        fps: Double,
        targetWidth: Double,
        from start: TimeInterval = 0,
        to end: TimeInterval? = nil
    ) throws -> [(image: CGImage, time: TimeInterval)] {
        var collected: [(image: CGImage, time: TimeInterval)] = []
        try forEachFrame(from: url, fps: fps, targetWidth: targetWidth, from: start, to: end) {
            collected.append(($0, $1))
        }
        return collected
    }

    /// The same decode as `frames`, handing each frame to `body` and letting it
    /// go again rather than accumulating them.
    ///
    /// Same sampling decisions, same scaling, same error reporting — `frames`
    /// is written in terms of this — so a caller that streams and a caller that
    /// collects see exactly the same frames at exactly the same times. That
    /// matters here: the validation video is drawn from a second read of the
    /// clip at a different width, and its frames have to line up sample for
    /// sample with the detection pass or the overlay would be one frame out.
    static func forEachFrame(
        from url: URL,
        fps: Double,
        targetWidth: Double,
        from start: TimeInterval = 0,
        to end: TimeInterval? = nil,
        _ body: (CGImage, TimeInterval) throws -> Void
    ) throws {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw ReadError(description: "no video track in \(url.lastPathComponent)")
        }

        let reader = try AVAssetReader(asset: asset)
        let duration = CMTimeGetSeconds(asset.duration)
        let upperBound = end ?? duration
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: max(0, upperBound - start), preferredTimescale: 600)
        )

        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ReadError(description: "cannot read video track of \(url.lastPathComponent)")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw ReadError(description: "reader failed to start: \(reader.error?.localizedDescription ?? "unknown")")
        }

        let interval = 1.0 / fps
        var nextWanted = start

        while let sample = output.copyNextSampleBuffer() {
            // Per-frame pool: streaming a 46s clip at 1280px produces ~1160
            // multi-megabyte autoreleased buffers, and without draining them
            // frame by frame the "streaming" reader peaks at the same
            // gigabytes the collecting one does.
            try autoreleasepool {
                let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                guard time + 1e-9 >= nextWanted else { return }
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }

                let ciImage = CIImage(cvPixelBuffer: buffer)
                let factor = targetWidth / ciImage.extent.width
                let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
                if let cgImage = context.createCGImage(scaled, from: scaled.extent) {
                    try body(cgImage, time)
                }
                // Advance past the frame just taken rather than by one interval
                // from where we wanted it, so a clip whose real rate is below
                // `fps` does not accumulate a backlog of wanted times.
                nextWanted = max(nextWanted + interval, time + interval * 0.5)
            }
        }

        if reader.status == .failed {
            throw ReadError(description: "read failed: \(reader.error?.localizedDescription ?? "unknown")")
        }
    }
}
