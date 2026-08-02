import CoreGraphics
import SkiVideoCore
import SwiftUI

/// One analysed segment, as the operator judges it: a strip of five moments
/// from its life, its time range, and how many samples are behind it.
///
/// A **pure view** — values and one closure, no model. That is deliberate and
/// is what makes the tap gate testable. `SubjectPickModel.toggle` already
/// refuses an unselectable segment, so a sheet-level test cannot tell a card
/// that guards its tap from one that does not: both leave the selection
/// unchanged. Holding the gate here, as `.disabled(...)` on a real `Button`,
/// puts it somewhere a test can see it directly — `onTap` either fires or it
/// does not. See `SubjectPickWiringTests` for the measurement.
///
/// **The reason is shown, not just implied.** An unselectable card replaces
/// its sample count with `exclusionReason`. A control that does nothing and
/// says nothing reads as a bug; the sentence is what makes it read as a rule.
///
/// Selection is legible without colour: an accent border *and* a filled
/// checkmark, so the state survives greyscale and the accent colour being
/// something else.
struct SegmentCard: View {
    let segment: AnalysedSegment
    let isSelected: Bool
    /// Why this segment cannot be picked right now, or nil when it can be.
    /// Mirrors `SubjectPickModel.exclusionReason(for:)`, which is nil for an
    /// already-selected segment so a pick can always be undone.
    let exclusionReason: String?
    /// The composed preview strip, or nil while it is still being drawn.
    /// Rendering is the sheet's job, off the main thread — five frame seeks
    /// per card is not something to do inside `body`.
    let strip: CGImage?
    let onTap: () -> Void

    /// The strip is drawn at `scale: 2` over five 72×96 cells, so its natural
    /// size is 360×96 points. Cards are narrower than that at iPad portrait
    /// widths, so the image fits rather than fills and this is a ceiling, not
    /// a fixed height.
    private static let stripHeight: CGFloat = 96

    private var isSelectable: Bool { exclusionReason == nil }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                stripView
                HStack(spacing: 6) {
                    // Shape as well as colour: the checkmark is what says
                    // "selected" in greyscale, and it reserves its own width
                    // when absent so the timecode does not shift on a tap.
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    Text(rangeText)
                        .font(.callout.monospacedDigit())
                }
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    // Without this an exclusion sentence is truncated to one
                    // line, which loses the half that explains anything.
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minWidth: 44, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(.quaternary))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.35),
                        lineWidth: isSelected ? 3 : 1
                    )
            )
            // Inside the button's own label and bounded by the card's own
            // rounded rect. Not the parent-over-a-child case
            // `ComparisonControlBar` documents and refuses: nothing sits
            // behind a grid cell for this to swallow taps from, and without
            // it a `.plain` button only takes hits on its opaque pixels, so
            // the gaps between the text lines would not be tappable.
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .opacity(isSelectable ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!isSelectable)
        .help(accessibilityText)
        .accessibilityIdentifier("Segment \(segment.id)")
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var stripView: some View {
        if let strip {
            Image(decorative: strip, scale: 2)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: Self.stripHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            // A still placeholder rather than a spinner: a dozen cards each
            // animating an indeterminate indicator is a lot of motion to say
            // "not yet", and every one of them is replaced within a second.
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(height: Self.stripHeight)
                .overlay(
                    Image(systemName: "photo")
                        .imageScale(.large)
                        .foregroundStyle(.tertiary)
                )
                .accessibilityHidden(true)
        }
    }

    private var rangeText: String {
        Timecode.string(segment.firstSeen) + " – " + Timecode.string(segment.lastSeen)
    }

    /// The sample count, or the reason this segment cannot be picked — the
    /// reason takes the line, rather than being tucked away in a tooltip
    /// nobody hovers on a touchscreen.
    private var detailText: String {
        exclusionReason ?? "\(segment.detectionCount) samples"
    }

    /// One sentence used for both `.help` and `.accessibilityLabel`, so the
    /// tooltip and the screen reader cannot drift apart.
    private var accessibilityText: String {
        var text = "Segment \(segment.id), \(rangeText), \(segment.detectionCount) samples"
        if isSelected { text += ", selected" }
        if let exclusionReason { text += ". \(exclusionReason)" }
        return text
    }
}
