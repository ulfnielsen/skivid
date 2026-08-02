import CoreGraphics
import Foundation

/// The settings that produced an analysis, recorded so a later build can tell
/// a stored result apart from one it would produce now.
public struct AnalysisParameters: Codable, Equatable, Sendable {
    public let fps: Double
    public let detectionWidth: Double
    public let initialJump: Double
    public let speedMultiplier: Double
    public let maxHeightRatio: Double
    public let maxMisses: Int
    public let cutOnAmbiguity: Bool
    public let minSamples: Int

    public init(
        fps: Double, detectionWidth: Double, initialJump: Double,
        speedMultiplier: Double, maxHeightRatio: Double, maxMisses: Int,
        cutOnAmbiguity: Bool, minSamples: Int
    ) {
        self.fps = fps
        self.detectionWidth = detectionWidth
        self.initialJump = initialJump
        self.speedMultiplier = speedMultiplier
        self.maxHeightRatio = maxHeightRatio
        self.maxMisses = maxMisses
        self.cutOnAmbiguity = cutOnAmbiguity
        self.minSamples = minSamples
    }

    /// The values the app analyses with today.
    public static let current = AnalysisParameters(
        fps: 25, detectionWidth: 320, initialJump: 0.06, speedMultiplier: 4.0,
        maxHeightRatio: 1.15, maxMisses: 10, cutOnAmbiguity: true, minSamples: 8
    )

    public func matches(_ other: AnalysisParameters) -> Bool { self == other }
}

/// One moment of a segment, enough to redraw a thumbnail from the video
/// without caching an image next to the footage.
public struct SegmentPreview: Codable, Equatable, Sendable {
    public let time: TimeInterval
    public let box: CGRect

    public init(time: TimeInterval, box: CGRect) {
        self.time = time
        self.box = box
    }
}

/// A contiguous run of detections believed to be one person.
public struct AnalysedSegment: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let firstSeen: TimeInterval
    public let lastSeen: TimeInterval
    public let detectionCount: Int
    public let peakHeightFraction: Double
    public let previews: [SegmentPreview]

    public init(
        id: Int, firstSeen: TimeInterval, lastSeen: TimeInterval,
        detectionCount: Int, peakHeightFraction: Double, previews: [SegmentPreview]
    ) {
        self.id = id
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.detectionCount = detectionCount
        self.peakHeightFraction = peakHeightFraction
        self.previews = previews
    }

    /// Two segments overlapping in time cannot be the same person, so they can
    /// never both belong to one pick.
    public func overlaps(_ other: AnalysedSegment) -> Bool {
        firstSeen <= other.lastSeen && other.firstSeen <= lastSeen
    }
}

/// A run start as stored. Mirrors `SubjectRunStart.Outcome`, minus the cases
/// that mean "there is nothing to store".
public enum StoredRunStart: Codable, Equatable, Sendable {
    case started(time: TimeInterval, baseline: Double, threshold: Double)
    /// The subject was never demonstrably still, so their run began at or
    /// before this time. Not the same as a measured start, and the UI must not
    /// present it as one.
    case alreadyRunning(firstSeen: TimeInterval)

    /// The time to sync on, whichever case it is.
    public var syncTime: TimeInterval {
        switch self {
        case let .started(time, _, _): return time
        case let .alreadyRunning(firstSeen): return firstSeen
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, time, baseline, threshold, firstSeen
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An unrecognised kind throws rather than defaulting. A future version
        // may add one, and silently reading it as `started` at time zero would
        // apply a wrong sync point with nothing to indicate it.
        switch try container.decode(String.self, forKey: .kind) {
        case "started":
            self = .started(
                time: try container.decode(TimeInterval.self, forKey: .time),
                baseline: try container.decode(Double.self, forKey: .baseline),
                threshold: try container.decode(Double.self, forKey: .threshold)
            )
        case "alreadyRunning":
            self = .alreadyRunning(
                firstSeen: try container.decode(TimeInterval.self, forKey: .firstSeen)
            )
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "unrecognised run-start kind '\(other)'"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .started(time, baseline, threshold):
            try container.encode("started", forKey: .kind)
            try container.encode(time, forKey: .time)
            try container.encode(baseline, forKey: .baseline)
            try container.encode(threshold, forKey: .threshold)
        case let .alreadyRunning(firstSeen):
            try container.encode("alreadyRunning", forKey: .kind)
            try container.encode(firstSeen, forKey: .firstSeen)
        }
    }
}

/// The operator's answer: which segments are the athlete, and when they went.
public struct SubjectPick: Codable, Equatable, Sendable {
    public let segmentIDs: [Int]
    public let runStart: StoredRunStart

    public init(segmentIDs: [Int], runStart: StoredRunStart) {
        self.segmentIDs = segmentIDs
        self.runStart = runStart
    }
}

public struct ClipAnalysis: Codable, Equatable, Sendable {
    public let version: Int
    public let analysedAt: Date
    public let parameters: AnalysisParameters
    public let segments: [AnalysedSegment]
    public let subject: SubjectPick?

    public init(
        version: Int, analysedAt: Date, parameters: AnalysisParameters,
        segments: [AnalysedSegment], subject: SubjectPick?
    ) {
        self.version = version
        self.analysedAt = analysedAt
        self.parameters = parameters
        self.segments = segments
        self.subject = subject
    }

    /// Whether this was produced by settings other than the given ones.
    ///
    /// Staleness is reported, never acted on. A run start is a time and a time
    /// does not expire; the segment list is working data; and the pick is
    /// expensive human input. Recomputing silently would discard a decision the
    /// operator made in order to chase a number that was probably already right.
    public func isStale(against current: AnalysisParameters) -> Bool {
        !parameters.matches(current)
    }

    public func with(subject: SubjectPick?) -> ClipAnalysis {
        ClipAnalysis(
            version: version, analysedAt: analysedAt, parameters: parameters,
            segments: segments, subject: subject
        )
    }
}
