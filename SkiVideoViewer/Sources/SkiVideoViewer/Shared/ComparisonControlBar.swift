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
/// "44pt row" is the honest claim, and it is weaker than "44pt target" for two
/// of the controls. The transport buttons and the anchor are genuinely 44×44 —
/// a `frame` plus `contentShape` on a plain `Button`. The two segmented
/// pickers draw at their platform-intrinsic 24pt however tall a frame they are
/// given (measured on macOS: identical drawn pixel extent at `height: 44` and
/// unframed), so they get the 44pt frame *and* `contentShape(Rectangle())`,
/// which makes the surrounding band part of the picker's hit region rather
/// than a gap that falls through to the bar. Whether a tap in that band
/// actually selects the segment under it is the one thing that cannot be
/// measured headlessly — it needs Task 4's device check.
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
        .contentShape(Rectangle())
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
        .contentShape(Rectangle())
    }

    /// A `ForEach` over `allCases` rather than a restatement of the list:
    /// `TransportAction`'s declaration order *is* left-to-right button order,
    /// and the exhaustive `switch` in `appearance(of:)` means a case added to
    /// the model cannot silently fail to appear here.
    private var transport: some View {
        HStack(spacing: 4) {
            ForEach(TransportAction.allCases) { transportButton($0) }
        }
    }

    private func transportButton(_ action: TransportAction) -> some View {
        let appearance = Self.appearance(of: action)
        return Button {
            // Always through `applyTransport`, never the per-side model methods
            // it wraps: `lastTouchedSide` is written only there and in `load`,
            // so a control that bypasses it leaves that state stale and the
            // demotion off `.both` then lands on the wrong side.
            model.applyTransport(action)
        } label: {
            Image(systemName: appearance.symbol)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(appearance.label)
        .accessibilityLabel(appearance.label)
        .disabled(!model.hasTwoVideos)
    }

    private static func appearance(of action: TransportAction) -> (symbol: String, label: String) {
        switch action {
        case .back5: return ("gobackward.5", "Back 5 seconds")
        case .back1: return ("gobackward.minus", "Back 1 second")
        case .playPause: return ("playpause.fill", "Play or pause")
        case .forward1: return ("goforward.plus", "Forward 1 second")
        case .forward5: return ("goforward.5", "Forward 5 seconds")
        // Momentary, not a toggle. `applyTransport(.slow)` is fire-and-play at
        // 0.25×, and the rate it sets lives on `AVPlayer`, which publishes
        // nothing — a toggle rendered from it would show stale state whenever
        // the periodic time observer is idle, which is precisely while paused.
        // The way back to 1× is play/pause: it pauses, and the next play starts
        // at full rate. Labelled as the action it is.
        case .slow: return ("tortoise.fill", "Play at quarter speed")
        }
    }

    /// Follows the target, like the scrubber: a Right-targeted bar reading out
    /// the left clip's clock would contradict the timeline directly above it.
    private var timeLabel: some View {
        let side = model.target.scrubbedSide
        let time = side == .left ? model.leftTime : model.rightTime
        let duration = side == .left ? model.leftDuration : model.rightDuration
        return Text(ComparisonModel.timecode(time) + " / " + ComparisonModel.timecode(duration))
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
