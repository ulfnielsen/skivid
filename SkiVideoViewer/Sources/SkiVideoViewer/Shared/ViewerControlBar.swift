import SkiVideoCore
import SwiftUI

/// Transport, zoom, time and clip stepping — the one row that replaces three
/// text buttons and a hint line.
///
/// No layout or target picker, unlike the comparison screen's bar, so this is
/// still roughly 90pt narrower than that one. The zoom control cost 236.0pt of
/// the margin it used to have, though: measured in
/// `ViewerControlBarLayoutTests`, the ideal width moved from 557.0pt to
/// 793.0pt, which is *above* the 744pt iPad mini portrait width. The
/// `ViewThatFits` fallback is therefore no longer a precaution — it is the
/// layout the narrower iPad actually gets.
struct ViewerControlBar: View {
    @ObservedObject var model: ViewerModel
    /// The video pane's measured size, from `ViewerPane`'s `GeometryReader` by
    /// way of `ContentView`.
    ///
    /// `ViewerModel.setZoomScale` re-clamps the pan against the pane, and this
    /// bar is the pane's sibling: its own geometry describes the control row,
    /// not the video. Defaulted to `.zero` so the layout-measurement tests can
    /// host the bar with no pane at all — `VideoZoom.setScale` documents a
    /// degenerate pane as "apply the scale, skip the re-clamp", and
    /// `layerFrame` re-clamps whatever it renders regardless.
    var videoPaneSize: CGSize = .zero

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                transport
                zoomControl
                Spacer(minLength: 8)
                timeLabel
                clipStepping
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    transport
                    Spacer(minLength: 0)
                }
                HStack(spacing: 16) {
                    zoomControl
                    Spacer(minLength: 8)
                    timeLabel
                    clipStepping
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Out-of-range requests reach `setZoomScale` unfiltered — `ZoomControl`'s
    /// minus button offers 0.5 at 1×, its plus button 4.5 at 4× — and that is
    /// deliberate rather than an oversight in the control: `VideoZoom.setScale`
    /// clamps to `VideoZoom.range` unconditionally, so the range is enforced in
    /// exactly one place and no call site has to restate it.
    private var zoomControl: some View {
        ZoomControl(
            zoom: model.zoom,
            isEnabled: model.currentPlaybackURL != nil,
            onScale: { model.setZoomScale($0, in: videoPaneSize) },
            onReset: { model.resetZoom() }
        )
        .frame(maxWidth: 220)
    }

    private var transport: some View {
        TransportControls(isEnabled: model.currentPlaybackURL != nil) { action in
            model.applyTransport(action)
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
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
        .disabled(model.currentPlaybackURL == nil)
    }
}
