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
/// There is one scrubber where there used to be two, and `.both` needs no
/// special case: `ComparisonModel.scrub(_:to:)` opens with
/// `guard isSynced else { … }` and, when synced, seeks *both* players — the
/// targeted one to the requested time and the other to that time plus the
/// sync-point offset. Verified by reading the model, not assumed.
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
