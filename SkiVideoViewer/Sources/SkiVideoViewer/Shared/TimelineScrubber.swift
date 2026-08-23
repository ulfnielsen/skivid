import SkiVideoCore
import SwiftUI

/// A clip timeline, shared by the comparison screen and the viewer.
///
/// Owns the mid-drag state both callers need: the model's playhead stops being
/// the truth while dragging, because the periodic time observer lags the thumb
/// and following it makes the thumb fight the finger.
struct TimelineScrubber: View {
    let time: Double
    let duration: Double
    let onScrub: (Double) -> Void

    @State private var scrubTime = 0.0
    @State private var isScrubbing = false

    private var displayedTime: Double {
        isScrubbing ? scrubTime : time
    }

    @Environment(\.isShortOnHeight) private var isShortOnHeight

    var body: some View {
        Slider(
            value: Binding(
                get: { min(max(displayedTime, 0), max(duration, 0.0001)) },
                set: { newValue in
                    scrubTime = newValue
                    // Seek live rather than on release. Finding a frame means
                    // watching the frames go by; the callers' scrub methods call
                    // `cancelPendingSeeks` first, so a drag coalesces instead of
                    // queueing a seek per pixel.
                    onScrub(newValue)
                }
            ),
            in: 0...max(duration, 0.0001),
            onEditingChanged: { editing in
                // Seed from the playhead *before* `isScrubbing` flips: the flag
                // changes on drag-start, ahead of the first `set`, and an
                // unseeded `scrubTime` would snap the thumb back to wherever the
                // previous drag ended for that one frame.
                if editing { scrubTime = time }
                isScrubbing = editing
                // The last `set` already seeked here; repeating it on release
                // makes the final position durable even if that setter was
                // coalesced away.
                if !editing { onScrub(scrubTime) }
            }
        )
        .disabled(duration <= 0)
        // Reserves a 44pt row, matching the control bars'. It does not make the
        // slider 44pt: measured, a `Slider` draws over 16pt on macOS whether
        // framed at `height: 44` or left unframed — the frame centres it rather
        // than growing it — and it hit-tests over its own extent.
        //
        // `contentShape(Rectangle())` was tried here and removed: a parent's
        // content shape cannot route hits into a child control, and its only
        // measurable effect was swallowing clicks meant for what sits behind.
        // Do not re-add it.
        // 44 is a comfortable touch row and, sideways on a phone, a twentieth
        // of the screen spent on a control the thumb is already resting on.
        .frame(height: isShortOnHeight ? 30 : 44)
        .accessibilityLabel("Timeline")
        .accessibilityValue(Timecode.string(displayedTime))
    }
}
