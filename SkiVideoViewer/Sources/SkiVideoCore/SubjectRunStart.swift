import CoreGraphics
import CoreImage
import Foundation
import Vision

/// A single instant's evidence of independent motion: how much of the frame,
/// after the camera's own motion has been cancelled, still changed relative
/// to the previous frame.
public struct ForegroundSample {
    public let time: TimeInterval
    /// Percentage (0...100) of compared pixels that moved independently of
    /// the background.
    public let movingFraction: Double

    public init(time: TimeInterval, movingFraction: Double) {
        self.time = time
        self.movingFraction = movingFraction
    }
}

/// The moment a run is judged to begin, with the numbers that produced the
/// judgement recorded alongside it so the operator can see why, not just
/// trust a number.
public struct RunStart {
    public let time: TimeInterval
    public let baseline: Double
    public let threshold: Double

    public init(time: TimeInterval, baseline: Double, threshold: Double) {
        self.time = time
        self.baseline = baseline
        self.threshold = threshold
    }
}

/// When the picked subject's run begins.
///
/// The whole-frame detector this replaced failed on clips with no quiet
/// lead-in because other skiers' motion is in the signal. Restricting the
/// same measurement to the subject's own box removes them, which is the
/// point of having the operator pick a subject at all. The pan cancellation,
/// the difference threshold and the baseline/threshold/sustain constants are
/// that detector's, unchanged: they were tuned on two clips and are known to
/// be at risk of overfitting, so this does not re-tune them.
public enum SubjectRunStart {
    /// Independent-motion profile measured inside the subject's box, dilated
    /// by `dilation`. Frames where the subject has no detection contribute no
    /// sample — a zero there would read as quiet and could be mistaken for a
    /// pre-run baseline.
    public static func profile(
        frames: [(image: CGImage, time: TimeInterval)],
        candidate: SubjectCandidate,
        dilation: Double = 0.2
    ) -> [ForegroundSample] {
        guard frames.count > 1 else { return [] }

        var boxes: [TimeInterval: CGRect] = [:]
        for detection in candidate.detections {
            boxes[detection.time] = detection.box
        }

        var raw: [(time: TimeInterval, fraction: Double)] = []
        for index in 1..<frames.count {
            guard let box = boxes[frames[index].time] else { continue }
            let dilated = dilate(box, by: dilation)
            let fraction = movingFraction(
                earlier: frames[index - 1].image,
                later: frames[index].image,
                within: dilated
            )
            raw.append((frames[index].time, fraction))
        }

        guard !raw.isEmpty else { return [] }
        let smoothed = movingAverage(raw.map(\.fraction), radius: 2)
        return zip(raw, smoothed).map {
            ForegroundSample(time: $0.time, movingFraction: $1)
        }
    }

    /// The subject's run start, or nil if their motion never leaves baseline.
    public static func detect(
        frames: [(image: CGImage, time: TimeInterval)],
        candidate: SubjectCandidate,
        baselinePercentile: Double = 0.10,
        thresholdMultiplier: Double = 1.8,
        sustainedRiseSeconds: Double = 0.5
    ) -> Outcome {
        runStart(
            in: profile(frames: frames, candidate: candidate),
            baselinePercentile: baselinePercentile,
            thresholdMultiplier: thresholdMultiplier,
            sustainedRiseSeconds: sustainedRiseSeconds
        )
    }

    /// The **first** sustained rise above threshold, not the last quiet stretch.
    ///
    /// `lastQuietRunStart` deliberately takes the sample after the
    /// *last* sustained quiet period, because a whole-frame signal contains
    /// every other skier in the clip and their earlier bumps would otherwise
    /// win. A subject-local signal contains only the picked person, so that
    /// reason is gone — and the rule then actively misfires: measured on
    /// `Idun Nielsen/C0082.MP4`, where the subject is moving from 4.3s to the
    /// end of the clip, mid-run dips of 6.3%, 13.5% and 13.1% fell under the
    /// 17.3% threshold, counted as "quiet", and put the reported start at
    /// 17.0s against a ground truth of ~2s. Taking the first sustained rise
    /// instead gives ~4s on that clip and leaves `C0094`'s answer unchanged.
    ///
    /// A rise must hold for `sustainedRiseSeconds` to count, so a single noisy
    /// sample cannot start a run.
    public static func runStart(
        in samples: [ForegroundSample],
        baselinePercentile: Double = 0.10,
        thresholdMultiplier: Double = 1.8,
        sustainedRiseSeconds: Double = 0.5,
        quietCeiling: Double = 5.0,
        sustainedQuietSeconds: Double = 0.5
    ) -> Outcome {
        guard !samples.isEmpty else { return .noSamples }

        let sorted = samples.map(\.movingFraction).sorted()
        let index = min(
            sorted.count - 1,
            max(0, Int(Double(sorted.count) * baselinePercentile))
        )
        let baseline = sorted[index]
        let threshold = baseline * thresholdMultiplier

        // Was the subject ever demonstrably still before they moved? The
        // baseline is a percentile, so on a clip that is motion from end to
        // end it lands *inside* the run and every relative comparison becomes
        // meaningless. `quietCeiling` is absolute for that reason, and 5% is
        // not a fitted number: measured across all four ground-truth clips, a
        // standing subject's box reads 0.0-2.0% and a skiing one 10-40%, so
        // anything in between separates them with room to spare.
        var quietRunStart: TimeInterval?
        var sawSustainedQuiet = false
        for sample in samples {
            if sample.movingFraction <= quietCeiling {
                let began = quietRunStart ?? sample.time
                quietRunStart = began
                if sample.time - began >= sustainedQuietSeconds { sawSustainedQuiet = true }
            } else {
                quietRunStart = nil
            }
            if sawSustainedQuiet { break }
        }
        guard sawSustainedQuiet else {
            return .alreadyRunning(firstSeen: samples[0].time)
        }

        for start in samples.indices where samples[start].movingFraction > threshold {
            // The rise must hold, not merely occur. Scan forward until either
            // the window is long enough (a real start) or the signal drops
            // back under the threshold (noise, and the search resumes).
            var end = start
            while end < samples.count, samples[end].movingFraction > threshold {
                if samples[end].time - samples[start].time >= sustainedRiseSeconds {
                    return .started(RunStart(
                        time: samples[start].time,
                        baseline: baseline,
                        threshold: threshold
                    ))
                }
                end += 1
            }
        }
        return .neverMoves(baseline: baseline, threshold: threshold)
    }

    /// The rule `SubjectRunStart.runStart` replaced: the sample after the
    /// *last* sustained quiet stretch.
    ///
    /// Kept **only** so the test that distinguishes the two rules has
    /// something to distinguish against — a test asserting "first, not last"
    /// proves nothing if the last-based answer is unavailable to compare
    /// with. It is deliberately not `public`: measured on a whole frame it
    /// ranked bystanders above the racer, and on a subject-local signal it
    /// reads mid-run dips as quiet. Nothing outside the tests may call it.
    static func lastQuietRunStart(
        in samples: [ForegroundSample],
        baselinePercentile: Double = 0.10,
        thresholdMultiplier: Double = 1.8,
        sustainedQuietSeconds: Double = 1.0
    ) -> RunStart? {
        guard !samples.isEmpty else { return nil }

        let sortedFractions = samples.map(\.movingFraction).sorted()
        let percentileIndex = min(
            sortedFractions.count - 1,
            max(0, Int(Double(sortedFractions.count) * baselinePercentile))
        )
        let baseline = sortedFractions[percentileIndex]
        let threshold = baseline * thresholdMultiplier

        // Tracks the start of the current unbroken quiet streak, and the
        // highest index at which such a streak has lasted long enough to
        // count as "sustained". Scanning all the way to the end means a
        // later sustained-quiet stretch always overrides an earlier one —
        // exactly what "does not sustainably return" requires: other
        // skiers' bumps earlier in the clip must not win over the subject's
        // real, permanent rise.
        var quietStreakStart: Int?
        var lastSustainedQuietEnd: Int?
        for index in samples.indices {
            if samples[index].movingFraction <= threshold {
                if quietStreakStart == nil {
                    quietStreakStart = index
                }
                let duration = samples[index].time - samples[quietStreakStart!].time
                if duration >= sustainedQuietSeconds {
                    lastSustainedQuietEnd = index
                }
            } else {
                quietStreakStart = nil
            }
        }

        guard let quietEnd = lastSustainedQuietEnd, quietEnd + 1 < samples.count else {
            return nil
        }
        return RunStart(
            time: samples[quietEnd + 1].time,
            baseline: baseline,
            threshold: threshold
        )
    }

    /// What the profile actually showed. `alreadyRunning` and `neverMoves` are
    /// separate outcomes rather than a shared `nil` because they mean opposite
    /// things to the operator — one says the clip began mid-run and the
    /// reported time is a lower bound, the other says this subject never
    /// moved and is probably the wrong pick.
    public enum Outcome {
        case started(RunStart)
        /// The subject was never demonstrably still, so their run began at or
        /// before the first sample.
        case alreadyRunning(firstSeen: TimeInterval)
        case neverMoves(baseline: Double, threshold: Double)
        case noSamples
    }

    private static func dilate(_ box: CGRect, by fraction: Double) -> CGRect {
        box.insetBy(
            dx: -box.width * CGFloat(fraction) / 2,
            dy: -box.height * CGFloat(fraction) / 2
        )
        .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Registers `later` to `earlier` translationally over the whole frame —
    /// the camera's motion is a property of the frame, not of the box — then
    /// counts differing pixels only inside `box`.
    private static func movingFraction(
        earlier: CGImage, later: CGImage, within box: CGRect
    ) -> Double {
        guard earlier.width == later.width, earlier.height == later.height else { return 0 }
        let width = earlier.width
        let height = earlier.height
        let frame = CGRect(x: 0, y: 0, width: width, height: height)

        var shift = CGPoint.zero
        if let result = try? FrameRegistration.register(
            reference: earlier, floating: later, method: .translational
        ) {
            shift = CGPoint(
                x: CGFloat(result.warp.columns.2.x),
                y: CGFloat(result.warp.columns.2.y)
            )
        }

        let cancelled = CIImage(cgImage: later)
            .transformed(by: CGAffineTransform(translationX: shift.x, y: shift.y))
            .cropped(to: frame)

        guard
            let earlierGray = grayscaleBytes(from: CIImage(cgImage: earlier), in: frame, width: width, height: height),
            let laterGray = grayscaleBytes(from: cancelled, in: frame, width: width, height: height)
        else { return 0 }

        // `box` is normalised top-left-origin; the byte buffers are
        // top-left-origin row-major, so this maps straight across.
        let borderX = Int(ceil(abs(Double(shift.x)))) + 8
        let borderY = Int(ceil(abs(Double(shift.y)))) + 8
        let minX = max(borderX, Int(Double(box.minX) * Double(width)))
        let maxX = min(width - borderX, Int(Double(box.maxX) * Double(width)))
        let minY = max(borderY, Int(Double(box.minY) * Double(height)))
        let maxY = min(height - borderY, Int(Double(box.maxY) * Double(height)))
        guard maxX > minX, maxY > minY else { return 0 }

        var compared = 0
        var moved = 0
        for y in minY..<maxY {
            for x in minX..<maxX {
                let index = y * width + x
                if abs(Int(earlierGray[index]) - Int(laterGray[index])) > 18 { moved += 1 }
                compared += 1
            }
        }
        guard compared > 0 else { return 0 }
        return 100.0 * Double(moved) / Double(compared)
    }

    private static func movingAverage(_ values: [Double], radius: Int) -> [Double] {
        guard !values.isEmpty else { return [] }
        return values.indices.map { index in
            let lo = max(0, index - radius)
            let hi = min(values.count - 1, index + radius)
            let window = values[lo...hi]
            return window.reduce(0, +) / Double(window.count)
        }
    }

    // Render via createCGImage then draw into a CGContext backed by the byte
    // buffer. CIContext.render(toBitmap:) with .R8/DeviceGray silently
    // returns all zeros on this machine — the same note and the same
    // pattern recur in `lastQuietRunStart` below.
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    private static func grayscaleBytes(
        from image: CIImage, in frame: CGRect, width: Int, height: Int
    ) -> [UInt8]? {
        guard let cgImage = context.createCGImage(image, from: frame) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height)
        guard let bitmapContext = CGContext(
            data: &bytes, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        bitmapContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }
}
