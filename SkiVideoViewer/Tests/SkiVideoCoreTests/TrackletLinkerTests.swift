import CoreGraphics
import XCTest
@testable import SkiVideoCore

final class TrackletLinkerTests: XCTestCase {
    /// Builds a detection whose box is centred at (cx, cy) with the given
    /// height. `width` defaults to 40% of the height — roughly a standing
    /// person — but every test below passes explicit widths that are *not*
    /// a fixed multiple of the height, so a gate mistakenly keyed on
    /// `box.width` cannot masquerade as the height gate and pass anyway.
    private func detection(
        at time: TimeInterval, cx: Double, cy: Double, height: Double,
        width: Double? = nil, confidence: Double = 0.8
    ) -> PoseDetection {
        let width = width ?? height * 0.4
        return PoseDetection(
            time: time,
            box: CGRect(x: cx - width / 2, y: cy - height / 2, width: width, height: height),
            joints: ["nose": CGPoint(x: cx, y: cy - height / 2)],
            averageConfidence: confidence
        )
    }

    private func frames(_ groups: [(TimeInterval, [PoseDetection])]) -> [FrameDetections] {
        groups.map { FrameDetections(time: $0.0, poses: $0.1) }
    }

    // MARK: - Separation

    func testTwoWellSeparatedPeopleStayDistinct() {
        // Two people, each drifting slightly, half a frame apart throughout.
        // Widths cycle independently of height so neither track's continuity
        // could be explained by a width-keyed gate.
        var groups: [(TimeInterval, [PoseDetection])] = []
        for step in 0..<10 {
            let t = Double(step) * 0.04
            let drift = Double(step) * 0.003
            let wobble = Double(step % 3) * 0.007
            groups.append((t, [
                detection(at: t, cx: 0.18 + drift, cy: 0.52, height: 0.24, width: 0.086 + wobble),
                detection(at: t, cx: 0.73 - drift, cy: 0.47, height: 0.19, width: 0.070 + wobble),
            ]))
        }
        let tracklets = TrackletLinker.link(frames(groups))

        XCTAssertEqual(tracklets.count, 2)
        XCTAssertEqual(tracklets.map(\.detections.count).sorted(), [10, 10])
    }

    // MARK: - Misses

    func testTrackSurvivesAShortMiss() {
        // Present, absent for 3 samples, present again nearby. The track's
        // own recent step is 0.0224, so its base gate is 4 * that = 0.0894,
        // widened by 3 misses to 0.0894 * 2.5 = 0.2236 — comfortably over
        // the 0.0632 it has to reach.
        let groups: [(TimeInterval, [PoseDetection])] = [
            (0.00, [detection(at: 0.00, cx: 0.31, cy: 0.46, height: 0.220, width: 0.088)]),
            (0.04, [detection(at: 0.04, cx: 0.33, cy: 0.47, height: 0.220, width: 0.075)]),
            (0.08, []),
            (0.12, []),
            (0.16, []),
            (0.20, [detection(at: 0.20, cx: 0.39, cy: 0.49, height: 0.230, width: 0.097)]),
        ]
        let tracklets = TrackletLinker.link(frames(groups))

        XCTAssertEqual(tracklets.count, 1)
        XCTAssertEqual(tracklets[0].detections.count, 3)
    }

    func testTrackEndsAfterTooManyMisses() {
        // Present, absent for 6 samples with maxMisses 4 — the track ends on
        // the 4th miss — then present again close by. Because the track is
        // already finished, the late detection cannot extend it however
        // reachable it looks.
        var groups: [(TimeInterval, [PoseDetection])] = [
            (0.00, [detection(at: 0.00, cx: 0.31, cy: 0.46, height: 0.220, width: 0.081)]),
        ]
        for step in 1...6 {
            groups.append((Double(step) * 0.04, []))
        }
        groups.append((0.28, [detection(at: 0.28, cx: 0.34, cy: 0.48, height: 0.220, width: 0.094)]))

        let tracklets = TrackletLinker.link(frames(groups), maxMisses: 4)

        XCTAssertEqual(tracklets.count, 2)
        XCTAssertEqual(tracklets.map(\.detections.count).sorted(), [1, 1])
    }

    func testGateWidensWithConsecutiveMisses() {
        // The track's recent step is 0.0200, so its base gate is 0.0799. It
        // then misses 3 samples and must reach 0.1300 — beyond the base gate
        // but inside 0.0799 * (1 + 0.5 * 3) = 0.1998. The height ratio
        // (1.062) is inside even the unwidened height gate, so distance is
        // the only thing under test.
        let groups: [(TimeInterval, [PoseDetection])] = [
            (0.00, [detection(at: 0.00, cx: 0.2400, cy: 0.4600, height: 0.220, width: 0.085)]),
            (0.04, [detection(at: 0.04, cx: 0.2570, cy: 0.4495, height: 0.226, width: 0.096)]),
            (0.08, []),
            (0.12, []),
            (0.16, []),
            (0.20, [detection(at: 0.20, cx: 0.3790, cy: 0.4943, height: 0.240, width: 0.104)]),
        ]
        let tracklets = TrackletLinker.link(frames(groups))

        XCTAssertEqual(tracklets.count, 1, "the widened gate should reacquire at 0.130")
        XCTAssertEqual(tracklets[0].detections.count, 3)

        // Control: without widening the same reacquisition is out of reach,
        // which is what makes the assertion above about widening rather than
        // about the base gate being generous.
        let unwidened = TrackletLinker.link(frames(groups), widenPerMiss: 0)
        XCTAssertEqual(unwidened.count, 2, "0.130 is outside the unwidened 0.0799 gate")
    }

    // MARK: - Height gate

    func testHeightGateRejectsAShrinkingJumpTheDistanceGateAllows() {
        // A second person appears very close by but at a third the height.
        // Distance alone (0.0148, well inside the 0.06 initial gate) would
        // happily link them; the two-sided height ratio must not. Widths are
        // deliberately *not* proportional to height (0.160 and 0.150, a ratio
        // of 1.067 that is inside the height gate) so a gate mistakenly keyed
        // on box.width would wrongly pass this jump.
        let groups: [(TimeInterval, [PoseDetection])] = [
            (0.00, [detection(at: 0.00, cx: 0.420, cy: 0.510, height: 0.270, width: 0.160)]),
            (0.04, [detection(at: 0.04, cx: 0.433, cy: 0.503, height: 0.090, width: 0.150)]),
        ]
        let tracklets = TrackletLinker.link(frames(groups))

        XCTAssertEqual(tracklets.count, 2)
    }

    func testHeightGateRejectsAGrowingJumpToo() {
        // The mirror image: a nearby detection three times the height. A
        // one-sided ratio check passes this and is wrong. As above, widths
        // (0.150 and 0.160) are independent of height so this test would
        // also catch a gate mistakenly keyed on width.
        let groups: [(TimeInterval, [PoseDetection])] = [
            (0.00, [detection(at: 0.00, cx: 0.420, cy: 0.510, height: 0.090, width: 0.150)]),
            (0.04, [detection(at: 0.04, cx: 0.433, cy: 0.503, height: 0.270, width: 0.160)]),
        ]
        let tracklets = TrackletLinker.link(frames(groups))

        XCTAssertEqual(tracklets.count, 2)
    }

    // MARK: - Distance gate

    func testDistanceGateRejectsAFarJumpOfCompatibleHeight() {
        // Compatible heights (ratio 1.022) and compatible widths (1.099, also
        // inside the height gate), but 0.600 of frame width away — far beyond
        // the 0.06 gate a track with no measured speed gets.
        let groups: [(TimeInterval, [PoseDetection])] = [
            (0.00, [detection(at: 0.00, cx: 0.170, cy: 0.440, height: 0.230, width: 0.081)]),
            (0.04, [detection(at: 0.04, cx: 0.770, cy: 0.462, height: 0.235, width: 0.089)]),
        ]
        let tracklets = TrackletLinker.link(frames(groups))

        XCTAssertEqual(tracklets.count, 2)
    }

    func testANewTrackUsesTheInitialJumpFractionNotTheSpeedFloor() {
        // A track with a single detection has no measured speed. It must fall
        // back to `initialJumpFraction` (0.06) — not to `speedFloor` (0.02),
        // which is a floor for tracks *known* to be slow, not for tracks
        // nothing is known about yet.
        let start = detection(at: 0.00, cx: 0.3000, cy: 0.4000, height: 0.180, width: 0.085)

        // 0.050 away: inside 0.06, outside 0.02.
        let near = TrackletLinker.link(frames([
            (0.00, [start]),
            (0.04, [detection(at: 0.04, cx: 0.3468, cy: 0.4176, height: 0.186, width: 0.072)]),
        ]))
        XCTAssertEqual(near.count, 1, "0.050 is inside initialJumpFraction 0.06")
        XCTAssertEqual(near[0].detections.count, 2)

        // 0.090 away: outside 0.06.
        let far = TrackletLinker.link(frames([
            (0.00, [start]),
            (0.04, [detection(at: 0.04, cx: 0.3842, cy: 0.4317, height: 0.186, width: 0.072)]),
        ]))
        XCTAssertEqual(far.count, 2, "0.090 is outside initialJumpFraction 0.06")
    }

    // MARK: - Speed-derived gate

    func testAFastTrackToleratesAJumpASlowTrackRejects() {
        // Two tracks with the same shape of history in different corners of
        // the frame: one has been moving 0.050 per sample, the other 0.005.
        // Each is then offered a detection exactly 0.150 away, on the same
        // bearing, with a height well inside the height gate. The fast track
        // (gate 4 * 0.050 = 0.200) must take its detection; the slow one
        // (gate max(0.02, 4 * 0.005) = 0.020) must not.
        //
        // This is the test that distinguishes a gate derived from motion from
        // any constant: no single constant accepts 0.150 for one track and
        // rejects it for the other.
        var groups: [(TimeInterval, [PoseDetection])] = []
        let fastHeights = [0.190, 0.196, 0.188, 0.193]
        let fastWidths = [0.079, 0.091, 0.070, 0.085]
        let slowHeights = [0.260, 0.253, 0.264, 0.257]
        let slowWidths = [0.104, 0.093, 0.112, 0.099]
        for step in 0..<4 {
            let t = Double(step) * 0.04
            groups.append((t, [
                detection(
                    at: t,
                    cx: 0.1000 + Double(step) * 0.0472,
                    cy: 0.3000 + Double(step) * 0.0164,
                    height: fastHeights[step], width: fastWidths[step]
                ),
                detection(
                    at: t,
                    cx: 0.7000 + Double(step) * 0.00472,
                    cy: 0.7000 + Double(step) * 0.00164,
                    height: slowHeights[step], width: slowWidths[step]
                ),
            ]))
        }
        let fastTarget = detection(at: 0.16, cx: 0.3816, cy: 0.4031, height: 0.199, width: 0.096)
        let slowTarget = detection(at: 0.16, cx: 0.85416, cy: 0.75882, height: 0.266, width: 0.088)
        groups.append((0.16, [fastTarget, slowTarget]))

        let tracklets = TrackletLinker.link(frames(groups))

        XCTAssertEqual(
            tracklets.map(\.detections.count).sorted(), [1, 4, 5],
            "the fast track should extend to 5, the slow track should stop at 4 and leave its "
            + "0.150 detection to start a track of its own"
        )
        let fast = tracklets.first { $0.detections.count == 5 }
        XCTAssertEqual(
            fast?.detections.last?.box.midX ?? 0, fastTarget.box.midX, accuracy: 1e-9,
            "the 5-detection track must be the fast one, extended by its own target"
        )
        let slow = tracklets.first { $0.detections.count == 4 }
        XCTAssertEqual(
            slow?.detections.last?.time ?? 0, 0.12, accuracy: 1e-9,
            "the slow track must end at its last hit, not reach 0.16"
        )
    }

    // MARK: - The measured C0094 failure

    func testTrackDoesNotJumpToADistantLargerPersonAfterAMiss() {
        // Regression test for the swap measured on `Idun Nielsen/C0094.MP4`:
        // the athlete is tracked at ~0.015 of frame width per sample, is
        // missed for a frame, and a bystander's detection 0.206 away at 1.86x
        // her box height is the only thing on offer. The old constant gates
        // (0.21 distance, 2.0 height) admitted him on both counts and the
        // track continued as a different person for the rest of the clip.
        var groups: [(TimeInterval, [PoseDetection])] = []
        let heights = [0.178, 0.182, 0.176, 0.181, 0.180]
        let widths = [0.071, 0.083, 0.066, 0.078, 0.090]
        for step in 0..<5 {
            let t = Double(step) * 0.04
            groups.append((t, [detection(
                at: t,
                cx: 0.3000 + Double(step) * 0.0138,
                cy: 0.5000 + Double(step) * 0.0059,
                height: heights[step], width: widths[step]
            )]))
        }
        groups.append((0.20, []))
        // 0.206 from (0.3552, 0.5236), and 1.86 * 0.180 tall.
        let bystander = detection(at: 0.24, cx: 0.5452, cy: 0.6030, height: 0.3348, width: 0.152)
        groups.append((0.24, [bystander]))

        let tracklets = TrackletLinker.link(frames(groups))

        XCTAssertEqual(tracklets.map(\.detections.count).sorted(), [1, 5])
        let athlete = tracklets.first { $0.detections.count == 5 }
        XCTAssertEqual(
            athlete?.detections.last?.time ?? 0, 0.16, accuracy: 1e-9,
            "the athlete's track must end at her last real detection"
        )
        let orphan = tracklets.first { $0.detections.count == 1 }
        XCTAssertEqual(
            orphan?.detections.first?.box.midX ?? 0, bystander.box.midX, accuracy: 1e-9,
            "the bystander must start his own tracklet"
        )

        // Each gate must reject him on its own, so neither can be removed
        // without this test noticing. With the distance gate opened wide
        // (speedMultiplier 40 puts the gate at 0.90) only the height ratio
        // can still refuse him.
        let heightOnly = TrackletLinker.link(frames(groups), speedMultiplier: 40.0)
        XCTAssertEqual(
            heightOnly.map(\.detections.count).sorted(), [1, 5],
            "1.86x the height must be refused even when the distance gate would admit him"
        )

        // And with the height gate opened wide, only distance can refuse him.
        let distanceOnly = TrackletLinker.link(frames(groups), maxHeightRatio: 3.0)
        XCTAssertEqual(
            distanceOnly.map(\.detections.count).sorted(), [1, 5],
            "0.206 away must be refused even when the height gate would admit him"
        )
    }

    // MARK: - Ambiguity

    func testTwoQualifyingDetectionsEndTheTrackRatherThanBeingGuessedBetween() {
        // The track's recent step is 0.0148, so its gate is 0.0591. Two
        // detections arrive inside it (0.0123 and 0.0313 away) and both are
        // inside the height ratio. There is no evidence identifying which one
        // is the same person, so the track must end rather than guess.
        let groups: [(TimeInterval, [PoseDetection])] = [
            (0.00, [detection(at: 0.00, cx: 0.4000, cy: 0.5000, height: 0.200, width: 0.090)]),
            (0.04, [detection(at: 0.04, cx: 0.4130, cy: 0.4930, height: 0.204, width: 0.078)]),
            (0.08, [
                detection(at: 0.08, cx: 0.4235, cy: 0.4865, height: 0.196, width: 0.100),
                detection(at: 0.08, cx: 0.4382, cy: 0.5115, height: 0.219, width: 0.070),
            ]),
        ]

        let cut = TrackletLinker.link(frames(groups))
        XCTAssertEqual(
            cut.map(\.detections.count).sorted(), [1, 1, 2],
            "the track must end at 2 detections and leave both claimants to start their own"
        )
        let ended = cut.first { $0.detections.count == 2 }
        XCTAssertEqual(
            ended?.detections.last?.time ?? 0, 0.04, accuracy: 1e-9,
            "the track must not take either of the ambiguous detections"
        )

        // With the cut disabled the old behaviour returns: nearest wins.
        let guessed = TrackletLinker.link(frames(groups), cutOnAmbiguity: false)
        XCTAssertEqual(guessed.map(\.detections.count).sorted(), [1, 3])
        let continued = guessed.first { $0.detections.count == 3 }
        XCTAssertEqual(
            continued?.detections.last?.box.midX ?? 0, 0.4235, accuracy: 1e-9,
            "without the cut, the nearer of the two is taken"
        )
    }

    func testNearestPassingDetectionWinsOverLargerOne() {
        // Two candidates both pass the gates; the nearer one must be taken
        // even though the other is bigger and more confident. The ambiguity
        // cut would otherwise end the track before the tie is resolved, so
        // this exercises the resolution rule with the cut off — the rule
        // still runs under the default when only one detection qualifies.
        let near = detection(at: 0.04, cx: 0.423, cy: 0.453, height: 0.213, width: 0.095)
        let far = detection(
            at: 0.04, cx: 0.448, cy: 0.489, height: 0.241, width: 0.075, confidence: 0.99
        )
        let groups: [(TimeInterval, [PoseDetection])] = [
            (0.00, [detection(at: 0.00, cx: 0.410, cy: 0.460, height: 0.220, width: 0.090)]),
            (0.04, [far, near]),
        ]
        let tracklets = TrackletLinker.link(frames(groups), cutOnAmbiguity: false)

        let longest = tracklets.max(by: { $0.detections.count < $1.detections.count })
        XCTAssertEqual(longest?.detections.count, 2)
        XCTAssertEqual(longest?.detections.last?.box.midX ?? 0, near.box.midX, accuracy: 1e-9)
    }

    // MARK: - Claim order

    func testHealthyTrackClaimsBeforeStaleTrackWithWiderGate() {
        // Track "stale" is seen for 5 frames near cx 0.20 moving 0.0121 per
        // sample — a base gate of 0.0483 — then misses 3 frames in a row,
        // widening its gate to 0.0483 * 2.5 = 0.1208. Track "healthy" starts
        // later near cx 0.40, moving 0.0202 per sample, and is seen every
        // frame: 0 misses, gate 0.0810.
        //
        // A single new detection then appears at cx 0.355: 0.1116 from stale
        // (inside its widened gate, well outside its base gate) and 0.0626
        // from healthy (inside its gate). Both tracks can reach it, but only
        // one detection exists.
        //
        // Ordering by raw history length would let "stale" (5 detections)
        // claim ahead of "healthy" (2 detections) purely because it has been
        // followed longer, even though it has not seen its subject in 3
        // frames and its gate is only wide because of that neglect. The
        // healthy track — which just saw its subject last frame — must claim
        // the contended detection instead.
        var groups: [(TimeInterval, [PoseDetection])] = []
        let staleWidths = [0.082, 0.095, 0.074, 0.088, 0.101]
        for step in 0..<5 {
            let t = Double(step) * 0.04
            groups.append((t, [detection(
                at: t,
                cx: 0.2000 + Double(step) * 0.011,
                cy: 0.5000 - Double(step) * 0.005,
                height: 0.220 + Double(step) * 0.002,
                width: staleWidths[step]
            )]))
        }
        groups.append((0.20, [])) // stale miss 1
        // healthy starts; stale miss 2
        groups.append((0.24, [detection(
            at: 0.24, cx: 0.4000, cy: 0.4700, height: 0.205, width: 0.093
        )]))
        // healthy continues; stale miss 3
        groups.append((0.28, [detection(
            at: 0.28, cx: 0.4170, cy: 0.4590, height: 0.208, width: 0.079
        )]))
        let contended = detection(at: 0.32, cx: 0.3550, cy: 0.4680, height: 0.215, width: 0.106)
        groups.append((0.32, [contended]))

        let tracklets = TrackletLinker.link(frames(groups))

        XCTAssertEqual(tracklets.count, 2)
        XCTAssertEqual(tracklets.map(\.detections.count).sorted(), [3, 5])
        let winner = tracklets.first(where: { $0.detections.count == 3 })
        XCTAssertEqual(
            winner?.detections.last?.box.midX ?? 0, contended.box.midX, accuracy: 1e-9,
            "the healthy track (fewer misses) should claim the contended detection"
        )
    }
}
