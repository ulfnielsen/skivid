import SkiVideoCore
import SwiftUI

/// One clip in side-by-side layout: the video, its name over the letterbox,
/// and the control that loads or replaces it.
///
/// The filename sits over the letterbox rather than in a header row, so it
/// costs no layout height; an empty pane puts its Choose control in the middle
/// of itself for the same reason. Those two header rows were the largest single
/// piece of chrome this redesign reclaims.
///
/// Both states are `ClipSourceMenu` now — same routes, two appearances — so the
/// side-by-side panes and the overlay layout offer the same ways to load a clip
/// by construction rather than by two lists staying in step.
struct ComparisonPane: View {
    @ObservedObject var model: ComparisonModel
    let side: ComparisonSide

    private var name: String {
        side == .left ? model.leftName : model.rightName
    }

    private var isLoaded: Bool {
        ClipSourceMenu.isLoaded(model, side)
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
    ///
    /// **It kept the route and lost the affordance.** At `.caption`, white on
    /// black, with the chevron the only hint that it was pressable, the
    /// operator's report was "I don't see a way to select the comparison video
    /// anymore" — the control was there and read as a caption. `overlayChip`
    /// is the same placement, at zero layout cost still, wearing a material
    /// capsule and a 44pt tap target. The 8pt inset lives here rather than in
    /// the chip because it is a placement decision, exactly as `ComparisonView`
    /// insets the status chip.
    ///
    /// The pane's own title needs no side prefix — which pane it is in says
    /// that — so this passes the bare filename and lets `ClipSourceMenu` name
    /// the side in the spoken label alone.
    private var loadedName: some View {
        ClipSourceMenu(model: model, side: side, appearance: .overlayChip, title: name)
            .padding(8)
    }

    /// The two panes read identically until clips are loaded, so the
    /// accessibility label names the side while the visible title stays the
    /// spec's "Choose Clip". That is not decoration: it is the only thing that
    /// distinguishes the panes to VoiceOver *or* to a test, and without it a
    /// pane wired to the wrong side is invisible to both. Mutation-verified —
    /// building both panes with `side: .left` passed every assertion before
    /// this label existed. See `ClipSourceMenu.spokenLabel`, which now owns it.
    private var emptyChooser: some View {
        ClipSourceMenu(
            model: model,
            side: side,
            appearance: .prominent,
            title: ClipSourceMenu.chooseTitle
        )
    }
}
