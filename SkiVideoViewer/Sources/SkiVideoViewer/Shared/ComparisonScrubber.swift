import SkiVideoCore
import SwiftUI

/// Which clip's clock the scrubber and the control bar's time label read.
///
/// Shared by both so they cannot disagree: a timeline showing the right clip
/// above a readout showing the left one is worse than either alone. `.both`
/// resolves to `.left` because while synced the pair is locked, so either
/// side's playhead names the pair's position — and `ComparisonModel.scrub`
/// carries the other clip along by the offset between the two sync points.
extension ComparisonTarget {
    var scrubbedSide: ComparisonSide {
        self == .right ? .right : .left
    }
}

/// The timeline for whatever the control bar is targeting.
///
/// There is one scrubber where there used to be two, and no target needs a
/// special case here: `ComparisonModel.scrub(_:to:)` reads `target` itself and
/// decides what a drag means. While aligning it is a plain per-side seek; with
/// `both` it moves the locked pair, keeping the sync offset; with one side
/// targeted it *corrects* that clip against the other, leaving the other where
/// it is, which is the frame-level adjustment a run start needs and the 1s/5s
/// arrows cannot give.
///
/// The decision has to be made in the model, from `target`, because what this
/// view passes is `scrubbedSide` — which collapses `.both` to `.left` so the
/// bar and the time label read one clock, and therefore cannot express the
/// difference. Verified by reading the model, not assumed.
struct ComparisonScrubber: View {
    @ObservedObject var model: ComparisonModel

    private var side: ComparisonSide { model.target.scrubbedSide }

    var body: some View {
        TimelineScrubber(
            time: side == .left ? model.leftTime : model.rightTime,
            duration: side == .left ? model.leftDuration : model.rightDuration,
            onScrub: { model.scrub(side, to: $0) }
        )
    }
}
