import SkiVideoCore
import SwiftUI

/// Composition only. Everything that used to be inline here — the panes, the
/// timeline, the transport, the blend controls — is one file each now; see the
/// spec's "Structure" table. Side-by-side is two rows of chrome, overlay three.
struct ComparisonView: View {
    @StateObject private var model: ComparisonModel
    let closeWindow: () -> Void

    init(
        initialLeftVideo: URL?,
        openLibrary: [ComparisonAthleteChoice],
        input: PlaybackInputSource,
        folderPicker: FolderPicker,
        closeWindow: @escaping () -> Void
    ) {
        _model = StateObject(
            wrappedValue: ComparisonModel(
                initialLeftVideo: initialLeftVideo,
                openLibrary: openLibrary,
                input: input,
                folderPicker: folderPicker
            )
        )
        self.closeWindow = closeWindow
    }

    var body: some View {
        VStack(spacing: 0) {
            videos
                .overlay(alignment: .topTrailing) { statusChip }

            // One surface for the chrome, as every deleted control row had.
            // Applied to the group rather than per row so the scrubber, the
            // blend bar and the control bar cannot end up on different
            // backgrounds; it changes no height.
            VStack(spacing: 0) {
                if model.layout == .overlay {
                    OverlayBlendBar(model: model)
                }
                ComparisonScrubber(model: model)
                    .padding(.horizontal, 12)
                ComparisonControlBar(model: model)
            }
            .background(.bar)
        }
        // An 11-inch iPad is 834pt wide in portrait, so a hard 1000pt minimum
        // clips. macOS keeps it: the Compare window is resizable and needs a
        // floor. Same shape as `ContentView`'s minimum-size conditional.
        #if os(macOS)
        .frame(minWidth: 1000, minHeight: 680)
        #endif
        // macOS drops the Close button — the window has one. iPad needs it,
        // because a full-screen cover has no chrome of its own, and it goes
        // over the video rather than into a row.
        #if os(iOS)
        .overlay(alignment: .topLeading) { closeButton }
        #endif
        .onDisappear { model.close() }
    }

    @ViewBuilder
    private var videos: some View {
        switch model.layout {
        case .sideBySide:
            HStack(spacing: 1) {
                ComparisonPane(model: model, side: .left)
                // Constrained deliberately: a bare `Divider()` inside an
                // `HStack` is vertically greedy and squeezes the video.
                Divider().frame(width: 1)
                ComparisonPane(model: model, side: .right)
            }
        case .overlay:
            // Both platforms use the SwiftUI stack. macOS previously had its
            // own NSViewRepresentable overlay, whose CALayer.compositingFilter
            // approach is a silent no-op on iOS.
            OverlayPlayerStack(
                bottomPlayer: model.leftPlayer,
                topPlayer: model.rightPlayer,
                topOpacity: model.topLayerOpacity,
                blend: model.blend
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// `model.status` is the only feedback `nudge` produces, and the rows that
    /// used to display it are deleted. Over the letterbox rather than in a row
    /// of its own: reclaiming vertical space is the point of this redesign, and
    /// a line that is only intermittently interesting is the last thing to
    /// spend a permanent row on.
    ///
    /// **Top**-trailing, and width-bounded. It was bottom-trailing on the
    /// reasoning that the pane filenames are bottom-*leading* and so could not
    /// collide. Measured on an 834pt portrait iPad, that was wrong: the chip
    /// laid out to 446pt against a 415pt right pane, overran the divider and
    /// covered the left pane's filename. The top edge is the only part of the
    /// video with nothing else in it — the iOS close button is top-*leading*
    /// and 68pt wide — and `maxWidth: 320` with two lines bounds the longest
    /// status ("Independent controls restored…", 83 characters) instead of
    /// letting it size itself.
    ///
    /// Not hit-testable, and that is load-bearing rather than defensive: with
    /// the chip hit-testable, synthetic clicks on the control underneath fired
    /// zero times.
    private var statusChip: some View {
        Text(model.status)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            // A `maxWidth` frame is greedy up to its maximum, so the pill is a
            // constant 340pt rather than sizing to the sentence. Deliberate:
            // constant geometry is what makes "it cannot reach the other pane"
            // checkable, and a chip that resized on every status change would
            // flicker beside the video.
            .frame(maxWidth: 320)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .padding(8)
            .allowsHitTesting(false)
            .accessibilityLabel("Status: \(model.status)")
    }

    private var closeButton: some View {
        Button {
            closeWindow()
        } label: {
            Image(systemName: "xmark")
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(12)
        .accessibilityLabel("Close comparison")
    }
}
