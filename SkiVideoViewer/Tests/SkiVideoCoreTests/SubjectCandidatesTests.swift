import CoreGraphics
import XCTest
@testable import SkiVideoCore

final class SubjectCandidatesTests: XCTestCase {
    private func detection(
        at time: TimeInterval, cx: Double, cy: Double, height: Double, width: Double? = nil,
        joints: Int = 7
    ) -> PoseDetection {
        // Default width is a fixed multiple of height so most tests can
        // ignore aspect ratio entirely. Callers that need to pin the height
        // gate to the height *axis* specifically (as opposed to width, which
        // moves in lockstep under the default) pass an independent width.
        let width = width ?? height * 0.4
        var points: [String: CGPoint] = [:]
        for index in 0..<joints {
            points["j\(index)"] = CGPoint(x: cx, y: cy)
        }
        return PoseDetection(
            time: time,
            box: CGRect(x: cx - width / 2, y: cy - height / 2, width: width, height: height),
            joints: points,
            averageConfidence: 0.8
        )
    }

    private func tracklet(
        id: Int, from start: TimeInterval, count: Int,
        cx: Double, cy: Double, height: Double, width: Double? = nil, step: TimeInterval = 0.04
    ) -> Tracklet {
        Tracklet(id: id, detections: (0..<count).map { index in
            detection(at: start + Double(index) * step, cx: cx, cy: cy, height: height, width: width)
        })
    }

    func testShortGapWithCompatibleGeometryMerges() {
        // Ends at 0.36s, resumes at 1.16s — a 0.8s gap, under the 1.5s limit,
        // 0.06 of frame width away.
        let a = tracklet(id: 0, from: 0.00, count: 10, cx: 0.37, cy: 0.49, height: 0.23)
        let b = tracklet(id: 1, from: 1.16, count: 8, cx: 0.43, cy: 0.51, height: 0.24)

        let candidates = SubjectCandidates.candidates(from: [a, b])

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].trackletIDs.sorted(), [0, 1])
        XCTAssertEqual(candidates[0].detectionCount, 18)
    }

    func testLongGapDoesNotMerge() {
        // Same geometry, but a 2.4s gap — beyond the 1.5s limit.
        let a = tracklet(id: 0, from: 0.00, count: 10, cx: 0.37, cy: 0.49, height: 0.23)
        let b = tracklet(id: 1, from: 2.76, count: 8, cx: 0.43, cy: 0.51, height: 0.24)

        let candidates = SubjectCandidates.candidates(from: [a, b])

        XCTAssertEqual(candidates.count, 2)
    }

    func testOverlappingTrackletsNeverMerge() {
        // Two tracklets alive at the same time cannot be one person, however
        // close and however similar in size. The overlap here is deliberately
        // small relative to the sample spacing (0.1s overlap against a 0.5s
        // spacing): the position/height gates alone would happily allow this
        // merge (a wide gate from only ~0.2 "misses", and centres 0.028 apart
        // against a ~0.204 gate) — only the explicit non-overlap guard blocks
        // it. Values chosen so removing that guard actually flips the result,
        // unlike a heavily-overlapping pair where a very negative gap already
        // drives the widened gate negative on its own.
        let a = tracklet(id: 0, from: 0.00, count: 3, cx: 0.37, cy: 0.49, height: 0.23, step: 0.5)
        let b = tracklet(id: 1, from: 0.90, count: 3, cx: 0.39, cy: 0.51, height: 0.23, step: 0.5)

        let candidates = SubjectCandidates.candidates(from: [a, b])

        XCTAssertEqual(candidates.count, 2)
    }

    func testIncompatibleHeightAcrossTheGapDoesNotMerge() {
        // Short gap, close by, but a 2.2x jump in HEIGHT specifically — the
        // widths (0.30 -> 0.32, a 1.07x ratio) are deliberately compatible.
        // A box's width is not a fixed multiple of its height here (unlike
        // most other tests' default aspect ratio), so a mutation that reads
        // the gate off box.width instead of box.height cannot pass by
        // coincidence: it would see the compatible width ratio and wrongly
        // allow the merge.
        let a = tracklet(id: 0, from: 0.00, count: 10, cx: 0.37, cy: 0.49, height: 0.10, width: 0.30)
        let b = tracklet(id: 1, from: 0.96, count: 8, cx: 0.41, cy: 0.51, height: 0.22, width: 0.32)

        let candidates = SubjectCandidates.candidates(from: [a, b])

        XCTAssertEqual(candidates.count, 2)
    }

    func testTooFarApartAcrossTheGapDoesNotMerge() {
        // Compatible time gap (0.3s, well under 1.5s) and compatible height
        // (1.05x), but 0.35 of frame width apart — well past even the
        // widened gate (~0.219 after ~0.3 "misses" at this coarse 1.0s
        // sample spacing). Only the position gate can be rejecting this.
        let a = tracklet(id: 0, from: 0.00, count: 2, cx: 0.20, cy: 0.50, height: 0.20, step: 1.0)
        let b = tracklet(id: 1, from: 1.30, count: 2, cx: 0.55, cy: 0.50, height: 0.21, step: 1.0)

        let candidates = SubjectCandidates.candidates(from: [a, b])

        XCTAssertEqual(candidates.count, 2)
    }

    func testGateWideningPermitsAJoinTheBaseGateWouldRefuse() {
        // A 0.30 displacement that the BASE gate (0.21, no widening) would
        // refuse outright, but a 0.35s gap over this 0.1s sample spacing
        // works out to 3.5 "misses", widening the gate to ~0.319 — enough
        // to admit it. This is only reachable through the widening term;
        // neutralising it (jumpWidenPerMiss = 0) collapses the gate back to
        // 0.21 and the merge should then be refused.
        let a = tracklet(id: 0, from: 0.00, count: 4, cx: 0.20, cy: 0.50, height: 0.20, step: 0.1)
        let b = tracklet(id: 1, from: 0.65, count: 4, cx: 0.50, cy: 0.50, height: 0.205, step: 0.1)

        let candidates = SubjectCandidates.candidates(from: [a, b])

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].trackletIDs.sorted(), [0, 1])
    }

    func testBestFrameIsTheOneWithMostJoints() {
        var detections = (0..<6).map { index in
            detection(at: Double(index) * 0.04, cx: 0.44, cy: 0.47, height: 0.21, joints: 5)
        }
        detections[3] = detection(at: 0.12, cx: 0.44, cy: 0.47, height: 0.21, joints: 14)

        let candidates = SubjectCandidates.candidates(from: [Tracklet(id: 0, detections: detections)])

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].bestFrameTime, 0.12, accuracy: 1e-9)
    }

    func testCandidatesAreNumberedByDescendingDetectionCount() {
        let small = tracklet(id: 0, from: 0.00, count: 4, cx: 0.19, cy: 0.44, height: 0.16)
        let large = tracklet(id: 1, from: 0.00, count: 17, cx: 0.81, cy: 0.53, height: 0.29)

        let candidates = SubjectCandidates.candidates(from: [small, large])

        XCTAssertEqual(candidates.map(\.id), [1, 2])
        XCTAssertEqual(candidates[0].detectionCount, 17)
        XCTAssertEqual(candidates[0].trackletIDs, [1])
        XCTAssertEqual(candidates[1].detectionCount, 4)
    }

    func testNumberingIsStableUnderInputOrder() {
        // Two people, each built from two merging tracklets, with EQUAL
        // total detection counts (18 each) so the ids.first tiebreak is the
        // only thing that can order them. The temporally-EARLIER person (E)
        // deliberately holds the LARGER tracklet ids {2, 3}, and the
        // temporally-LATER person (L) holds the SMALLER ids {0, 1} — so the
        // order the grouping loop naturally discovers them in (E first, by
        // time) disagrees with the tiebreak order (L first, by id). That
        // makes both the pre-sort (which must give forward and reversed the
        // same internal processing order) and the tiebreak (which must
        // override natural discovery order) independently load-bearing:
        //   - drop the pre-sort: `reversed`, whose array order isn't already
        //     time-sorted, stops matching `forward` (which happens to already
        //     be time-sorted, so is unaffected) -> the equality check below fails.
        //   - drop the tiebreak: forward and reversed still agree with each
        //     other (both still go through the same pre-sorted processing),
        //     but the shared result becomes [[2,3],[0,1]] (natural discovery
        //     order) instead of the required [[0,1],[2,3]] -> the absolute
        //     check below fails.
        let earlyFirst = tracklet(id: 2, from: 0.00, count: 10, cx: 0.37, cy: 0.49, height: 0.23)
        let earlySecond = tracklet(id: 3, from: 1.16, count: 8, cx: 0.43, cy: 0.51, height: 0.24)
        let lateFirst = tracklet(id: 0, from: 4.00, count: 9, cx: 0.70, cy: 0.30, height: 0.15)
        let lateSecond = tracklet(id: 1, from: 5.12, count: 9, cx: 0.76, cy: 0.32, height: 0.156)

        let forward = SubjectCandidates.candidates(
            from: [earlyFirst, earlySecond, lateFirst, lateSecond]
        )
        let reversed = SubjectCandidates.candidates(
            from: [lateSecond, lateFirst, earlySecond, earlyFirst]
        )

        XCTAssertEqual(forward.map { $0.trackletIDs.sorted() }, [[0, 1], [2, 3]])
        XCTAssertEqual(forward.map(\.detectionCount), [18, 18])
        XCTAssertEqual(forward.map(\.trackletIDs), reversed.map(\.trackletIDs))
        XCTAssertEqual(forward.map(\.detectionCount), reversed.map(\.detectionCount))
    }

    func testNewTrackletJoinsTheLatestEndingCompatibleGroup() {
        // g1 and g2 overlap each other in time (so they can never merge with
        // one another) but share identical position/height, so both are
        // independently compatible with n once it starts after both end. n
        // must join whichever group's tail ends LATEST (g2, id 1) — not
        // whichever was discovered first (g1, id 0).
        let g1 = tracklet(id: 0, from: 0.00, count: 5, cx: 0.50, cy: 0.50, height: 0.20, step: 0.1)
        let g2 = tracklet(id: 1, from: 0.10, count: 5, cx: 0.50, cy: 0.50, height: 0.20, step: 0.1)
        let n = tracklet(id: 2, from: 1.00, count: 5, cx: 0.50, cy: 0.50, height: 0.20, step: 0.1)

        let candidates = SubjectCandidates.candidates(from: [g1, g2, n])

        let groups = candidates.map { $0.trackletIDs.sorted() }
        XCTAssertTrue(groups.contains([1, 2]), "the later-ending group (id 1) should absorb the new tracklet")
        XCTAssertTrue(groups.contains([0]), "the earlier-ending group (id 0) should remain solitary")
    }

    func testChainedMergeComparesAgainstTheMostRecentTailNotTheFirst() {
        // a merges with b (0.8s gap), then c merges with b (0.8s gap) — but
        // the cumulative a-to-c gap is 1.88s, past mergeGapSeconds (1.5s).
        // This only forms one three-tracklet chain if c is compared against
        // b (the group's current tail) rather than a (its first member).
        let a = tracklet(id: 0, from: 0.00, count: 10, cx: 0.30, cy: 0.50, height: 0.20)
        let b = tracklet(id: 1, from: 1.16, count: 8, cx: 0.36, cy: 0.50, height: 0.205)
        let c = tracklet(id: 2, from: 2.24, count: 8, cx: 0.42, cy: 0.50, height: 0.21)

        let candidates = SubjectCandidates.candidates(from: [a, b, c])

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].trackletIDs, [0, 1, 2])
        XCTAssertEqual(candidates[0].detectionCount, 26)
    }

    func testPeakHeightFractionIsTheLargestBoxOverTheCandidatesLife() {
        var detections = (0..<5).map { index in
            detection(at: Double(index) * 0.04, cx: 0.44, cy: 0.47, height: 0.13)
        }
        detections[2] = detection(at: 0.08, cx: 0.44, cy: 0.47, height: 0.38)

        let candidates = SubjectCandidates.candidates(from: [Tracklet(id: 0, detections: detections)])

        XCTAssertEqual(candidates[0].peakHeightFraction, 0.38, accuracy: 1e-9)
    }
}
