import CoreGraphics
import Foundation

/// Decides, for one instant, whether the two clips should be drawn spatially
/// aligned — and if so, by how much.
///
/// An `AlignmentTrack` stores what was *measured*, ungated and uneased. This is
/// where it becomes a judgement, and it is deliberately the only place: the
/// live overlay and the exporter both come through here, so they cannot drift
/// apart, and a threshold can be changed without recomputing a single track.
///
/// The rules below are not arbitrary. Each one comes from
/// `docs/superpowers/specs/2026-08-02-phase-c-alignment-findings.md`, a sweep of
/// C0094 (run start 18.56 s) against C0092 (4.40 s) at equal *run phase*, t from
/// 0 to 17 s in 0.5 s steps. That sweep found:
///
/// | window        | overlap     | vs identity            |
/// |---------------|-------------|------------------------|
/// | t = 0.0 – 4.0 | 0.82 – 0.92 | beats it by 4 – 8      |
/// | t = 4.5 – 7.5 | 0.23 – 0.49 | **worse than identity**|
/// | t = 8.0 –13.0 | 0.68 – 0.83 | beats it by 3 – 6      |
/// | t = 13.5–17.0 | 0.09 – 0.60 | worse                  |
///
/// The key reading: low overlap does **not** mean the registration is wrong. At
/// t = 5.0 the recovered translation is large but correct — inside the small
/// rectangle where the frames still meet, the terrain cancels cleanly. The
/// cameras are simply looking at different parts of the hill, so matching them
/// costs most of the frame. Overlap is therefore a health signal for *shared
/// view*, and it is already computed by the registration pass for free.
public enum AlignmentGate {
    /// The eased, gated translation to apply to the right clip at `time`
    /// (seconds after the run start, common to both clips), or `nil` for
    /// identity — draw the clips unaligned.
    ///
    /// - Parameters:
    ///   - track: raw, ungated samples in ascending `time` order.
    ///   - time: seconds after the run start.
    ///   - engageAbove: overlap that turns alignment **on**. Measured: the good
    ///     windows sit at 0.68 and above.
    ///   - disengageBelow: overlap that turns alignment **off**. Measured: the
    ///     bad windows sit at 0.49 and below.
    ///   - easeSeconds: how long the translation takes to shrink to identity
    ///     after a disengage.
    ///
    /// ## Why two thresholds and not one
    ///
    /// Do not "simplify" these into a single number. The measured good windows
    /// are at overlap ≥ 0.68 and the bad ones at ≤ 0.49; everything in the
    /// 0.55 – 0.68 band is a judgement the data does not settle. With one
    /// threshold, a signal wandering across it toggles alignment on and off
    /// sample by sample, and the operator sees the frame jitter. With two, the
    /// band holds whatever state it is already in — the state only changes on
    /// evidence strong enough to have been seen in the measurement.
    /// `testASignalOscillatingBetweenTheThresholdsDoesNotFlap` fails for any
    /// single-threshold implementation, in both directions.
    ///
    /// ## Why it never latches
    ///
    /// The lab's `OverlayClipWriter` stops aligning for the remainder of the
    /// clip after three consecutive failures, on the premise that divergence is
    /// monotonic. The measurement disproves that premise: it was an artefact of
    /// comparing equal *elapsed* time on a pair whose runs start 14 s apart. At
    /// equal run phase the recovery at t = 8 is real and holds for five seconds.
    /// A latch would throw that window away, so this walks the whole track and
    /// re-engages whenever overlap earns it.
    ///
    /// ## Why the fallback is identity, not the last good warp
    ///
    /// Holding a stale translation through a low-overlap stretch is what puts
    /// one clip in the corner of the frame — visible at t = 5.0, where the
    /// recovered translation is large and the floating frame ends up in the
    /// top-left. Unaligned is honest; a large stale translation is not. So a
    /// disengage eases the *last engaged* translation down to zero over
    /// `easeSeconds` (a hard cut is a visible jump, and the boundary is crossed
    /// several times in 17 s) and then returns `nil`.
    public static func translation(
        in track: AlignmentTrack,
        at time: TimeInterval,
        engageAbove: Double = 0.68,
        disengageBelow: Double = 0.55,
        easeSeconds: Double = 0.25
    ) -> CGVector? {
        let samples = track.samples
        guard let first = samples.first, let last = samples.last else { return nil }

        // Nothing was measured outside the sampled span. Before it there is no
        // state yet; past it, holding the last translation indefinitely is
        // exactly the stale-warp failure above, so both ends are identity.
        guard time >= first.time, time <= last.time else { return nil }

        let states = engagementStates(
            of: samples, engageAbove: engageAbove, disengageBelow: disengageBelow
        )

        // Bracket `time`. Landing exactly on a sample collapses the bracket, so
        // that sample's own state decides — which is what makes the instant of
        // a disengage the start of the ease rather than the end of the run.
        guard let high = samples.firstIndex(where: { $0.time >= time }) else { return nil }
        let low = samples[high].time == time ? high : high - 1

        if states[low].engaged && states[high].engaged {
            // Inside an engaged run: interpolate linearly, so playback gets a
            // continuous translation between samples rather than a staircase.
            return interpolate(from: samples[low], to: samples[high], at: time)
        }

        if states[low].engaged {
            // Engaged at `low`, disengaged at `high`: the run ends at
            // `samples[high].time`. Interpolating into `high` would blend in a
            // translation that was measured *not* to be trustworthy, so hold
            // the last engaged one. It meets the ease at the boundary, where
            // the ease still has its full weight, so there is no jump.
            return samples[low].translation
        }

        // Disengaged. Either we are inside the ease that follows the most
        // recent disengage, or we are at identity.
        guard let disengage = states[low].lastDisengage else { return nil }
        let elapsed = time - disengage.time
        guard easeSeconds > 0 else { return nil }
        let remaining = 1 - elapsed / easeSeconds
        guard remaining > 0, remaining <= 1 else { return nil }
        return CGVector(
            dx: disengage.translation.dx * remaining,
            dy: disengage.translation.dy * remaining
        )
    }

    /// What the gate had decided by the time it reached each sample.
    private struct Engagement {
        var engaged: Bool
        /// The most recent disengage at or before this sample: when it
        /// happened, and the translation the ease starts from.
        var lastDisengage: (time: TimeInterval, translation: CGVector)?
    }

    /// Walks the samples in order, carrying the engaged/disengaged state.
    ///
    /// This is the hysteresis. Engaged becomes disengaged only on a sample
    /// strictly *below* `disengageBelow`; disengaged becomes engaged only on
    /// one strictly *above* `engageAbove`. A sample in the band between them
    /// changes nothing.
    ///
    /// The walk always starts from the beginning of the track rather than from
    /// the query point, because the state at any instant is the whole history
    /// of the signal up to it — that is what a hysteretic gate means.
    private static func engagementStates(
        of samples: [AlignmentSample],
        engageAbove: Double,
        disengageBelow: Double
    ) -> [Engagement] {
        // The track begins unaligned: nothing has yet earned a warp.
        var state = Engagement(engaged: false, lastDisengage: nil)
        var states: [Engagement] = []
        states.reserveCapacity(samples.count)

        for (index, sample) in samples.enumerated() {
            if state.engaged {
                if sample.overlap < disengageBelow {
                    state.engaged = false
                    // The ease starts from the last translation that was
                    // actually trusted — the previous sample's, not this one's.
                    // `index > 0` holds because engaging requires an earlier
                    // sample to have engaged us.
                    state.lastDisengage = (sample.time, samples[index - 1].translation)
                }
            } else if sample.overlap > engageAbove {
                state.engaged = true
            }
            states.append(state)
        }
        return states
    }

    private static func interpolate(
        from low: AlignmentSample,
        to high: AlignmentSample,
        at time: TimeInterval
    ) -> CGVector {
        let span = high.time - low.time
        guard span > 0 else { return low.translation }
        let fraction = (time - low.time) / span
        return CGVector(
            dx: low.translation.dx + (high.translation.dx - low.translation.dx) * fraction,
            dy: low.translation.dy + (high.translation.dy - low.translation.dy) * fraction
        )
    }
}
