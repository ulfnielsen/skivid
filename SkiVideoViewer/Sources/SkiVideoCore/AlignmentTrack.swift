import CoreGraphics
import Foundation

/// The settings that produced an alignment track, recorded so a later build
/// can tell a stored track apart from one it would produce now. Mirrors
/// `AnalysisParameters`.
public struct AlignmentParameters: Codable, Equatable, Sendable {
    /// Samples per second along the run, common to both clips.
    public let sampleRate: Double
    /// The width frames were scaled to before registration.
    public let workingWidth: Double
    /// How far past the run start the pass went.
    public let durationSeconds: Double

    public init(sampleRate: Double, workingWidth: Double, durationSeconds: Double) {
        self.sampleRate = sampleRate
        self.workingWidth = workingWidth
        self.durationSeconds = durationSeconds
    }

    /// The values the app computes alignment with today.
    public static let current = AlignmentParameters(
        sampleRate: 25, workingWidth: 320, durationSeconds: 17
    )

    public func matches(_ other: AlignmentParameters) -> Bool { self == other }
}

/// One registered frame pair.
public struct AlignmentSample: Codable, Equatable, Sendable {
    /// Seconds after the run start, common to both clips.
    public let time: TimeInterval
    /// Applied to the right clip to bring it onto the left, in normalised
    /// frame widths so it survives a change of working resolution.
    public let translation: CGVector
    public let overlap: Double
    public let residual: Double
    /// What the residual would have been with no warp. Stored so "did
    /// alignment earn its place" stays answerable from the file.
    public let identityResidual: Double

    public init(
        time: TimeInterval, translation: CGVector,
        overlap: Double, residual: Double, identityResidual: Double
    ) {
        self.time = time
        self.translation = translation
        self.overlap = overlap
        self.residual = residual
        self.identityResidual = identityResidual
    }
}

/// How two clips align spatially, as measured once and stored beside them.
///
/// A track describes a *pair*: this comparison only means something for the
/// run starts it was computed against, so both are recorded and every load
/// checks them — see `isStale`.
public struct AlignmentTrack: Codable, Equatable, Sendable {
    public let version: Int
    public let computedAt: Date
    public let leftClip: String
    public let rightClip: String
    /// The run starts this was computed against. A track computed for
    /// different starts describes a different comparison and must not be used.
    public let leftStart: TimeInterval
    public let rightStart: TimeInterval
    public let parameters: AlignmentParameters
    public let samples: [AlignmentSample]

    public init(
        version: Int, computedAt: Date, leftClip: String, rightClip: String,
        leftStart: TimeInterval, rightStart: TimeInterval,
        parameters: AlignmentParameters, samples: [AlignmentSample]
    ) {
        self.version = version
        self.computedAt = computedAt
        self.leftClip = leftClip
        self.rightClip = rightClip
        self.leftStart = leftStart
        self.rightStart = rightStart
        self.parameters = parameters
        self.samples = samples
    }

    /// Whether this was computed against different run starts than the ones
    /// given.
    ///
    /// Compared within a tolerance rather than exactly: the starts round-trip
    /// through JSON and originate from a detector that reports to two
    /// decimals, so exact equality would call every reloaded track stale and
    /// re-run a 15-second registration pass on every open.
    ///
    /// As with `ClipAnalysis.isStale`, this is reported, not acted on — the
    /// samples are kept either way.
    public func isStale(leftStart: TimeInterval, rightStart: TimeInterval) -> Bool {
        let tolerance = 0.01
        return abs(self.leftStart - leftStart) > tolerance
            || abs(self.rightStart - rightStart) > tolerance
    }
}
