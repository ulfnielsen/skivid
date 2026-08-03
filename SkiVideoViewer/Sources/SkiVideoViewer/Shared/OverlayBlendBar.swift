import SkiVideoCore
import SwiftUI

/// Overlay-only: how strongly the top clip is drawn, in which mode, and whether
/// the two are drawn spatially aligned.
///
/// The slider is disabled in difference mode because `topLayerOpacity` forces
/// 1.0 there — an enabled control that does nothing is exactly what this
/// redesign is removing. The explanatory sentence the old bar carried beside it
/// is gone with the rest of the hint text; the disabled state says the same
/// thing without a row.
///
/// No `contentShape(Rectangle())` on the picker or the slider. Measured in
/// Task 2: a parent's content shape cannot route a hit into a child control's
/// segments — it only swallows clicks in the surrounding band, which here is
/// the video. Do not add it. The two buttons below are the other case: they are
/// controls this project builds rather than system controls, so they carry the
/// 44pt frame *and* a content shape, exactly as `ComparisonControlBar`'s anchor
/// and subject buttons do.
///
/// **The alignment controls are a constant width in every state.** Compute,
/// working-with-a-Cancel and Align all lay out inside the same
/// `alignmentControlWidth`. That is the lesson `ComparisonControlBar.targetPicker`
/// records, applied before it can bite: a group that changed width when the pass
/// started would slide the blend picker sideways under the operator's pointer,
/// mid-gesture, for fifteen seconds.
struct OverlayBlendBar: View {
    @ObservedObject var model: ComparisonModel
    @ObservedObject var alignment: AlignmentSessionModel

    /// Whether the pass has what it needs: a local file on each side and a
    /// detected run start on each. Decided by `ComparisonView`, which is the
    /// only place that knows both, and handed in — so a test can see the bar
    /// refuse rather than infer it.
    var canComputeAlignment = false

    /// Starts the registration pass. A closure rather than a call into
    /// `alignment` directly, because the pass needs the two clip URLs and the
    /// two run starts, and this bar deliberately knows none of them.
    var onComputeAlignment: () -> Void = {}

    /// One width for all three states of the alignment group: the 44pt Align
    /// toggle plus the 44pt action, with the `HStack`'s 16pt between them.
    private static let alignmentControlWidth: CGFloat = 44 + 16 + 44

    /// The glyphs, named once so a test can assert they resolve to real
    /// symbols. A misspelt `systemName` renders an empty frame with no error
    /// anywhere — a control that is there, hittable, and invisible — and this
    /// project has measured repeatedly that neither a view-tree search nor an
    /// offscreen render will tell you a control did not draw.
    static let alignOnSymbol = "align.horizontal.center.fill"
    static let alignOffSymbol = "align.horizontal.center"
    static let computeSymbol = "square.on.square.dashed"

    var body: some View {
        HStack(spacing: 16) {
            Text("Left").font(.caption).foregroundStyle(.secondary)
            Slider(value: $model.overlayOpacity, in: 0...1)
                .disabled(model.blend == .difference)
                .accessibilityLabel("Blend between left and right")
            Text("Right").font(.caption).foregroundStyle(.secondary)

            Picker("Blend mode", selection: $model.blend) {
                ForEach(OverlayBlend.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

            alignmentControls
                .frame(width: Self.alignmentControlWidth)
        }
        .padding(.horizontal, 12)
        // The controls themselves draw over 24pt, which put the slider and the
        // blend picker hard against the video above and the scrubber below.
        // Matches the control bar's own vertical padding.
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var alignmentControls: some View {
        if case let .computing(progress) = alignment.state {
            HStack(spacing: 16) {
                // Determinate, unlike the run-start pass's spinner: this one
                // reports progress after every frame pair, and a 15-second wait
                // with nothing moving reads as a hang.
                ProgressView(value: progress)
                    .frame(width: 44)
                    .accessibilityLabel("Computing alignment")
                cancelButton
            }
        } else {
            HStack(spacing: 16) {
                alignToggle
                computeButton
            }
        }
    }

    /// A `Button` whose symbol carries the state, not a `Toggle`.
    ///
    /// The same shape as `ComparisonControlBar.anchorControl`, which flips
    /// between `pin` and `pin.fill` and renames itself — so the chrome has one
    /// idiom for "a 44pt control that shows what it will do" rather than two.
    ///
    /// Measured, and the reason this is not a `Toggle(...).toggleStyle(.button)`
    /// as first written: that style draws its own border *around* the 44pt
    /// frame, which took the whole overlay band from 40pt to 68pt, and it
    /// renders no `NSButton` at all — a synthetic click cannot reach it, so the
    /// wiring below could not be tested the way every other control in this
    /// bar's neighbours is.
    private var alignToggle: some View {
        Button {
            alignment.isAligned.toggle()
        } label: {
            Image(systemName: alignment.isAligned ? Self.alignOnSymbol : Self.alignOffSymbol)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!alignment.canAlign)
        // The disabled state says *why*, which is the whole point of leaving
        // the control visible instead of hiding it.
        .help(alignment.alignmentUnavailableReason ?? alignLabel)
        .accessibilityLabel(alignment.alignmentUnavailableReason ?? alignLabel)
        .accessibilityIdentifier("Align")
    }

    /// Names the action rather than the state, as the anchor's label does: the
    /// symbol already says which way the switch is thrown, and a label that
    /// repeats it leaves the operator guessing what pressing it would do.
    private var alignLabel: String {
        alignment.isAligned ? "Stop aligning the clips" : "Draw the clips spatially aligned"
    }

    private var computeButton: some View {
        Button {
            onComputeAlignment()
        } label: {
            Image(systemName: Self.computeSymbol)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(computeLabel)
        .accessibilityLabel(computeLabel)
        .accessibilityIdentifier("Compute alignment")
        .disabled(!canComputeAlignment)
    }

    /// Cancels the run in flight. Straight into the model — unlike Compute,
    /// this needs nothing the bar does not have, and routing it through a
    /// closure would put a link in the chain with nothing on the far end of it.
    private var cancelButton: some View {
        Button {
            alignment.cancel()
        } label: {
            Image(systemName: "xmark")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Stop computing alignment")
        .accessibilityLabel("Stop computing alignment")
        .accessibilityIdentifier("Cancel alignment")
    }

    /// Names what is missing rather than only what the button does, for the
    /// same reason `ComparisonControlBar.subjectLabel` names its side: a
    /// disabled control whose tooltip only restates its title tells the
    /// operator nothing about how to enable it.
    private var computeLabel: String {
        canComputeAlignment
            ? "Compute how the two clips line up"
            : "Find the subject in both clips first, so each run start is known"
    }
}
