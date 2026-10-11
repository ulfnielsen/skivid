import SkiVideoCore
import SwiftUI

/// Transport, time and clip stepping — the one row that replaces three text
/// buttons and a hint line.
///
/// No layout or target picker, unlike the comparison screen's bar, so this is
/// roughly 230pt narrower and expected to fit one row at every iPad width.
/// `ViewThatFits` still carries a wrapped fallback: an expectation is not a
/// measurement, and Task 4 measures it.
struct ViewerControlBar: View {
    @ObservedObject var model: ViewerModel
    /// `canDraw` reads `pictureSize` (published on `model`) and
    /// `drawing.session` (published on `drawing`), so both are observed.
    @ObservedObject var drawing: DrawingController
    @Environment(\.isShortOnHeight) private var isShortOnHeight

    init(model: ViewerModel) {
        self.model = model
        _drawing = ObservedObject(wrappedValue: model.drawing)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                transport
                Spacer(minLength: 8)
                timeLabel
                drawingButtons
                clipStepping
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    transport
                    Spacer(minLength: 0)
                }
                HStack(spacing: 16) {
                    Spacer(minLength: 8)
                    timeLabel
                    drawingButtons
                    clipStepping
                }
            }
        }
        .padding(.horizontal, isShortOnHeight ? 8 : 12)
        .padding(.vertical, isShortOnHeight ? 2 : 8)
    }

    private var transport: some View {
        TransportControls(isEnabled: model.currentPlaybackURL != nil) { action in
            model.applyTransport(action)
        }
    }

    private var drawingButtons: some View {
        HStack(spacing: 4) {
            Button { model.setDrawing(true) } label: {
                Image(systemName: "pencil.tip.crop.circle").frame(width: 44, height: isShortOnHeight ? 34 : 44).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Draw (D)")
            .accessibilityLabel("Draw")
            .accessibilityIdentifier("viewer.draw")
            .disabled(!model.canDraw)

            Button { drawing.showsDrawings.toggle() } label: {
                Image(systemName: drawing.showsDrawings ? "eye" : "eye.slash")
                    .frame(width: 44, height: isShortOnHeight ? 34 : 44).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(drawing.showsDrawings ? "Hide drawings" : "Show drawings")
            .accessibilityLabel("Show drawings")
            .accessibilityValue(drawing.showsDrawings ? "On" : "Off")
            .accessibilityIdentifier("viewer.showDrawings")
        }
    }

    private var timeLabel: some View {
        Text(Timecode.string(model.currentTime) + " / " + Timecode.string(model.duration))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    /// Navigation *between* clips, not transport *within* one, so it sits apart
    /// from the transport rather than joining it.
    private var clipStepping: some View {
        HStack(spacing: 4) {
            stepButton("backward.end.fill", "Previous clip", by: -1)
            stepButton("forward.end.fill", "Next clip", by: 1)
        }
    }

    private func stepButton(_ symbol: String, _ label: String, by offset: Int) -> some View {
        Button {
            model.changeVideo(by: offset)
        } label: {
            Image(systemName: symbol)
                .frame(width: 44, height: isShortOnHeight ? 34 : 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
        .disabled(model.currentPlaybackURL == nil)
    }
}
