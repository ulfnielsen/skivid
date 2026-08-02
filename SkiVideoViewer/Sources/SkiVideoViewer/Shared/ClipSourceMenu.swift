import SkiVideoCore
import SwiftUI

/// Every route to putting a clip into one side — the file panel, and each open
/// athlete's videos — as one view, used by all three placements that offer it
/// so they cannot drift apart.
///
/// It used to live inside `ComparisonPane` as a private `clipSources`, which
/// was fine while the pane was the only thing that offered it. The overlay
/// layout offers it too now, and it is drawn by `ComparisonView` rather than by
/// the pane, so "what are the ways to load a clip" has to be sayable in one
/// place or the two layouts answer it differently.
///
/// The reported defect was not that the routes were missing from the loaded
/// pane — they were there, on the filename — but that at `.caption` over black
/// video they read as a label. `.overlayChip` is the same placement with a
/// control's appearance; see it for what changed and what deliberately did not.
struct ClipSourceMenu: View {
    enum Appearance {
        /// Centred in an empty pane. What exists today; do not change how it
        /// looks — an empty pane's prominent blue button is the one state of
        /// this control an operator already finds, and `ClipChooserTests`
        /// guards it while the others are fixed.
        case prominent
        /// Over video: reads as a control, not a caption.
        case overlayChip
    }

    @ObservedObject var model: ComparisonModel
    let side: ComparisonSide
    let appearance: Appearance
    /// Shown in the chip. The filename for a loaded side, "Choose Clip" when
    /// empty. Also the accessibility *identifier*, so renaming what the
    /// control says on screen is a change a test can see.
    let title: String

    @ViewBuilder
    var body: some View {
        switch appearance {
        case .prominent:
            prominent
        case .overlayChip:
            chip
        }
    }

    /// The empty pane's chooser, unchanged from the redesign: a prominent
    /// button in the middle of the pane, where the deleted header row's control
    /// used to be reachable from.
    ///
    /// The `maxWidth`/`maxHeight` frame is part of how it looks rather than a
    /// caller's placement decision — it is what centres the button in the pane
    /// — so it lives here with the appearance it belongs to.
    private var prominent: some View {
        chooser { Text(title) }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(spokenLabel)
            // The identifier is the *visible* title, and the label is the
            // spoken one. Overriding the label hides the title from the
            // accessibility tree entirely, so without this nothing observes it:
            // renaming the button in the UI is a mutation no test can see.
            .accessibilityIdentifier(title)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The loaded pane's chooser, and both of the overlay layout's.
    ///
    /// **Placement is unchanged and must stay unchanged** — bottom-leading over
    /// the letterbox, costing no layout height. Reclaiming the two header rows
    /// is the redesign this sits inside and the space it bought was measured,
    /// so the fix for "the operator cannot find it" is to make this look like a
    /// control, not to move it somewhere roomier.
    ///
    /// What makes it one: a `.thinMaterial` capsule, the same treatment
    /// `ComparisonStatusChip` uses to float over video, so the control has an
    /// edge instead of being loose text on black; a chevron that is always
    /// visible rather than appearing on hover, because a control nobody hovers
    /// is a control nobody finds; and a 44pt minimum height, per
    /// `ComparisonControlBar`'s rule for the controls we build ourselves.
    ///
    /// The `contentShape` is the case where a content shape does work — our own
    /// button's label, making its padding tappable, rather than an attempt to
    /// extend a system control's hit region. All it can swallow here is the
    /// video behind it, which takes no taps. (`ComparisonControlBar` documents
    /// the other case, where a `contentShape` on a band around a system control
    /// ate the taps meant for it.)
    private var chip: some View {
        chooser {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down")
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(.thinMaterial, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spokenLabel)
        .accessibilityIdentifier(title)
    }

    /// A plain `Button` when there is nothing to choose *between*, a `Menu`
    /// otherwise: the guarded shape Task 2 established for the anchor's context
    /// menu. A `Menu` whose only item is "Choose File…" is one tap of nothing.
    ///
    /// `.button` + `.plain` rather than the default menu style, which on macOS
    /// draws a bordered pop-up button — over video that reads as chrome rather
    /// than as this view's own capsule. Both are available at this project's
    /// minimums (macOS 13 / iOS 17), so no platform branch is needed. The
    /// caller supplies the outer `buttonStyle`, which the menu inherits.
    @ViewBuilder
    private func chooser(@ViewBuilder label: () -> some View) -> some View {
        if model.openLibrary.isEmpty {
            Button(action: { Task { await model.chooseVideo(side: side) } }, label: label)
        } else {
            Menu(content: { clipSources }, label: label)
                .menuIndicator(.hidden)
                .menuStyle(.button)
        }
    }

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

    /// **The spoken label names the side, and it takes the side from `side` —
    /// never from `title`.**
    ///
    /// Two panes read identically until clips are loaded, and in the overlay
    /// layout both chips sit in the same rect, so naming the side is the only
    /// thing that distinguishes them to VoiceOver *or* to a test: without it a
    /// chooser wired to the wrong side is invisible to both. Mutation-verified
    /// twice — building both panes with `side: .left` passed every assertion
    /// before this label existed, and building both overlay chips with
    /// `side: .left` still yields two labels that *differ*: measured,
    /// `"Left clip: left.mov"` and `"Left clip: Right · Choose Clip"`, because
    /// the titles differ even where the wiring does not. So the side is spoken
    /// first and `ClipChooserTests` asserts that prefix rather than mere
    /// difference, which is what catches it.
    ///
    /// `prominent` keeps its own wording because the iPad UI tests look the
    /// empty choosers up by it (`app.buttons["Choose left clip"]`) — which is
    /// also where "the label is really applied to the control" is observed,
    /// through a real accessibility tree on a real device.
    ///
    /// Internal rather than private so `ClipChooserTests` can read it off the
    /// chips the shipped view builds. `NSHostingView` publishes no
    /// accessibility children in a headless test process — measured: an
    /// offscreen window's hosting view reports `accessibilityChildren() == []`
    /// for a hierarchy containing two labelled buttons — so this is the only
    /// place a macOS unit test can see the side wiring at all.
    var spokenLabel: String {
        switch appearance {
        case .prominent:
            return "Choose \(sideName.lowercased()) clip"
        case .overlayChip:
            return "\(sideName) clip: \(titleWithoutSidePrefix)"
        }
    }

    /// The overlay chips already spell the side out on screen — they have to,
    /// since both clips are drawn into one rect — so speaking `title` verbatim
    /// after the label's own side would say it twice. Dropped only when it is
    /// this chip's *own* side, so a chip whose title names the other side reads
    /// as the contradiction it is rather than being tidied into silence.
    private var titleWithoutSidePrefix: String {
        let prefix = "\(sideName) \(Self.separator) "
        guard title.hasPrefix(prefix) else { return title }
        return String(title.dropFirst(prefix.count))
    }

    private var sideName: String { Self.sideName(side) }

    // MARK: - Titles

    /// What the control says when the side is empty, at every placement.
    static let chooseTitle = "Choose Clip"

    private static let separator = "·"

    static func sideName(_ side: ComparisonSide) -> String {
        side == .left ? "Left" : "Right"
    }

    /// Whether a side has a clip in it.
    ///
    /// `ComparisonModel` publishes no per-side "loaded" flag — `hasTwoVideos`
    /// is the only loaded signal and it answers for the pair — so this asks the
    /// player, exactly as `hasTwoVideos` does.
    ///
    /// `currentItem` is not itself observable, so this alone would not redraw a
    /// view. It does not have to: `load(_:side:)` is the only thing that sets
    /// `currentItem`, and it always also writes the published `leftName` /
    /// `rightName` (and the time and duration), so the view is invalidated by
    /// the same call that changes this value.
    @MainActor
    static func isLoaded(_ model: ComparisonModel, _ side: ComparisonSide) -> Bool {
        (side == .left ? model.leftPlayer : model.rightPlayer).currentItem != nil
    }

    /// The title for a side, for a chip that has to name it.
    ///
    /// The overlay layout draws both clips into one rect, so neither chip has a
    /// pane around it to say which clip it swaps — the title has to. The
    /// unloaded fallback is this view's `chooseTitle` and not
    /// `ComparisonModel.leftName`'s "Choose left video" placeholder, so that
    /// every empty chooser in the window says the same thing.
    @MainActor
    static func sidedTitle(_ model: ComparisonModel, _ side: ComparisonSide) -> String {
        let name = side == .left ? model.leftName : model.rightName
        return "\(sideName(side)) \(separator) \(isLoaded(model, side) ? name : chooseTitle)"
    }
}
