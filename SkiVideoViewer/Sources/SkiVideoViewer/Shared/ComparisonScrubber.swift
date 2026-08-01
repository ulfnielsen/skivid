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

    @State private var scrubTime = 0.0
    @State private var isScrubbing = false

    private var side: ComparisonSide {
        model.target.scrubbedSide
    }

    private var duration: Double {
        side == .left ? model.leftDuration : model.rightDuration
    }

    /// The model's playhead, which stops being the truth mid-drag: the periodic
    /// time observer lags the thumb, so following it while scrubbing makes the
    /// thumb fight the finger.
    private var playheadTime: Double {
        side == .left ? model.leftTime : model.rightTime
    }

    private var displayedTime: Double {
        isScrubbing ? scrubTime : playheadTime
    }

    var body: some View {
        Slider(
            value: Binding(
                get: { min(max(displayedTime, 0), max(duration, 0.0001)) },
                set: { newValue in
                    scrubTime = newValue
                    // Seek live rather than on release. Aligning two clips
                    // means finding the same frame in each, which cannot be
                    // done without watching the frames go by; this is also what
                    // the two per-side scrubbers being replaced did. `scrub`
                    // calls `cancelPendingSeeks` first, so a drag coalesces
                    // instead of queueing a seek per pixel.
                    model.scrub(side, to: newValue)
                }
            ),
            in: 0...max(duration, 0.0001),
            onEditingChanged: { editing in
                // Seed from the playhead *before* `isScrubbing` flips: the flag
                // changes on drag-start, ahead of the first `set`, and an
                // unseeded `scrubTime` would snap the thumb back to wherever
                // the previous drag ended for that one frame.
                if editing { scrubTime = playheadTime }
                isScrubbing = editing
                // The last `set` already seeked here; repeating it on release
                // makes the final position durable even if that setter was
                // coalesced away.
                if !editing { model.scrub(side, to: scrubTime) }
            }
        )
        .disabled(duration <= 0)
        // Reserves a 44pt row, matching the control bar's. It does not make the
        // slider 44pt: measured, a `Slider` draws over 16pt on macOS whether
        // framed at `height: 44` or left unframed — the frame centres it rather
        // than growing it — and it hit-tests over its own extent.
        //
        // `contentShape(Rectangle())` was tried here and removed. On the
        // equivalent segmented control, synthetic clicks selected over the same
        // band with it, without it, and with no frame at all: a parent's
        // content shape defines *that view's* hit region and cannot route hits
        // into a child control. Its only measurable effect was swallowing
        // clicks in the surrounding band, which would silently eat taps meant
        // for whatever Task 3 composes behind the scrubber. Do not re-add it.
        .frame(height: 44)
        .accessibilityLabel("Timeline")
        .accessibilityValue(ComparisonModel.timecode(displayedTime))
    }
}
