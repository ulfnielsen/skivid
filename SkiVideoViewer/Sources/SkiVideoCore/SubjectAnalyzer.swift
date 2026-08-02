import AVFoundation
import CoreGraphics
import Foundation

/// Turns a clip into a list of candidate segments, and a chosen set of those
/// segments into a run start.
///
/// Roughly 20s for a 45s clip on this machine, almost all of it Vision. That is
/// why it reports progress and honours cancellation: a job that long with no
/// escape is the wrong shape for a UI.
public enum SubjectAnalyzer {
    public enum AnalysisError: Error, CustomStringConvertible {
        case noFrames(String)
        case noPeopleFound(String)

        public var description: String {
            switch self {
            case let .noFrames(name): return "no frames could be read from \(name)"
            case let .noPeopleFound(name): return "no people were detected in \(name)"
            }
        }
    }

    /// Detects everyone in `clip` and groups them into segments.
    ///
    /// `progress` is called with 0...1 as frames are processed. Cancellation is
    /// checked between frames via `Task.checkCancellation()`, so the caller's
    /// Cancel takes effect within one frame rather than at the end.
    public static func analyse(
        clip: URL,
        parameters: AnalysisParameters = .current,
        previewCount: Int = 5,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> ClipAnalysis {
        let frames = try ClipFrameReader.frames(
            from: clip, fps: parameters.fps, targetWidth: parameters.detectionWidth
        )
        guard !frames.isEmpty else {
            throw AnalysisError.noFrames(clip.lastPathComponent)
        }

        var detections: [FrameDetections] = []
        detections.reserveCapacity(frames.count)
        for (index, frame) in frames.enumerated() {
            try Task.checkCancellation()
            detections.append(contentsOf: PoseDetector.detections(in: [frame]))
            progress(Double(index + 1) / Double(frames.count))
        }

        let tracklets = TrackletLinker.link(
            detections,
            initialJumpFraction: parameters.initialJump,
            speedMultiplier: parameters.speedMultiplier,
            maxHeightRatio: parameters.maxHeightRatio,
            maxMisses: parameters.maxMisses,
            cutOnAmbiguity: parameters.cutOnAmbiguity
        )
        // A zero merge gap means nothing is ever joined across a gap: a
        // candidate is one contiguous segment. Merging is what re-fused
        // different people after the linker had correctly separated them.
        let candidates = SubjectCandidates.candidates(from: tracklets, mergeGapSeconds: 0)
            .filter { $0.detectionCount >= parameters.minSamples }

        guard !candidates.isEmpty else {
            throw AnalysisError.noPeopleFound(clip.lastPathComponent)
        }

        return ClipAnalysis(
            version: 1,
            analysedAt: Date(),
            parameters: parameters,
            segments: candidates.map { segment(from: $0, previewCount: previewCount) },
            subject: nil
        )
    }

    /// The run start for a chosen set of segments, re-reading the clip.
    ///
    /// Re-reads rather than caching the frames from `analyse`: a 45s clip at
    /// 320px is ~1100 CGImages, which is not something to hold across a UI
    /// interaction of unbounded length.
    public static func runStart(
        clip: URL,
        analysis: ClipAnalysis,
        segmentIDs: [Int]
    ) async throws -> SubjectRunStart.Outcome {
        let frames = try ClipFrameReader.frames(
            from: clip,
            fps: analysis.parameters.fps,
            targetWidth: analysis.parameters.detectionWidth
        )
        guard !frames.isEmpty else {
            throw AnalysisError.noFrames(clip.lastPathComponent)
        }
        try Task.checkCancellation()

        let detections = PoseDetector.detections(in: frames)
        let tracklets = TrackletLinker.link(
            detections,
            initialJumpFraction: analysis.parameters.initialJump,
            speedMultiplier: analysis.parameters.speedMultiplier,
            maxHeightRatio: analysis.parameters.maxHeightRatio,
            maxMisses: analysis.parameters.maxMisses,
            cutOnAmbiguity: analysis.parameters.cutOnAmbiguity
        )
        let candidates = SubjectCandidates.candidates(from: tracklets, mergeGapSeconds: 0)
            .filter { $0.detectionCount >= analysis.parameters.minSamples }

        let wanted = Set(segmentIDs)
        let picked = candidates.filter { wanted.contains($0.id) }
        let merged = picked.flatMap(\.detections).sorted { $0.time < $1.time }
        guard let first = merged.first, let last = merged.last else {
            return .noSamples
        }

        let subject = SubjectCandidate(
            id: picked.first?.id ?? 0,
            trackletIDs: picked.flatMap(\.trackletIDs).sorted(),
            detections: merged,
            firstSeen: first.time,
            lastSeen: last.time,
            detectionCount: merged.count,
            bestFrameTime: picked.first?.bestFrameTime ?? first.time,
            bestFrameBox: picked.first?.bestFrameBox ?? first.box,
            peakHeightFraction: picked.map(\.peakHeightFraction).max() ?? 0
        )
        return SubjectRunStart.runStart(
            in: SubjectRunStart.profile(frames: frames, candidate: subject)
        )
    }

    /// `previewCount` moments spread evenly across the segment's life — not its
    /// clearest instant alone. One thumbnail cannot show that a track has
    /// changed person partway through, and rejecting such a track is exactly
    /// what the operator is there to do.
    private static func segment(
        from candidate: SubjectCandidate, previewCount: Int
    ) -> AnalysedSegment {
        let wanted = min(previewCount, candidate.detections.count)
        let previews = (0..<wanted).map { step -> SegmentPreview in
            let position = wanted == 1
                ? 0
                : Int((Double(step) / Double(wanted - 1))
                      * Double(candidate.detections.count - 1))
            let detection = candidate.detections[position]
            return SegmentPreview(time: detection.time, box: detection.box)
        }
        return AnalysedSegment(
            id: candidate.id,
            firstSeen: candidate.firstSeen,
            lastSeen: candidate.lastSeen,
            detectionCount: candidate.detectionCount,
            peakHeightFraction: candidate.peakHeightFraction,
            previews: previews
        )
    }
}
