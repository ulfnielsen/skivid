import CoreGraphics
import Foundation
import Vision

/// Detects human body poses frame by frame.
///
/// Measured at ~11 ms per frame at 320 px wide, which is what makes a
/// 25 fps pass over a 45 s clip practical. This is the only place Vision's
/// bottom-left coordinate origin appears; `PoseDetection` is top-left
/// throughout.
public enum PoseDetector {
    /// Runs body-pose detection on each frame, preserving input order.
    /// A frame whose request throws contributes an empty `poses` array
    /// rather than being dropped, so sample times stay aligned with the
    /// caller's frame list.
    public static func detections(
        in frames: [(image: CGImage, time: TimeInterval)]
    ) -> [FrameDetections] {
        frames.map { frame in
            FrameDetections(time: frame.time, poses: poses(in: frame.image, at: frame.time))
        }
    }

    private static func poses(in image: CGImage, at time: TimeInterval) -> [PoseDetection] {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let observations = request.results else { return [] }

        return observations.compactMap { observation -> PoseDetection? in
            guard let recognised = try? observation.recognizedPoints(.all) else { return nil }

            var joints: [String: CGPoint] = [:]
            var confidenceSum = 0.0
            for (name, point) in recognised where point.confidence > 0.1 {
                // Vision: origin bottom-left, y up. Ours: origin top-left, y down.
                joints[name.rawValue.rawValue] = CGPoint(x: point.location.x, y: 1.0 - point.location.y)
                confidenceSum += Double(point.confidence)
            }
            guard joints.count >= 4 else { return nil }

            let xs = joints.values.map(\.x)
            let ys = joints.values.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max()
            else { return nil }

            return PoseDetection(
                time: time,
                box: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                joints: joints,
                averageConfidence: confidenceSum / Double(joints.count)
            )
        }
    }
}
