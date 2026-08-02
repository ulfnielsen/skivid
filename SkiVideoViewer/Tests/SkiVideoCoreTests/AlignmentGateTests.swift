import CoreGraphics
import XCTest
@testable import SkiVideoCore

final class AlignmentGateTests: XCTestCase {
    /// A track whose overlap follows `overlaps` at 0.5s spacing, with a
    /// translation that grows so interpolation is observable.
    private func track(_ overlaps: [Double]) -> AlignmentTrack {
        sampled(overlaps, spacing: 0.5)
    }

    /// The same, at the pass's real 25 Hz. The median window is measured in
    /// samples, so it only means 0.2 s on a track sampled this way.
    private func denseTrack(_ overlaps: [Double]) -> AlignmentTrack {
        sampled(overlaps, spacing: 0.04)
    }

    private func sampled(_ overlaps: [Double], spacing: TimeInterval) -> AlignmentTrack {
        AlignmentTrack(
            version: 1, computedAt: Date(timeIntervalSince1970: 1_754_140_000),
            leftClip: "L.MP4", rightClip: "R.MP4",
            leftStart: 18.56, rightStart: 4.40, parameters: .current,
            samples: overlaps.enumerated().map { index, overlap in
                AlignmentSample(
                    time: Double(index) * spacing,
                    translation: CGVector(
                        dx: 0.02 + Double(index) * 0.004,
                        dy: -0.01 - Double(index) * 0.003
                    ),
                    overlap: overlap, residual: 5.0, identityResidual: 9.0
                )
            }
        )
    }

    /// The dx the track's own sample at `index` carries. Asserting against this
    /// distinguishes "still inside the engaged run, returning measured
    /// geometry" from "easing an older translation toward identity", which a
    /// bare non-nil check cannot.
    private func measuredDX(at index: Int) -> Double { 0.02 + Double(index) * 0.004 }

    // MARK: - The rules, on the findings' 0.5 s grid, unfiltered

    // These eight pin the gating rules themselves, so they run with
    // `overlapWindow: 1` — the raw-overlap configuration they were written
    // against. The median window is calibrated in samples for 25 Hz; over a
    // 0.5 s grid a 5-sample window would span 2.5 s, and these short synthetic
    // tracks would be testing the filter rather than the rules. The same rules
    // are re-covered at the default window by the 25 Hz tests below.

    func testAHealthyStretchIsAligned() {
        let gate = AlignmentGate.translation(
            in: track([0.91, 0.88, 0.84, 0.86, 0.90]), at: 1.0, overlapWindow: 1
        )
        XCTAssertNotNil(gate)
        XCTAssertEqual(gate?.dx ?? 0, 0.028, accuracy: 1e-9)
    }

    func testALowOverlapStretchIsIdentity() {
        XCTAssertNil(
            AlignmentGate.translation(
                in: track([0.41, 0.26, 0.23, 0.29, 0.35]), at: 1.0, overlapWindow: 1
            )
        )
    }

    /// The whole reason there are two thresholds. A signal wandering inside the
    /// band must hold whatever state it was in, not toggle on every sample.
    func testASignalOscillatingBetweenTheThresholdsDoesNotFlap() {
        // Engages on the first sample, then wanders in 0.55...0.68 forever.
        let wandering = track([0.91, 0.66, 0.57, 0.64, 0.58, 0.67, 0.56, 0.63])
        for step in 1..<8 {
            XCTAssertNotNil(
                AlignmentGate.translation(
                    in: wandering, at: Double(step) * 0.5, overlapWindow: 1
                ),
                "disengaged inside the band at sample \(step)"
            )
        }

        // The mirror: starts disengaged, wanders in the band, stays off.
        let fromBelow = track([0.22, 0.57, 0.66, 0.58, 0.64, 0.61])
        for step in 1..<6 {
            XCTAssertNil(
                AlignmentGate.translation(
                    in: fromBelow, at: Double(step) * 0.5, overlapWindow: 1
                ),
                "engaged inside the band at sample \(step)"
            )
        }
    }

    /// The anti-latch test. The lab exporter stops for the rest of the clip
    /// after three consecutive failures; measured recovery at t=8 held for five
    /// seconds, so that behaviour would discard a genuinely alignable window.
    func testALongDisengagedStretchReEngagesOnRecovery() {
        let recovering = track([0.91, 0.24, 0.31, 0.28, 0.22, 0.26, 0.34, 0.79, 0.83, 0.81])
        XCTAssertNil(AlignmentGate.translation(in: recovering, at: 1.5, overlapWindow: 1))
        XCTAssertNotNil(
            AlignmentGate.translation(in: recovering, at: 4.5, overlapWindow: 1),
            "never re-engaged after a long disengaged stretch"
        )
    }

    func testTheEaseReachesIdentityAndDoesNotOvershoot() {
        // Engaged, then falls off a cliff at t=1.0.
        let falling = track([0.91, 0.88, 0.24, 0.22, 0.20])
        let atCliff = AlignmentGate.translation(in: falling, at: 1.0, overlapWindow: 1)
        let midEase = AlignmentGate.translation(in: falling, at: 1.125, overlapWindow: 1)
        let afterEase = AlignmentGate.translation(in: falling, at: 1.30, overlapWindow: 1)

        // Shrinking toward zero, never past it, and gone by easeSeconds.
        XCTAssertNotNil(midEase)
        XCTAssertLessThan(abs(midEase?.dx ?? 1), abs(atCliff?.dx ?? 0))
        XCTAssertGreaterThanOrEqual(midEase?.dx ?? -1, 0)
        XCTAssertNil(afterEase)
    }

    func testInterpolationHappensInsideAnEngagedRun() {
        let engaged = track([0.91, 0.88, 0.84])
        let between = AlignmentGate.translation(in: engaged, at: 0.25, overlapWindow: 1)

        // Halfway between sample 0 (0.020) and sample 1 (0.024).
        XCTAssertEqual(between?.dx ?? 0, 0.022, accuracy: 1e-9)
    }

    func testAnEmptyTrackIsIdentityEverywhere() {
        XCTAssertNil(AlignmentGate.translation(in: track([]), at: 0, overlapWindow: 1))
        XCTAssertNil(AlignmentGate.translation(in: track([]), at: 5, overlapWindow: 1))
    }

    func testATimeBeyondTheLastSampleIsIdentity() {
        // The pass covers a fixed duration; past its end nothing was measured,
        // and holding the last translation indefinitely is the stale-warp
        // failure this design exists to avoid.
        XCTAssertNil(
            AlignmentGate.translation(in: track([0.91, 0.88]), at: 30, overlapWindow: 1)
        )
    }

    // MARK: - The overlap median filter, at 25 Hz and the default window

    /// The measured case. At 25 Hz registration flips between a small-shift
    /// solution (overlap ~0.79) and a large-shift one (~0.23) on adjacent
    /// frames, so the engaged boundary is a flicker rather than a transition.
    /// Hysteresis cannot suppress it — the flicker swings clear across the
    /// band — so the decision overlap is median-filtered first.
    func testASingleSampleOverlapDropoutDoesNotDisengage() {
        var overlaps = [Double](repeating: 0.85, count: 21)
        overlaps[10] = 0.22
        let dropout = denseTrack(overlaps)

        // Still engaged, and still returning sample 10's own measured
        // translation rather than an eased older one.
        let atDropout = AlignmentGate.translation(in: dropout, at: 0.40)
        XCTAssertNotNil(atDropout, "a single-sample dropout disengaged the gate")
        XCTAssertEqual(atDropout?.dx ?? 0, measuredDX(at: 10), accuracy: 1e-9)

        // Strengthened past the brief's single sample: a mean over five would
        // survive one 0.22 among four 0.85s (it lands near 0.72), so that case
        // alone cannot tell a median from a mean. Two adjacent dropouts can —
        // their mean is 0.53, under `disengageBelow`, while the median is
        // untouched at 0.85. Two isolated flips inside a five-sample window is
        // still exactly what the filter exists to absorb.
        var pairOverlaps = [Double](repeating: 0.85, count: 21)
        pairOverlaps[10] = 0.05
        pairOverlaps[11] = 0.05
        let pairDropout = denseTrack(pairOverlaps)

        let atPair = AlignmentGate.translation(in: pairDropout, at: 0.44)
        XCTAssertNotNil(atPair, "a two-sample dropout disengaged the gate")
        XCTAssertEqual(atPair?.dx ?? 0, measuredDX(at: 11), accuracy: 1e-9)
    }

    /// The filter must not be widenable until nothing ever disengages. A
    /// collapse the median actually follows still has to turn alignment off.
    func testAGenuineMultiSecondCollapseStillDisengages() {
        let collapsing = denseTrack(
            [Double](repeating: 0.85, count: 25) + [Double](repeating: 0.20, count: 100)
        )

        XCTAssertNotNil(
            AlignmentGate.translation(in: collapsing, at: 0.50),
            "never engaged during the healthy stretch"
        )
        XCTAssertNil(
            AlignmentGate.translation(in: collapsing, at: 2.0),
            "a four-second collapse did not disengage"
        )
    }

    /// The mirror of the dropout: an isolated good frame inside a bad stretch
    /// is the same flicker seen from the other side, and must not switch
    /// alignment on for one frame.
    func testASingleSampleOverlapSpikeDoesNotEngage() {
        var overlaps = [Double](repeating: 0.20, count: 21)
        overlaps[10] = 0.95
        XCTAssertNil(
            AlignmentGate.translation(in: denseTrack(overlaps), at: 0.40),
            "a single-sample spike engaged the gate"
        )

        var pairOverlaps = [Double](repeating: 0.20, count: 21)
        pairOverlaps[10] = 0.95
        pairOverlaps[11] = 0.95
        XCTAssertNil(
            AlignmentGate.translation(in: denseTrack(pairOverlaps), at: 0.44),
            "a two-sample spike engaged the gate"
        )
    }

    /// The filter is opt-out, so the unfiltered rules above stay reachable.
    func testAWindowOfOneReproducesTheUnfilteredBehaviour() {
        var overlaps = [Double](repeating: 0.85, count: 21)
        overlaps[10] = 0.22
        let dropout = denseTrack(overlaps)

        // Unfiltered, the raw 0.22 disengages, and what comes back is the
        // previous sample's translation at the head of the ease — not sample
        // 10's own. Filtered, it is sample 10's.
        let unfiltered = AlignmentGate.translation(in: dropout, at: 0.40, overlapWindow: 1)
        XCTAssertNotNil(unfiltered)
        XCTAssertEqual(unfiltered?.dx ?? 0, measuredDX(at: 9), accuracy: 1e-9)

        let filtered = AlignmentGate.translation(in: dropout, at: 0.40)
        XCTAssertEqual(filtered?.dx ?? 0, measuredDX(at: 10), accuracy: 1e-9)

        // Away from the dropout the two agree, so window 1 differs only where
        // the filter has something to do.
        XCTAssertEqual(
            AlignmentGate.translation(in: dropout, at: 0.20, overlapWindow: 1)?.dx ?? 0,
            AlignmentGate.translation(in: dropout, at: 0.20)?.dx ?? -1,
            accuracy: 1e-9
        )
    }

    /// The window is clamped to the track rather than reading out of bounds.
    func testTheMedianWindowIsClampedAtTheTrackEdges() {
        // A dropout on the very first sample: the window can only reach forward.
        var leading = [Double](repeating: 0.85, count: 11)
        leading[0] = 0.22
        XCTAssertNotNil(
            AlignmentGate.translation(in: denseTrack(leading), at: 0),
            "the leading edge did not engage"
        )

        // ...and on the very last, where it can only reach back.
        var trailing = [Double](repeating: 0.85, count: 11)
        trailing[10] = 0.22
        XCTAssertNotNil(
            AlignmentGate.translation(in: denseTrack(trailing), at: 0.40),
            "the trailing edge did not stay engaged"
        )

        // A track shorter than the window at all.
        XCTAssertNotNil(
            AlignmentGate.translation(in: denseTrack([0.85, 0.85, 0.85]), at: 0.04)
        )
    }

    // MARK: - The rules again, at 25 Hz and the default window

    /// Hysteresis under the shipping configuration: the filter must not
    /// swallow the two-threshold behaviour the band exists for.
    func testHysteresisStillHoldsWithTheFilterEngaged() {
        let band = [0.66, 0.57, 0.64, 0.58, 0.67, 0.56, 0.63, 0.60, 0.65, 0.59]

        let wandering = denseTrack([Double](repeating: 0.91, count: 10) + band)
        for index in 10..<20 {
            XCTAssertNotNil(
                AlignmentGate.translation(in: wandering, at: Double(index) * 0.04),
                "disengaged inside the band at sample \(index)"
            )
        }

        let fromBelow = denseTrack([Double](repeating: 0.22, count: 10) + band)
        for index in 10..<20 {
            XCTAssertNil(
                AlignmentGate.translation(in: fromBelow, at: Double(index) * 0.04),
                "engaged inside the band at sample \(index)"
            )
        }
    }

    /// Anti-latch under the shipping configuration.
    func testRecoveryStillReEngagesWithTheFilterEngaged() {
        let recovering = denseTrack(
            [Double](repeating: 0.91, count: 10)
                + [Double](repeating: 0.22, count: 40)
                + [Double](repeating: 0.85, count: 20)
        )
        XCTAssertNil(AlignmentGate.translation(in: recovering, at: 1.0))
        XCTAssertNotNil(
            AlignmentGate.translation(in: recovering, at: 2.4),
            "never re-engaged after a long disengaged stretch"
        )
    }
}
