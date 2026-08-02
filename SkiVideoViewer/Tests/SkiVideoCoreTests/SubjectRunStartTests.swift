import CoreGraphics
import XCTest
@testable import SkiVideoCore

final class SubjectRunStartTests: XCTestCase {
    /// A fixed textured 160x120 background, converted to grayscale bytes
    /// once and reused (unchanged) for every frame in every test. Built from
    /// `TestImageFactory.textured` — the same randomly-placed, randomly-sized
    /// (6-32px) blob texture `RunStartDetectorTests` already relies on —
    /// rather than a literally flat grey field or per-pixel noise.
    ///
    /// Both alternatives were tried and empirically measured (not just
    /// suspected) to break registration:
    /// - A flat grey field gives Vision's
    ///   `VNTranslationalImageRegistrationRequest` nothing to match; it then
    ///   returns a large, high-"confidence" but meaningless translation for
    ///   almost any pair (~100-119px on this 160px-wide frame). The
    ///   border-exclusion band in `movingFraction` scales with that shift, so
    ///   a bogus 100+px shift excludes almost the entire frame — including
    ///   the subject's box — regardless of where the box is, silently
    ///   zeroing the signal both tests actually needed to see.
    /// - Independent per-pixel random noise gives Vision plenty to match,
    ///   but since it has no spatial correlation, a registration that is off
    ///   by even one pixel desyncs the *entire* frame (not just near an
    ///   edge), producing near-random diffs everywhere and reporting motion
    ///   far outside any real moving square.
    /// The blob texture is large-scale enough that a small registration
    /// residual only disturbs blob edges, and gives Vision enough
    /// corner-like structure to find the true (here: zero, nothing pans)
    /// shift.
    private static let backgroundBytes: [UInt8] = {
        let width = 160, height = 120
        let textured = TestImageFactory.textured(width: width, height: height, seed: 7)
        var bytes = [UInt8](repeating: 0, count: width * height)
        let context = CGContext(
            data: &bytes, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.draw(textured, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }()

    /// The fixed textured background (see `backgroundBytes`) with optional
    /// filled squares stamped on top.
    private func frame(squares: [(x: Int, y: Int, size: Int, value: UInt8)]) -> CGImage {
        let width = 160, height = 120
        var bytes = Self.backgroundBytes
        for square in squares {
            for y in square.y..<min(height, square.y + square.size) {
                for x in square.x..<min(width, square.x + square.size) {
                    bytes[y * width + x] = square.value
                }
            }
        }
        let context = CGContext(
            data: &bytes, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        return context.makeImage()!
    }

    private func candidate(boxes: [(TimeInterval, CGRect)]) -> SubjectCandidate {
        let detections = boxes.map { time, box in
            PoseDetection(time: time, box: box, joints: ["nose": CGPoint(x: box.midX, y: box.minY)], averageConfidence: 0.9)
        }
        return SubjectCandidate(
            id: 1, trackletIDs: [0], detections: detections,
            firstSeen: detections.first?.time ?? 0,
            lastSeen: detections.last?.time ?? 0,
            detectionCount: detections.count,
            bestFrameTime: detections.first?.time ?? 0,
            bestFrameBox: detections.first?.box ?? .zero,
            peakHeightFraction: detections.map(\.height).max() ?? 0
        )
    }

    func testMotionOutsideTheSubjectBoxIsIgnored() {
        // A square moving on the right of the frame; the subject's box is a
        // static region on the left. The profile must stay near zero.
        // This is the load-bearing test: without box restriction this is just
        // the whole-frame detector and reports the moving square.
        var frames: [(image: CGImage, time: TimeInterval)] = []
        for step in 0..<12 {
            frames.append((
                frame(squares: [(x: 96 + step * 3, y: 41, size: 13, value: 20)]),
                Double(step) * 0.04
            ))
        }
        let subjectBox = CGRect(x: 0.06, y: 0.31, width: 0.17, height: 0.29)
        let subject = candidate(boxes: frames.map { ($0.time, subjectBox) })

        let profile = SubjectRunStart.profile(frames: frames, candidate: subject)

        XCTAssertFalse(profile.isEmpty)
        // Bound tightened from an original 1.0: the square never enters the
        // box, so a correct measurement is exactly 0 every sample. 1.0 did
        // not discriminate — measured directly, the mutation this test
        // exists to catch (comparing the whole frame instead of the box)
        // still reports only ~0.52% here, because this square is small
        // relative to the whole frame, so a bound merely "close to zero"
        // passed regardless of whether the box restriction was even applied.
        // 0.1 sits strictly between the correct value (0) and the mutant's
        // (~0.52), so removing the box restriction now actually fails this
        // test — confirmed via the mutation check in the task report.
        for sample in profile {
            XCTAssertLessThan(sample.movingFraction, 0.1, "at t=\(sample.time)")
        }
    }

    func testMotionInsideTheSubjectBoxIsReported() {
        // The mirror: the square moves inside the subject's box.
        var frames: [(image: CGImage, time: TimeInterval)] = []
        for step in 0..<12 {
            frames.append((
                frame(squares: [(x: 14 + step * 3, y: 41, size: 13, value: 20)]),
                Double(step) * 0.04
            ))
        }
        let subjectBox = CGRect(x: 0.06, y: 0.31, width: 0.42, height: 0.29)
        let subject = candidate(boxes: frames.map { ($0.time, subjectBox) })

        let profile = SubjectRunStart.profile(frames: frames, candidate: subject)

        // Measured (not assumed): a 13px square stepping 3px/frame inside
        // this dilated box, with the fixed 8px border margin `movingFraction`
        // excludes on every side, changes exactly 78 of 3150 compared pixels
        // every frame — 2.48%, deterministically, not a flaky measurement.
        // The bound is set below that, comfortably above the near-zero
        // result the mirror test (`testMotionOutsideTheSubjectBoxIsIgnored`)
        // requires, so it still discriminates "seen" from "not seen".
        XCTAssertGreaterThan(profile.map(\.movingFraction).max() ?? 0, 2.0)
    }

    func testFramesWhereTheSubjectIsAbsentProduceNoSample() {
        // A zero would read as "quiet" and could be mistaken for a pre-run
        // baseline, so absence must produce no sample at all.
        var frames: [(image: CGImage, time: TimeInterval)] = []
        for step in 0..<10 {
            frames.append((frame(squares: []), Double(step) * 0.04))
        }
        let box = CGRect(x: 0.11, y: 0.23, width: 0.19, height: 0.34)
        // Detections only for the first four sample times.
        let subject = candidate(boxes: (0..<4).map { (Double($0) * 0.04, box) })

        let profile = SubjectRunStart.profile(frames: frames, candidate: subject)

        XCTAssertTrue(profile.allSatisfy { $0.time <= 0.12 + 1e-9 })
    }

    // MARK: - runStart

    private func samples(_ pairs: [(TimeInterval, Double)]) -> [ForegroundSample] {
        pairs.map { ForegroundSample(time: $0.0, movingFraction: $0.1) }
    }

    private func startTime(_ outcome: SubjectRunStart.Outcome) -> TimeInterval? {
        if case let .started(start) = outcome { return start.time }
        return nil
    }

    func testTakesTheFirstSustainedRiseNotTheLast() {
        // The measured C0082 failure as a regression test. The subject is
        // still for 1.2s, then moves for the rest of the clip, with one long
        // mid-run dip that falls under the *relative* threshold while being
        // nowhere near actually still.
        //
        // The numbers are chosen so both rules produce an answer and the
        // answers differ — otherwise this test proves nothing. 40 samples put
        // the 10th-percentile baseline at 5.8%, so the threshold is 10.4%: the
        // dip block sits below it and reads as "quiet" to a rule looking for
        // quiet, while staying above the 5% absolute ceiling so it is not
        // mistaken for the subject actually standing still.
        // `SubjectRunStart.lastQuietRunStart`'s last-quiet rule returns 12.0s
        // here. The answer is 1.6s.
        var pairs: [(TimeInterval, Double)] = []
        for step in 0..<40 {
            let time: TimeInterval = Double(step) * 0.4
            let value: Double
            switch step {
            case 0: value = 0.5
            case 1: value = 0.6
            case 2: value = 0.4
            case 3: value = 0.7
            case 25: value = 6.0
            case 26: value = 6.2
            case 27: value = 5.8
            case 28: value = 6.4
            case 29: value = 6.1
            default: value = 31.0 + Double(step % 9)
            }
            pairs.append((time, value))
        }

        // Guard the premise: if the legacy rule agreed, or declined to answer,
        // this test could pass under either implementation and would be worth
        // nothing.
        let legacy = SubjectRunStart.lastQuietRunStart(in: samples(pairs))
        XCTAssertEqual(legacy?.time ?? -1, 12.0, accuracy: 1e-9)

        let outcome = SubjectRunStart.runStart(in: samples(pairs))

        XCTAssertEqual(startTime(outcome) ?? -1, 1.6, accuracy: 1e-9)
    }

    func testASubjectNeverStillIsReportedAsAlreadyRunning() {
        let pairs: [(TimeInterval, Double)] = (0..<20).map { step in
            let time: TimeInterval = 0.1 + Double(step) * 0.4
            let value: Double = 14.0 + Double(step % 7) * 3.0
            return (time, value)
        }

        let outcome = SubjectRunStart.runStart(in: samples(pairs))

        guard case let .alreadyRunning(firstSeen) = outcome else {
            return XCTFail("expected alreadyRunning, got \(outcome)")
        }
        XCTAssertEqual(firstSeen, 0.1, accuracy: 1e-9)
    }

    func testASubjectThatNeverMovesIsNotAStart() {
        let pairs: [(TimeInterval, Double)] = (0..<20).map { step in
            let time: TimeInterval = 0.1 + Double(step) * 0.4
            let value: Double = 0.3 + Double(step % 3) * 0.2
            return (time, value)
        }

        guard case .neverMoves = SubjectRunStart.runStart(in: samples(pairs)) else {
            return XCTFail("expected neverMoves")
        }
    }

    func testASingleSpikeDoesNotStartARun() {
        // Quiet, one lone high sample, quiet again, then a real sustained
        // rise. The spike must not win.
        var pairs: [(TimeInterval, Double)] = []
        for step in 0..<8 { pairs.append((Double(step) * 0.4, 0.4)) }
        pairs[3] = (1.2, 37.0)
        for step in 0..<8 { pairs.append((3.2 + Double(step) * 0.4, 29.0 + Double(step))) }

        let outcome = SubjectRunStart.runStart(in: samples(pairs))

        XCTAssertEqual(startTime(outcome) ?? -1, 3.2, accuracy: 1e-9)
    }

    func testQuietCeilingIsAbsoluteNotRelativeToTheBaseline() {
        // Every sample sits between 11% and 17%, so a 10th-percentile
        // baseline lands at 11% and a 1.8x relative threshold is 19.8%, which
        // nothing crosses. A purely relative rule calls this "never moves".
        // The absolute ceiling correctly calls it a clip that began mid-run.
        let pairs: [(TimeInterval, Double)] = (0..<16).map { step in
            let time: TimeInterval = 0.1 + Double(step) * 0.4
            let value: Double = 11.0 + Double(step % 5) * 1.5
            return (time, value)
        }

        guard case .alreadyRunning = SubjectRunStart.runStart(in: samples(pairs)) else {
            return XCTFail("expected alreadyRunning")
        }
    }
}
