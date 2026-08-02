import CoreGraphics
import Foundation

/// A distinct person offered to the operator as a possible subject.
public struct SubjectCandidate {
    public let id: Int
    public let trackletIDs: [Int]
    /// Every detection belonging to this candidate, ascending in time.
    public let detections: [PoseDetection]
    public let firstSeen: TimeInterval
    public let lastSeen: TimeInterval
    public let detectionCount: Int
    /// The clearest moment: most joints detected, ties broken by largest box.
    public let bestFrameTime: TimeInterval
    public let bestFrameBox: CGRect
    /// Largest box height as a fraction of frame height, over the whole life.
    public let peakHeightFraction: Double

    public init(
        id: Int,
        trackletIDs: [Int],
        detections: [PoseDetection],
        firstSeen: TimeInterval,
        lastSeen: TimeInterval,
        detectionCount: Int,
        bestFrameTime: TimeInterval,
        bestFrameBox: CGRect,
        peakHeightFraction: Double
    ) {
        self.id = id
        self.trackletIDs = trackletIDs
        self.detections = detections
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.detectionCount = detectionCount
        self.bestFrameTime = bestFrameTime
        self.bestFrameBox = bestFrameBox
        self.peakHeightFraction = peakHeightFraction
    }
}

/// Groups tracklets into distinct people.
///
/// Tracklets fragment when a skier passes behind an obstacle. The merge rule
/// here is deliberately conservative and **prefers to over-segment**: showing
/// the operator six thumbnails for four people costs one glance, whereas
/// fusing two athletes into one candidate produces a corrupt subject track
/// that looks entirely plausible. Two tracklets join only when they do not
/// overlap in time, the gap between them is short, and both position and
/// height remain compatible across it.
public enum SubjectCandidates {
    public static func candidates(
        from tracklets: [Tracklet],
        mergeGapSeconds: Double = 1.5,
        maxJumpFraction: Double = 0.21,
        jumpWidenPerMiss: Double = 0.031,
        maxHeightRatio: Double = 2.0
    ) -> [SubjectCandidate] {
        let usable = tracklets.filter { !$0.detections.isEmpty }
            .sorted { ($0.firstSeen, $0.id) < ($1.firstSeen, $1.id) }
        guard !usable.isEmpty else { return [] }

        // Groups of tracklet indices, each group one person. Greedy in time
        // order: each tracklet either extends the most recently ended
        // compatible group or starts its own.
        var groups: [[Int]] = []
        for (index, tracklet) in usable.enumerated() {
            var target: Int?
            var bestEnd = -Double.infinity
            for (groupIndex, group) in groups.enumerated() {
                guard let tail = group.last.map({ usable[$0] }) else { continue }
                guard canJoin(
                    tail, tracklet,
                    mergeGapSeconds: mergeGapSeconds,
                    maxJumpFraction: maxJumpFraction,
                    jumpWidenPerMiss: jumpWidenPerMiss,
                    maxHeightRatio: maxHeightRatio
                ) else { continue }
                if tail.lastSeen > bestEnd {
                    bestEnd = tail.lastSeen
                    target = groupIndex
                }
            }
            if let target {
                groups[target].append(index)
            } else {
                groups.append([index])
            }
        }

        let unnumbered = groups.map { group -> (ids: [Int], detections: [PoseDetection]) in
            let ids = group.map { usable[$0].id }.sorted()
            let detections = group.flatMap { usable[$0].detections }
                .sorted { $0.time < $1.time }
            return (ids, detections)
        }

        // Descending by how long the person is on screen. Presentation order
        // only — it makes no claim about who the subject is. The tracklet-id
        // tiebreak keeps numbering stable across runs and input orderings.
        let ordered = unnumbered.sorted {
            if $0.detections.count != $1.detections.count {
                return $0.detections.count > $1.detections.count
            }
            return ($0.ids.first ?? 0) < ($1.ids.first ?? 0)
        }

        return ordered.enumerated().map { position, entry in
            let best = entry.detections.max {
                ($0.joints.count, Double($0.box.height)) < ($1.joints.count, Double($1.box.height))
            }
            return SubjectCandidate(
                id: position + 1,
                trackletIDs: entry.ids,
                detections: entry.detections,
                firstSeen: entry.detections.first?.time ?? 0,
                lastSeen: entry.detections.last?.time ?? 0,
                detectionCount: entry.detections.count,
                bestFrameTime: best?.time ?? 0,
                bestFrameBox: best?.box ?? .zero,
                peakHeightFraction: entry.detections.map(\.height).max() ?? 0
            )
        }
    }

    private static func canJoin(
        _ earlier: Tracklet,
        _ later: Tracklet,
        mergeGapSeconds: Double,
        maxJumpFraction: Double,
        jumpWidenPerMiss: Double,
        maxHeightRatio: Double
    ) -> Bool {
        guard let tail = earlier.detections.last, let head = later.detections.first else {
            return false
        }
        // Overlapping in time means two people, not one interrupted person.
        guard later.firstSeen > earlier.lastSeen else { return false }

        let gap = later.firstSeen - earlier.lastSeen
        guard gap <= mergeGapSeconds else { return false }

        // Widen the jump gate across the gap on the same footing the linker
        // uses within a track: one miss per sample interval, approximated
        // from the earlier tracklet's own sample spacing. A single-detection
        // tracklet has no spacing to measure, so `sampleSpacing` returns 0,
        // `misses` stays 0, and the gate stays flat at `maxJumpFraction` —
        // deliberately, not accidentally: with no history to judge a typical
        // frame-to-frame jump, refusing to widen the gate is the
        // conservative (over-segmenting) choice this module is built on.
        let spacing = sampleSpacing(of: earlier)
        let misses = spacing > 0 ? gap / spacing : 0
        let gate = maxJumpFraction + jumpWidenPerMiss * misses

        let dx = Double(head.centre.x - tail.centre.x)
        let dy = Double(head.centre.y - tail.centre.y)
        guard (dx * dx + dy * dy).squareRoot() < gate else { return false }

        let ratio = head.height / max(tail.height, 1e-9)
        return max(ratio, 1.0 / max(ratio, 1e-9)) < maxHeightRatio
    }

    private static func sampleSpacing(of tracklet: Tracklet) -> Double {
        guard tracklet.detections.count > 1 else { return 0 }
        let gaps = zip(tracklet.detections, tracklet.detections.dropFirst())
            .map { $1.time - $0.time }
            .filter { $0 > 0 }
        guard !gaps.isEmpty else { return 0 }
        return gaps.sorted()[gaps.count / 2]
    }
}
