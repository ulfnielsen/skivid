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
    /// Keep at least three quarters of the picture.
    ///
    /// Named rather than written into the signature because it encodes a
    /// decision — what fraction of the frame it is worth throwing away to
    /// bring the clips together — and a decision that is only a literal in a
    /// default argument cannot be asserted, only re-typed.
    public static let defaultEngageAbove = 0.75

    /// Below this the crop costs more than the alignment is worth.
    public static let defaultDisengageBelow = 0.65

    /// The eased, gated translation to apply to the right clip at `time`
    /// (seconds after the run start, common to both clips), or `nil` for
    /// identity — draw the clips unaligned.
    ///
    /// - Parameters:
    ///   - track: raw, ungated samples in ascending `time` order.
    ///   - time: seconds after the run start.
    ///   - engageAbove: overlap that turns alignment **on** — "keep at least
    ///     three quarters of the picture". See "what the thresholds cost"
    ///     below for why this is 0.75 and not the measured 0.68.
    ///   - disengageBelow: overlap that turns alignment **off** — below this
    ///     the crop costs more than the alignment is worth. Measured: the bad
    ///     windows sit at 0.49 and below, so there is still clear air under it.
    ///   - easeSeconds: how long the translation takes to shrink to identity
    ///     after a disengage.
    ///   - overlapWindow: how many samples the median filter spans before the
    ///     overlap is compared against the thresholds. 5 samples is 0.2 s at the
    ///     pass's 25 Hz. Pass 1 to gate on the raw overlap.
    ///
    /// ## What the thresholds cost, now that the overlay crops
    ///
    /// `OverlayPlayerStack` masks both clips to the region they share. For a
    /// pure translation that region is the frame inset by `|dx|` and `|dy|`,
    /// so **overlap is exactly the fraction of picture that survives the
    /// crop** — the same number, no longer an abstract quality score. Engaging
    /// at the measured 0.68 therefore means visibly discarding nearly a third
    /// of the frame, which is a decision the operator can now see rather than
    /// one hidden in a registration statistic.
    ///
    /// So the defaults are tightened to 0.75 / 0.65: keep at least three
    /// quarters of the picture, and give up below two thirds. The band is
    /// narrower than 0.68 / 0.55 and deliberately still a band — see below.
    ///
    /// **Measured cost of the tightening**, on both 425-sample tracks at the
    /// shipped 25 Hz / 320 px parameters, counting the sample times at which
    /// this function returns a translation:
    ///
    /// | pair          | 0.68 / 0.55 | 0.75 / 0.65 | lost      |
    /// |---------------|-------------|-------------|-----------|
    /// | C0084 + C0094 | 0.675       | 0.619       | 5.6 pp    |
    /// | C0094 + C0092 | 0.626       | 0.593       | 3.3 pp    |
    ///
    /// So the pair is drawn aligned for three to six percent less of the run.
    /// What goes is the opening of the second good window — which the findings
    /// already recorded as sitting at overlap 0.668 – 0.679, right on the old
    /// threshold — and the brief re-engagements in the tail. Those are exactly
    /// the samples that were keeping the least picture, which is the trade.
    ///
    /// ## Why two thresholds and not one
    ///
    /// Do not "simplify" these into a single number. The measured good windows
    /// are at overlap ≥ 0.68 and the bad ones at ≤ 0.49; everything between is
    /// a judgement the data does not settle. With one
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
    ///
    /// ## Why the overlap is median-filtered before it is gated
    ///
    /// The findings sampled a 0.5 s grid. Run at the pass's real 25 Hz, the
    /// "bad" stretch t = 4.5 – 7.5 turns out not to be a clean step: registration
    /// flips between two solutions on adjacent frames — a small shift
    /// (dy ≈ −0.04, overlap ≈ 0.79, residual 3.5 against identity 9.8) and a
    /// large one (dy ≈ −0.42, overlap ≈ 0.23). Samples 4.44 – 4.68 take the
    /// large solution, 4.72 – 4.92 come back to the small one and register well,
    /// and only 4.96 onward is genuinely bad. The original sweep happened to
    /// land on 4.50 and 5.00, both large-shift frames, which is why it read as a
    /// step.
    ///
    /// So the boundary is a **flicker, not a transition**, and hysteresis cannot
    /// help: the flicker is in the raw overlap and swings clear across the band,
    /// well below `disengageBelow`. Ungated, alignment would switch on and off
    /// within 0.3 s around t ≈ 4.7 and again near t ≈ 14 — a clip twitching in
    /// and out of position, with only the 0.25 s ease to soften it.
    ///
    /// A median over a small odd window suppresses isolated flips while leaving
    /// a genuine multi-second transition intact. **Median and not mean**: the
    /// mean of 0.79 and 0.23 lands mid-band, in the hysteresis gap, doing
    /// nothing useful, whereas the median just picks whichever of the two
    /// solutions the neighbourhood actually favours. The filter never invents a
    /// value that was not measured.
    ///
    /// Only the overlap used for the **decision** is filtered. The translation
    /// returned is always the measured one — the decision is what is noisy here,
    /// not the geometry.
    ///
    /// ## Known: the second good window now starts later
    ///
    /// The findings' second window opens at overlap 0.668 – 0.679, which was
    /// already sitting on the old 0.68 engage threshold and is now clearly
    /// under the new one. On C0094 + C0092 that window starts at 8.68 s
    /// instead of 8.12 s. This is not a defect to tune away: those samples are
    /// exactly the ones where a third of the frame would be cropped, and the
    /// point of the change is to refuse them.
    ///
    /// Thresholds stay parameters. The track stores raw samples precisely so
    /// one can be changed without recomputing anything.
    public static func translation(
        in track: AlignmentTrack,
        at time: TimeInterval,
        engageAbove: Double = AlignmentGate.defaultEngageAbove,
        disengageBelow: Double = AlignmentGate.defaultDisengageBelow,
        easeSeconds: Double = 0.25,
        overlapWindow: Int = 5
    ) -> CGVector? {
        let samples = track.samples
        guard let first = samples.first, let last = samples.last else { return nil }

        // Nothing was measured outside the sampled span. Before it there is no
        // state yet; past it, holding the last translation indefinitely is
        // exactly the stale-warp failure above, so both ends are identity.
        guard time >= first.time, time <= last.time else { return nil }

        let decisionOverlaps = medianFilteredOverlaps(of: samples, window: overlapWindow)
        let states = engagementStates(
            of: samples, using: decisionOverlaps,
            engageAbove: engageAbove, disengageBelow: disengageBelow
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

    /// The overlap series the gate makes its decisions on: a centred median of
    /// each sample's neighbourhood.
    ///
    /// The window is **clamped** at the track's edges rather than padded or
    /// wrapped, so early and late samples are filtered over whatever
    /// neighbourhood exists. A window of 1 (or 0) is the identity, which is what
    /// makes the filter opt-out. An even window is rounded up to the next odd
    /// one, since a centred median has no meaning otherwise.
    ///
    /// The median is taken as the upper-middle element of the sorted
    /// neighbourhood, never an average of two — an average could produce an
    /// overlap that no frame pair actually measured, which is the very thing
    /// median-over-mean was chosen to avoid.
    private static func medianFilteredOverlaps(
        of samples: [AlignmentSample],
        window: Int
    ) -> [Double] {
        let half = max(0, window) / 2
        guard half > 0 else { return samples.map(\.overlap) }

        var filtered: [Double] = []
        filtered.reserveCapacity(samples.count)
        for index in samples.indices {
            let low = max(0, index - half)
            let high = min(samples.count - 1, index + half)
            let neighbourhood = samples[low...high].map(\.overlap).sorted()
            filtered.append(neighbourhood[neighbourhood.count / 2])
        }
        return filtered
    }

    /// Walks the samples in order, carrying the engaged/disengaged state.
    ///
    /// This is the hysteresis. Engaged becomes disengaged only on a sample
    /// whose *decision* overlap is strictly **below** `disengageBelow`;
    /// disengaged becomes engaged only on one strictly **above** `engageAbove`.
    /// A sample in the band between them changes nothing.
    ///
    /// `overlaps` is the median-filtered series, parallel to `samples`. The
    /// samples themselves are still the source of every translation returned;
    /// only the decision reads the filtered value.
    ///
    /// The walk always starts from the beginning of the track rather than from
    /// the query point, because the state at any instant is the whole history
    /// of the signal up to it — that is what a hysteretic gate means.
    private static func engagementStates(
        of samples: [AlignmentSample],
        using overlaps: [Double],
        engageAbove: Double,
        disengageBelow: Double
    ) -> [Engagement] {
        // The track begins unaligned: nothing has yet earned a warp.
        var state = Engagement(engaged: false, lastDisengage: nil)
        var states: [Engagement] = []
        states.reserveCapacity(samples.count)

        for (index, sample) in samples.enumerated() {
            let overlap = overlaps[index]
            if state.engaged {
                if overlap < disengageBelow {
                    state.engaged = false
                    // The ease starts from the last translation that was
                    // actually trusted — the previous sample's, not this one's.
                    // `index > 0` holds because engaging requires an earlier
                    // sample to have engaged us.
                    state.lastDisengage = (sample.time, samples[index - 1].translation)
                }
            } else if overlap > engageAbove {
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
