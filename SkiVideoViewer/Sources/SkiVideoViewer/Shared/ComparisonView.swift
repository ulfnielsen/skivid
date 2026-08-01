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
                .overlay(alignment: .bottomTrailing) { statusChip }

            if model.layout == .overlay {
                OverlayBlendBar(model: model)
            }
            ComparisonScrubber(model: model)
                .padding(.horizontal, 12)
            ComparisonControlBar(model: model)
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
    /// spend a permanent row on. Bottom-*trailing* so it cannot collide with a
    /// pane's filename, which sits bottom-leading.
    ///
    /// Not hit-testable: it floats over the video and, like the content shapes
    /// Task 2 removed, anything transparent laid over another control's area
    /// only swallows taps.
    private var statusChip: some View {
        Text(model.status)
            .font(.caption)
            .foregroundStyle(.secondary)
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
