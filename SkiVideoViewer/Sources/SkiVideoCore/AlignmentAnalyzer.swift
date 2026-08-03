import CoreGraphics
import Foundation
import simd

/// Measures how two clips align, frame pair by frame pair, from the moment
/// each athlete's run starts.
///
/// This is the pass that fills an `AlignmentTrack`. It records what was
/// *measured* and nothing else — no threshold, no easing, no give-up rule.
/// Judgement lives in `AlignmentGate`, so a threshold can be revised without
/// re-running a pass that costs tens of seconds.
///
/// ## Why the run starts, and not elapsed time
///
/// The pair is read from `leftStart` and `rightStart` rather than from zero.
/// C0094's run begins at 18.56 s and C0092's at 4.40 s, so comparing equal
/// *elapsed* time compares two different parts of two different runs — which
/// is exactly what made the earlier "alignment decays monotonically" finding
/// an artefact of the sync error. Sample `n` of this track is the same instant
/// of each athlete's run. See
/// `docs/superpowers/specs/2026-08-02-phase-c-alignment-findings.md`.
public enum AlignmentAnalyzer {
    public enum AnalysisError: Error, CustomStringConvertible {
        case noFrames(String)

        public var description: String {
            switch self {
            case let .noFrames(name): return "no frames could be read from \(name)"
            }
        }
    }

    /// Registers `right` onto `left` at every sample of the run, returning the
    /// raw track.
    ///
    /// `progress` is called with 0...1 after each pair, and
    /// `Task.checkCancellation()` runs between pairs, so a Cancel takes effect
    /// within one registration rather than at the end of the pass.
    ///
    /// - Parameters:
    ///   - left: the reference clip. Its frames are not warped.
    ///   - right: the floating clip. The stored translation is what brings it
    ///     onto `left`.
    ///   - leftStart, rightStart: seconds into each clip at which that
    ///     athlete's run begins.
    public static func analyse(
        left: URL,
        right: URL,
        leftStart: TimeInterval,
        rightStart: TimeInterval,
        parameters: AlignmentParameters = .current,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> AlignmentTrack {
        try Task.checkCancellation()

        // The reference side is collected; the floating side is streamed past
        // it. Collecting both would double the peak for no gain — at the
        // 320px working width 17 s is ~425 frames, and only one side has to
        // be addressable by index for the pairing below.
        let reference = try ClipFrameReader.frames(
            from: left,
            fps: parameters.sampleRate,
            targetWidth: parameters.workingWidth,
            from: leftStart,
            to: leftStart + parameters.durationSeconds
        )
        guard !reference.isEmpty else {
            throw AnalysisError.noFrames(left.lastPathComponent)
        }
        try Task.checkCancellation()

        var samples: [AlignmentSample] = []
        samples.reserveCapacity(reference.count)

        // Paired by index, not by timestamp: both sides are read from their
        // own run start at the same rate, so pair `n` is the same phase of
        // each run. The recorded time is the reference clip's own offset from
        // its start, which is the grid the gate later interpolates on.
        try ClipFrameReader.forEachFrame(
            from: right,
            fps: parameters.sampleRate,
            targetWidth: parameters.workingWidth,
            from: rightStart,
            to: rightStart + parameters.durationSeconds
        ) { floating, _ in
            let index = samples.count
            guard index < reference.count else { return }
            try Task.checkCancellation()

            let frame = reference[index]
            samples.append(
                sample(
                    at: frame.time - leftStart,
                    reference: frame.image,
                    floating: floating
                )
            )
            progress(Double(samples.count) / Double(reference.count))
        }

        guard !samples.isEmpty else {
            throw AnalysisError.noFrames(right.lastPathComponent)
        }
        // The floating clip can run out first — C0092 is 26.4 s long against
        // C0094's 46.6 s — so the pass legitimately ends short of the
        // reference count. Close progress out rather than leaving it hanging
        // below 1 and looking stalled.
        progress(1)

        return AlignmentTrack(
            version: AlignmentTrack.currentVersion,
            computedAt: Date(),
            leftClip: left.lastPathComponent,
            rightClip: right.lastPathComponent,
            leftStart: leftStart,
            rightStart: rightStart,
            parameters: parameters,
            samples: samples
        )
    }

    /// One pair: register, then measure the result against doing nothing.
    ///
    /// A registration that throws still produces a sample — zero translation,
    /// zero overlap — so the gate reads it as disengaged. Dropping it instead
    /// would shorten the timeline silently and attribute every later sample to
    /// the wrong moment.
    private static func sample(
        at time: TimeInterval,
        reference: CGImage,
        floating: CGImage
    ) -> AlignmentSample {
        let identity = RegistrationResidual.measure(
            reference: reference, floating: floating,
            warp: RegistrationResidual.identityWarp
        )

        guard let result = try? FrameRegistration.register(
            reference: reference, floating: floating, method: .translational
        ) else {
            return AlignmentSample(
                time: time,
                translation: .zero,
                overlap: 0,
                residual: identity.meanAbsoluteDifference,
                identityResidual: identity.meanAbsoluteDifference
            )
        }

        // `FrameRegistration.warp` is *already* the transform to apply to the
        // floating image; it has done the inversion of Vision's raw output
        // internally. Inverting it again here was measured raising the
        // residual from 59.6 to 61.6 on a known (+40, +17) shift.
        let warp = result.warp
        let measured = RegistrationResidual.measure(
            reference: reference, floating: floating, warp: warp
        )

        // Normalised by the reference's own pixel width, so a track computed
        // at 320px means the same thing to a consumer drawing at 1920px. Both
        // components divide by *width*, not by width and height separately,
        // which keeps the vector's aspect true.
        //
        // **`dy` is negated, and that is not a sign slip to tidy away.** Vision
        // registers in a bottom-left origin with y increasing *upward*; this
        // project's convention — stated for every coordinate crossing a public
        // API, and already followed by `PoseDetection.box` — is top-left origin
        // with y increasing *downward*, which is also what a SwiftUI `.offset`
        // wants. Without the flip the vector is right in x and inverted in y,
        // so alignment pushes the two clips further apart by exactly the amount
        // it should have brought them together. Measured in the running app on
        // C0084 + C0094: at dy = 0 the shared banner sat ~100pt apart, and
        // applying dy = -0.0656 took it to ~205pt.
        let width = Double(reference.width)
        return AlignmentSample(
            time: time,
            translation: CGVector(
                dx: Double(warp.columns.2.x) / width,
                dy: -Double(warp.columns.2.y) / width
            ),
            overlap: measured.overlapFraction,
            residual: measured.meanAbsoluteDifference,
            identityResidual: identity.meanAbsoluteDifference
        )
    }
}
