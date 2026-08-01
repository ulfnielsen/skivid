import SwiftUI

/// `ComparisonModel.status` rendered as a pill that floats over the video.
///
/// The rows that used to display the status are deleted, and reclaiming
/// vertical space is the point of this redesign — a line that is only
/// intermittently interesting is the last thing to spend a permanent row on.
/// So it costs no row: `ComparisonView` hangs it on the video, top-trailing,
/// because the top edge is the only part of the video with nothing else in it
/// (the iOS close button is top-*leading* and 68pt wide).
///
/// **A constant 340pt wide, never sized to its text, and that is the whole
/// reason this is its own view.** It was originally unbounded and
/// bottom-trailing, on the reasoning that the pane filenames are
/// bottom-*leading* and so could not collide. Measured on an 834pt portrait
/// iPad, that was wrong: the chip laid out 446pt wide against a 415pt pane,
/// overran the divider and covered the left pane's filename. It is not
/// hit-testable, so nothing failed — the chip simply sat on top of the name.
///
/// A `maxWidth` frame is greedy up to its maximum, so the pill is a constant
/// 340pt (320 + 2×10 of padding) regardless of the sentence in it. That
/// constant is what makes "it cannot reach the other pane" checkable at all,
/// and it stops the chip flickering wider and narrower beside the video on
/// every status change. `ComparisonStatusChipTests` measures it against the
/// longest sentence the model can actually produce.
///
/// `allowsHitTesting(false)` is load-bearing rather than defensive: with the
/// chip hit-testable, synthetic clicks on the control underneath it fired zero
/// times.
struct ComparisonStatusChip: View {
    let status: String

    var body: some View {
        Text(status)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: 320)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .allowsHitTesting(false)
            .accessibilityLabel("Status: \(status)")
    }
}
