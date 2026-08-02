import CoreGraphics
import Foundation

/// One detected person in one frame.
///
/// All coordinates are normalised to the frame with the origin at the
/// **top-left** and y increasing downward. Vision reports a bottom-left
/// origin; `PoseDetector` performs that conversion once so nothing
/// downstream has to remember which convention it is in.
public struct PoseDetection {
    public let time: TimeInterval
    /// Axis-aligned hull of the detected joints.
    public let box: CGRect
    /// Joint name (Vision's `rawValue`) to normalised position.
    public let joints: [String: CGPoint]
    public let averageConfidence: Double

    public init(
        time: TimeInterval,
        box: CGRect,
        joints: [String: CGPoint],
        averageConfidence: Double
    ) {
        self.time = time
        self.box = box
        self.joints = joints
        self.averageConfidence = averageConfidence
    }

    public var centre: CGPoint { CGPoint(x: box.midX, y: box.midY) }
    public var height: Double { Double(box.height) }
}

/// Every person detected in one sampled frame.
public struct FrameDetections {
    public let time: TimeInterval
    public let poses: [PoseDetection]

    public init(time: TimeInterval, poses: [PoseDetection]) {
        self.time = time
        self.poses = poses
    }
}
