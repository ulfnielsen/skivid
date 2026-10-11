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

    /// What alignment is doing right now, when that is worth saying — in
    /// practice, that it has stepped aside for a stretch the pass measured as
    /// unalignable.
    ///
    /// Defaulted to nil so the layout tests keep measuring the pill they were
    /// written against, and so every other caller is unaffected.
    var alignmentNote: String?

    /// A **concatenated `Text`, not a `VStack` with an `if` in it** — and that
    /// is not a style choice, it is the measured way to add a second line here.
    ///
    /// The obvious version, `VStack { Text(status); if let note { Text(note) } }`,
    /// makes `ComparisonStatusChipTests` fail in a way that has nothing to do
    /// with what it measures: its `GeometryReader` probe stops reporting
    /// entirely and every frame reads `.zero`, at *every* call site including
    /// the ones passing no note. Bisected — a `VStack` with both `Text`s
    /// unconditional reports fine, and the same `VStack` with the `if` does not
    /// — so a structural conditional inside the view this chip is measured
    /// through is what breaks preference propagation out of the `.background`.
    /// Do not "tidy" this back into a stack.
    ///
    /// Two `Text`s unconditionally was the other candidate, and it costs 16pt
    /// of pill height for an empty second line whenever there is no note
    /// (measured: 41pt against 25pt). Concatenation costs nothing: an empty
    /// `Text` contributes no line.
    private var label: Text {
        Text(status)
            + Text(alignmentNote.map { "\n\($0)" } ?? "")
            // Dimmer than the status: an aside about why the picture looks the
            // way it does, not a report of what the operator's last action did.
            // `foregroundColor` rather than `foregroundStyle` because the
            // `Text`-returning overload of the latter is macOS 14, and this
            // package deploys to 13.
            .foregroundColor(.white.opacity(0.6))
    }

    var body: some View {
        label
            .font(.caption)
            .foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.center)
            // Two lines for the status, and two more for the note when there is
            // one. A value, not a branch in the view tree — see `label`.
            .lineLimit(alignmentNote == nil ? 2 : 4)
            .frame(maxWidth: 320)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .darkFrostedBacking(in: Capsule())
            .allowsHitTesting(false)
            .accessibilityLabel(
                alignmentNote.map { "Status: \(status). \($0)" } ?? "Status: \(status)"
            )
    }
}
