import CoreGraphics
import XCTest
@testable import SkiVideoCore

final class AlignmentGateTests: XCTestCase {
    /// A track whose overlap follows `overlaps` at 0.5s spacing, with a
    /// translation that grows so interpolation is observable.
    private func track(_ overlaps: [Double]) -> AlignmentTrack {
        AlignmentTrack(
            version: 1, computedAt: Date(timeIntervalSince1970: 1_754_140_000),
            leftClip: "L.MP4", rightClip: "R.MP4",
            leftStart: 18.56, rightStart: 4.40, parameters: .current,
            samples: overlaps.enumerated().map { index, overlap in
                AlignmentSample(
                    time: Double(index) * 0.5,
                    translation: CGVector(
                        dx: 0.02 + Double(index) * 0.004,
                        dy: -0.01 - Double(index) * 0.003
                    ),
                    overlap: overlap, residual: 5.0, identityResidual: 9.0
                )
            }
        )
    }

    func testAHealthyStretchIsAligned() {
        let gate = AlignmentGate.translation(
            in: track([0.91, 0.88, 0.84, 0.86, 0.90]), at: 1.0
        )
        XCTAssertNotNil(gate)
        XCTAssertEqual(gate?.dx ?? 0, 0.028, accuracy: 1e-9)
    }

    func testALowOverlapStretchIsIdentity() {
        XCTAssertNil(
            AlignmentGate.translation(in: track([0.41, 0.26, 0.23, 0.29, 0.35]), at: 1.0)
        )
    }

    /// The whole reason there are two thresholds. A signal wandering inside the
    /// band must hold whatever state it was in, not toggle on every sample.
    func testASignalOscillatingBetweenTheThresholdsDoesNotFlap() {
        // Engages on the first sample, then wanders in 0.55...0.68 forever.
        let wandering = track([0.91, 0.66, 0.57, 0.64, 0.58, 0.67, 0.56, 0.63])
        for step in 1..<8 {
            XCTAssertNotNil(
                AlignmentGate.translation(in: wandering, at: Double(step) * 0.5),
                "disengaged inside the band at sample \(step)"
            )
        }

        // The mirror: starts disengaged, wanders in the band, stays off.
        let fromBelow = track([0.22, 0.57, 0.66, 0.58, 0.64, 0.61])
        for step in 1..<6 {
            XCTAssertNil(
                AlignmentGate.translation(in: fromBelow, at: Double(step) * 0.5),
                "engaged inside the band at sample \(step)"
            )
        }
    }

    /// The anti-latch test. The lab exporter stops for the rest of the clip
    /// after three consecutive failures; measured recovery at t=8 held for five
    /// seconds, so that behaviour would discard a genuinely alignable window.
    func testALongDisengagedStretchReEngagesOnRecovery() {
        let recovering = track([0.91, 0.24, 0.31, 0.28, 0.22, 0.26, 0.34, 0.79, 0.83, 0.81])
        XCTAssertNil(AlignmentGate.translation(in: recovering, at: 1.5))
        XCTAssertNotNil(
            AlignmentGate.translation(in: recovering, at: 4.5),
            "never re-engaged after a long disengaged stretch"
        )
    }

    func testTheEaseReachesIdentityAndDoesNotOvershoot() {
        // Engaged, then falls off a cliff at t=1.0.
        let falling = track([0.91, 0.88, 0.24, 0.22, 0.20])
        let atCliff = AlignmentGate.translation(in: falling, at: 1.0)
        let midEase = AlignmentGate.translation(in: falling, at: 1.125)
        let afterEase = AlignmentGate.translation(in: falling, at: 1.30)

        // Shrinking toward zero, never past it, and gone by easeSeconds.
        XCTAssertNotNil(midEase)
        XCTAssertLessThan(abs(midEase?.dx ?? 1), abs(atCliff?.dx ?? 0))
        XCTAssertGreaterThanOrEqual(midEase?.dx ?? -1, 0)
        XCTAssertNil(afterEase)
    }

    func testInterpolationHappensInsideAnEngagedRun() {
        let engaged = track([0.91, 0.88, 0.84])
        let between = AlignmentGate.translation(in: engaged, at: 0.25)

        // Halfway between sample 0 (0.020) and sample 1 (0.024).
        XCTAssertEqual(between?.dx ?? 0, 0.022, accuracy: 1e-9)
    }

    func testAnEmptyTrackIsIdentityEverywhere() {
        XCTAssertNil(AlignmentGate.translation(in: track([]), at: 0))
        XCTAssertNil(AlignmentGate.translation(in: track([]), at: 5))
    }

    func testATimeBeyondTheLastSampleIsIdentity() {
        // The pass covers a fixed duration; past its end nothing was measured,
        // and holding the last translation indefinitely is the stale-warp
        // failure this design exists to avoid.
        XCTAssertNil(AlignmentGate.translation(in: track([0.91, 0.88]), at: 30))
    }
}
