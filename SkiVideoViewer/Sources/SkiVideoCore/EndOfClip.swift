import AVFoundation

/// "Is the playhead at the end of this clip?", in one place, for the four
/// routes that start playback from a stopped state.
///
/// **Why it has to be asked at all.** `AVPlayer` will not play from the end.
/// Nothing in this module observed `AVPlayerItemDidPlayToEndTime` or set
/// `actionAtItemEnd`, so a clip that had run out was a dead end: Space, the
/// transport's play/pause button and the tortoise button all did nothing. The
/// operator reported it as the app going dead — and reported it as a *focus*
/// bug, because it happened to bite just after they had used the zoom chip.
///
/// **What "does nothing" actually looks like, measured** on generated H.264
/// (160×90, 30fps, 2s), playhead parked at the end by letting the clip run out:
///
/// | | playhead after | `rate` after |
/// | ------------------------------- | ---------- | ---- |
/// | `playImmediately(atRate: 1)`    | +0.000125s | 0    |
/// | `playImmediately(atRate: 0.25)` | +0.000024s | 0    |
/// | `seek(.zero)` then `play…(1)`   | plays      | 1    |
///
/// Note the middle column rather than the right one: `rate` *is* assigned
/// synchronously by the call and only falls back to 0 a moment later, so a test
/// that asserts `rate > 0` right after the call passes even against the defect.
/// The playhead is the honest signal, and it is what the tests assert on.
///
/// The last row is the other half of the fix: an un-awaited `seek` followed by
/// `playImmediately` **in the same turn** reaches `rate == 1` — the rewind
/// needs no completion handler. `AVPlayer.setRate(_:time:atHostTime:)` is the
/// exception and is handled at its one call site; see `ComparisonModel.playSynced`.
extension AVPlayer {
    /// How close to the duration still counts as "at the end".
    ///
    /// **Bounded from below by what the app's own seeks can produce.** Every
    /// `CMTime` in this module is built at timescale 600, so a seek aimed at the
    /// duration quantises to the nearest 1/600 s. Measured: a seek to
    /// `duration − 0.001` on a 2.000s clip landed at 1.998333 — 1/600 s (0.00167)
    /// below the point asked for. A tolerance under that would miss a playhead
    /// the operator had put on the end with the scrubber.
    ///
    /// **Bounded from above by a frame.** 0.03s is less than one frame at both
    /// 30fps (0.0333) and 24fps (0.0417), so this can never rewind while a whole
    /// frame the operator could still watch remains.
    ///
    /// 0.03 sits ~18× above the quantisation floor and just under the frame
    /// ceiling. The asymmetry is deliberate in that ordering: being slightly too
    /// eager costs a restart the operator asked for anyway, while being slightly
    /// too shy reinstates the dead end this exists to remove.
    ///
    /// **The brief this came from predicted the opposite of what was measured.**
    /// It expected `currentTime` to land "a frame short of `duration`". It does
    /// not: across 2s/3s clips at 24, 25, 30 and 60fps a clip that runs out
    /// stops on the duration *exactly* (gap 0.000000), and the failed play
    /// attempt then nudges the head a fraction *past* it. Hence `>=` against
    /// `duration - tolerance` rather than a two-sided window — the overshoot has
    /// to compare as "at the end" too.
    static let endOfClipTolerance = 0.03

    /// `false` — never `true` — whenever the answer is not yet knowable.
    ///
    /// `duration` is indefinite, and reads back as NaN, until the item loads;
    /// every NaN comparison is `false`, so an unguarded `current >= duration - t`
    /// would silently answer "not at the end" for a reason that has nothing to
    /// do with the playhead. It is spelled out instead, because the same
    /// expression with the operands swapped would silently answer *"at the end"*
    /// and rewind every clip on its first frame.
    ///
    /// A zero-length item is excluded for the same reason: `0 >= 0 - 0.03` is
    /// true, which would make every play request rewind and none of them play.
    var isAtEndOfClip: Bool {
        guard let duration = currentItem?.duration.seconds, duration.isFinite, duration > 0 else {
            return false
        }
        let current = currentTime().seconds
        guard current.isFinite else { return false }
        return current >= duration - Self.endOfClipTolerance
    }
}
