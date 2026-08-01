import SkiVideoCore
import SwiftUI

/// One clip in side-by-side layout: the video, its name over the letterbox,
/// and the control that loads or replaces it.
///
/// The filename sits over the letterbox rather than in a header row, so it
/// costs no layout height; an empty pane puts its Choose control in the middle
/// of itself for the same reason. Those two header rows were the largest single
/// piece of chrome this redesign reclaims.
struct ComparisonPane: View {
    @ObservedObject var model: ComparisonModel
    let side: ComparisonSide

    private var name: String {
        side == .left ? model.leftName : model.rightName
    }

    /// `ComparisonModel` publishes no per-side "loaded" flag — `hasTwoVideos`
    /// is the only loaded signal and it answers for the pair — so this asks the
    /// player, exactly as `hasTwoVideos` does.
    ///
    /// `currentItem` is not itself observable, so this alone would not redraw
    /// the pane. It does not have to: `load(_:side:)` is the only thing that
    /// sets `currentItem`, and it always also writes the published `leftName` /
    /// `rightName` (and the time and duration), so the pane is invalidated by
    /// the same call that changes this value.
    private var isLoaded: Bool {
        (side == .left ? model.leftPlayer : model.rightPlayer).currentItem != nil
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            SinglePlayerView(player: side == .left ? model.leftPlayer : model.rightPlayer)

            if isLoaded {
                loadedName
            } else {
                emptyChooser
            }
        }
    }

    /// The filename is also the way to swap this side's clip. Deleting the
    /// header row deleted the only route to "From Open Folder…" and to loading
    /// a second clip into a pane that already has one — and comparing one run
    /// against several others is the whole workflow. A menu on the name keeps
    /// both routes at zero layout cost, which is the point of the redesign;
    /// dropping them would have been a feature deletion the spec never asked
    /// for.
    private var loadedName: some View {
        Menu {
            clipSources
        } label: {
            HStack(spacing: 4) {
                Text(name).lineLimit(1)
                Image(systemName: "chevron.down")
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.85))
            .padding(8)
            // The case where a content shape does work — our own button's
            // label, making its padding tappable, rather than an attempt to
            // extend a system control's hit region. All it can swallow here is
            // the video behind it, which takes no taps.
            .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        // `.button` + `.plain` rather than the default menu style, which on
        // macOS draws a bordered pop-up button — over video that reads as
        // chrome rather than as a caption. Both are available at this project's
        // minimums (macOS 13 / iOS 17), so no platform branch is needed.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("\(sideName) clip: \(name)")
    }

    /// A plain button when there is nothing to choose *between*: the guarded
    /// shape Task 2 established for the anchor's context menu. A `Menu` whose
    /// only item is "Choose File…" is one tap of nothing.
    ///
    /// The two panes read identically until clips are loaded, so the
    /// accessibility label names the side while the visible title stays the
    /// spec's "Choose Clip". That is not decoration: it is the only thing that
    /// distinguishes the panes to VoiceOver *or* to a test, and without it a
    /// pane wired to the wrong side is invisible to both. Mutation-verified —
    /// building both panes with `side: .left` passed every assertion before
    /// this label existed.
    @ViewBuilder
    private var emptyChooser: some View {
        Group {
            if model.openLibrary.isEmpty {
                Button(Self.chooseTitle) { Task { await model.chooseVideo(side: side) } }
            } else {
                Menu(Self.chooseTitle) { clipSources }
                    .menuStyle(.button)
            }
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel(chooseLabel)
        // The identifier is the *visible* title, and the label is the spoken
        // one. Overriding the label hides the title from the accessibility
        // tree entirely, so without this nothing observes it: renaming the
        // button in the UI is a mutation no test can see. Both derive from one
        // literal, so they cannot drift.
        .accessibilityIdentifier(Self.chooseTitle)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What the button says. The two panes read identically until clips are
    /// loaded, so the spoken label names the side while this stays the spec's
    /// wording.
    private static let chooseTitle = "Choose Clip"

    private var chooseLabel: String {
        "Choose \(sideName.lowercased()) clip"
    }

    /// Every route to putting a clip into this side, shared by both states so
    /// they cannot drift apart.
    @ViewBuilder
    private var clipSources: some View {
        Button("Choose File…") { Task { await model.chooseVideo(side: side) } }
        ForEach(model.openLibrary) { athlete in
            Menu(athlete.name) {
                ForEach(athlete.videos) { video in
                    Button(video.name) { model.load(video, side: side) }
                }
            }
        }
    }

    private var sideName: String {
        side == .left ? "Left" : "Right"
    }
}
