import SkiVideoCore
import SwiftUI

/// Layout picker, target selector, transport, time and the sync anchor — the
/// one row that replaces the previous three transports.
///
/// Wraps to two rows rather than shrinking when it does not fit: every control
/// keeps its 44pt row at every width. `ViewThatFits` tries the single row first
/// and falls through to the stacked one, which is also the last candidate and
/// so the one used when nothing fits.
///
/// **The 44pt rule applies to the controls we build, not to system controls.**
/// The anchor is a plain `Button` and is genuinely 44×44, by `frame` plus
/// `contentShape`; the six transport buttons are the same shape, built in
/// `TransportControls`. The two segmented pickers are not, and cannot be made
/// so from here — 32pt is the iPadOS standard size for a segmented control,
/// which is the size to want.
///
/// The `height: 44` frames below reserve the row — real, and what gives the
/// two-row layout its rhythm — but they do **not** enlarge the control.
/// Measured rather than assumed, so nobody re-derives it the hard way:
///
/// - A segmented `Picker` draws over 24pt on macOS (32pt on iPadOS) and a
///   `Slider` over 16pt, identically whether framed at `height: 44` or left
///   unframed. A parent frame centres them; it does not grow them.
/// - `contentShape(Rectangle())` on the framed parent does not help either.
///   Synthetic clicks at the third segment selected over the same ~24pt band
///   with it, without it, and with no height frame at all. A parent's content
///   shape defines *that view's* hit region; it cannot route a hit into a child
///   control's segments. Its one measurable effect was to *swallow* clicks in
///   the surrounding band — a background tap gesture fired zero times with it
///   and once without — so it is deliberately absent here. Do not add it: it
///   would silently eat taps meant for whatever sits behind the bar.
struct ComparisonControlBar: View {
    @ObservedObject var model: ComparisonModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                layoutPicker
                targetPicker
                transport
                Spacer(minLength: 8)
                timeLabel
                anchorButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    layoutPicker
                    targetPicker
                    Spacer(minLength: 0)
                }
                HStack(spacing: 16) {
                    transport
                    Spacer(minLength: 8)
                    timeLabel
                    anchorButton
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // A segmented picker is greedy horizontally — offered more width it takes
    // it — so both pickers carry a fixed width. That is not cosmetic here:
    // `ViewThatFits` chooses by comparing each candidate's *ideal* width
    // against the width it was offered, and a greedy child makes that ideal
    // width meaningless.

    private var layoutPicker: some View {
        Picker("Layout", selection: $model.layout) {
            ForEach(ComparisonLayout.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 180, height: 44)
    }

    /// Bound to `availableTargets`, never `ComparisonTarget.allCases`: `.both`
    /// is deliberately absent while aligning, because `playSynced` and
    /// `seekSynced` refuse unless synced, so offering it would be a control
    /// that can only produce a nag — exactly what this redesign deletes.
    ///
    /// One width for both segment counts, rather than 110/160. Measured: with
    /// a variable width the whole bar's ideal width changes with `isSynced`
    /// (830.5pt vs 880.5pt), which put the wrap threshold *between* the two
    /// states at exactly the 834pt the spec calls out — so tapping the anchor
    /// on an 11-inch iPad in portrait reflowed the bar from one row to two and
    /// resized the video above it. A constant width makes the threshold
    /// (880.5pt) the same in both states, and keeps the transport from
    /// shifting sideways when `Both` appears.
    private var targetPicker: some View {
        Picker("Controls", selection: $model.target) {
            ForEach(model.availableTargets) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 160, height: 44)
    }

    /// One definition, referenced from both `ViewThatFits` branches — not
    /// restated in each — so the routing through `applyTransport` lives in
    /// exactly one place.
    private var transport: some View {
        TransportControls(isEnabled: model.hasTwoVideos) { action in
            // Always through `applyTransport`, never the per-side model
            // methods it wraps: `lastTouchedSide` is written only there
            // and in `load`, so a control that bypasses it leaves that
            // state stale and the demotion off `.both` lands on the
            // wrong side.
            model.applyTransport(action)
        }
    }

    /// Follows the target, like the scrubber: a Right-targeted bar reading out
    /// the left clip's clock would contradict the timeline directly above it.
    private var timeLabel: some View {
        let side = model.target.scrubbedSide
        let time = side == .left ? model.leftTime : model.rightTime
        let duration = side == .left ? model.leftDuration : model.rightDuration
        return Text(Timecode.string(time) + " / " + Timecode.string(duration))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    /// Absorbs three of today's text buttons — Set Sync Points, Back to Sync
    /// Points and Unsync — the first two by changing meaning with `isSynced`,
    /// the third as the secondary action (right-click on Mac, long-press on
    /// touch).
    ///
    /// The whole `contextMenu` is conditional, not just its contents: a menu
    /// whose only item is gated on `isSynced` still counts as a context menu
    /// while aligning, and pops up empty.
    @ViewBuilder
    private var anchorButton: some View {
        if model.isSynced {
            anchorControl.contextMenu {
                Button("Clear sync", role: .destructive) { model.removeSync() }
            }
        } else {
            anchorControl
        }
    }

    private var anchorControl: some View {
        Button {
            if model.isSynced { model.returnToSyncPoints() } else { model.setSyncPoints() }
        } label: {
            Image(systemName: model.isSynced ? "pin.fill" : "pin")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(anchorLabel)
        .accessibilityLabel(anchorLabel)
        .disabled(!model.hasTwoVideos)
        // Carried over from the "Set Sync Points" button this replaces, so the
        // key equivalent survives the row being deleted. It follows the
        // button's meaning: ⌘Return sets the sync points while aligning and
        // returns to them once synced.
        .keyboardShortcut(.return, modifiers: .command)
    }

    private var anchorLabel: String {
        model.isSynced ? "Return to sync points" : "Set sync points"
    }
}
