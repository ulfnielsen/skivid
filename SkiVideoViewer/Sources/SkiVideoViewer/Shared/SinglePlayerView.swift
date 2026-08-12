import AVFoundation
import SkiVideoCore
import SwiftUI

/// One `AVPlayer` rendered by an `AVPlayerLayer`, with no transport controls.
/// Every screen in the app draws video through this: the overlay stacks two of
/// them, the two comparison panes take one each, and the viewer and the sorting
/// sheet use one apiece. It began as the
/// overlay's own view, because stacking needs a bare layer rather than the full
/// AVKit player controller the other screens used at the time; that controller
/// then turned out to be un-zoomable — its layer cannot be given a frame
/// independent of its view — and went, leaving this.
///
/// `resizeAspect`, not `resizeAspectFill`: the overlay compares two clips, and
/// cropping either one would make the comparison lie. Phase 3 established the
/// same rule for the main viewer on iPad. The zoom does not weaken that — it
/// hands the layer a frame already fitted to the clip's aspect, so the gravity
/// has no bars left to add and the picture is never cropped by anything except
/// the operator's own pan.
struct SinglePlayerView: View {
    let player: AVPlayer
    /// Defaulted so the pure-renderer call sites that predate zoom — and the
    /// tests that build this view without one — stay honest about not passing
    /// one.
    var zoom: VideoZoom = VideoZoom()

    var body: some View {
        PlayerLayerRepresentable(player: player, zoom: zoom)
    }
}

#if os(macOS)
import AppKit

private struct PlayerLayerRepresentable: NSViewRepresentable {
    let player: AVPlayer
    let zoom: VideoZoom

    func makeNSView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.attach(player)
        view.apply(zoom)
        return view
    }

    func updateNSView(_ view: PlayerLayerHostView, context: Context) {
        view.attach(player)
        view.apply(zoom)
    }

    // The macOS overlay this replaced detached its players in `dismantleNSView`
    // as a deliberate rule; keep it. A layer left holding an `AVPlayer` keeps a
    // render path alive for a view SwiftUI has already discarded.
    static func dismantleNSView(_ view: PlayerLayerHostView, coordinator: ()) {
        view.detach()
    }
}

final class PlayerLayerHostView: NSView {
    private let playerLayer = AVPlayerLayer()
    private var zoom = VideoZoom()
    private var itemObserver: NSKeyValueObservation?
    private var videoSizeObserver: NSKeyValueObservation?

    /// Which clip this view is drawing.
    ///
    /// Readable so a test can tell the overlay's two stacked player views apart
    /// in the hosted AppKit tree. That is not incidental: "which clip moves" is
    /// the whole of the alignment behaviour, the two views are otherwise
    /// identical black rects, and neither renderer this project has measured
    /// draws an `AVPlayerLayer`'s content — `ImageRenderer` fills the rect with
    /// its unrenderable placeholder and `cacheDisplay` gives black — so pixels
    /// cannot answer it.
    var attachedPlayer: AVPlayer? { playerLayer.player }

    /// Readable for the same reason `attachedPlayer` is: the geometry is the
    /// whole of the zoom behaviour, and pixels cannot answer "did it zoom"
    /// *from the video*, which is what `attachedPlayer` explains.
    ///
    /// Pixels can answer where a layer was *placed*, though — that limitation is
    /// about video content, not about layer geometry. A plain marker sublayer
    /// renders through `cacheDisplay` on a windowless view, which is how
    /// `testTheHostIsFlippedSoTheSharedRectIsReadTopDown` pins the y-axis
    /// convention on rendered pixels instead of on the `isFlipped` flag.
    var playerLayerFrame: CGRect { playerLayer.frame }

    /// The zoom this view was last given, as distinct from the frame it
    /// produced: a host that is handed the right zoom but computes the frame
    /// against the wrong pane, and one that is never handed the zoom at all,
    /// are different failures in different files.
    var appliedZoom: VideoZoom { zoom }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        wantsLayer = true
        let host = layer ?? CALayer()
        layer = host
        playerLayer.videoGravity = .resizeAspect
        // A zoomed layer is deliberately larger than this view. Unclipped it
        // paints over whatever sits beside it — which in the comparison window
        // is the other athlete's pane, and in the overlay is the other clip.
        host.masksToBounds = true
        host.addSublayer(playerLayer)
    }

    /// **The y-axis convention, and the only reason this view is flipped.**
    ///
    /// `layerFrame` returns one `origin.y` for both platforms, and it is
    /// written top-down: `center.y == 0` is the *top* of the picture, which is
    /// what `pan`'s negation means once SwiftUI's positive-downward
    /// `DragGesture.translation.height` feeds it — dragging down pushes the
    /// picture down and reveals its top. A `UIView`'s layer reads that rect
    /// top-down already. An unflipped layer-backed `NSView` reads it from the
    /// bottom, so macOS would show the opposite end of the clip from iPad at
    /// every pan except the centred one.
    ///
    /// Measured on a real clip whose top quarter is white, 640x360 in a
    /// 320x180 pane at 4x, captured off the screen — mean luminance of the
    /// pane's top third:
    ///
    /// |                    | drag down (`center.y` 0.125) | drag up (0.875) |
    /// | ------------------ | ---------------------------- | --------------- |
    /// | unflipped          | 0 (the picture's bottom)     | 255 (its top)   |
    /// | `isFlipped = true` | 255 (its top)                | 0 (its bottom)  |
    ///
    /// A clean inversion, and `isFlipped` fixes it. Two things were measured
    /// rather than assumed alongside it.
    ///
    /// The flip moves the layer's *frame* without turning the video content
    /// upside down: at 1x the white band stays at the top of the pane in both
    /// variants, reading 191 in that capture's **top** third against 0 in its
    /// **bottom** third either way.
    ///
    /// And `layer.isGeometryFlipped = true` — the other obvious candidate —
    /// does **nothing** here, giving byte-identical readings to the unflipped
    /// case. Note what that is *not*: AppKit does not overwrite the value.
    /// Measured on a layer-backed `NSView`, it reads back `true` immediately
    /// after being set and still `true` after a render, and the render is
    /// simply unaffected — top 0 / bottom 255, identical to never setting it.
    /// Why it has no effect was not established, only that it has none, which
    /// is why `isFlipped` is what ships.
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        placeLayer()
    }

    /// **Ignores a zoom equal to the one already applied**, so SwiftUI's
    /// habit of calling `updateNSView` for unrelated reasons does not re-place
    /// the layer on every pass. This is therefore not a way to force a
    /// refresh after something *else* changed: `bounds` changes come back
    /// through `layout`, and the video size through `observeVideoSize`.
    func apply(_ zoom: VideoZoom) {
        guard zoom != self.zoom else { return }
        self.zoom = zoom
        placeLayer()
    }

    func attach(_ player: AVPlayer) {
        if playerLayer.player !== player {
            playerLayer.player = player
            observeVideoSize(of: player)
        }
    }

    func detach() {
        playerLayer.player = nil
        itemObserver = nil
        videoSizeObserver = nil
    }

    /// Layer frame changes animate implicitly, which lags the video during a
    /// window resize and turns every zoom step into a slide. Apply them
    /// immediately.
    private func placeLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = zoom.layerFrame(
            in: bounds.size,
            videoSize: playerLayer.player?.currentItem?.presentationSize ?? .zero
        )
        CATransaction.commit()
    }

    /// Re-places the layer when the clip's own size *arrives*.
    ///
    /// `presentationSize` is `.zero` until the asset has loaded, and
    /// `layerFrame` deliberately falls back to the pane's rect for that window.
    /// So a layer placed once at `makeNSView` time would keep the pre-load
    /// geometry forever: on a clip whose aspect differs from the pane's, every
    /// zoom would be computed against the wrong picture until some unrelated
    /// window resize happened to run `layout` again — silently wrong, with
    /// nothing on screen to explain it.
    ///
    /// Two links, because both arrive late: the player gets a `currentItem`
    /// after `attach` (and gets a new one on every clip the operator loads),
    /// and that item gets a real `presentationSize` after its tracks load.
    ///
    /// **`.initial` on each, but only one of the two is pinned by a test.** The
    /// models own long-lived players and load clips into them; the SwiftUI view
    /// is built — and rebuilt on every navigation — afterwards, so `attach`
    /// normally arrives at a player whose item already has a real size and no
    /// `currentItem` change left to post.
    ///
    /// - The **outer** `.initial`, on `\.currentItem`, is load-bearing and
    ///   measured: deleting it strands an already-loaded clip on the pane
    ///   fallback, and `testTheLayerIsRePlacedWhenThePresentationSizeArrives`
    ///   fails at 1600 instead of 1200.
    /// - The **inner** `.initial`, on `\.presentationSize`, is *not* pinned:
    ///   that same test still passes without it, because something re-posts
    ///   `presentationSize` when a second `AVPlayerLayer` attaches to a settled
    ///   player. It is kept anyway, and not because "belt and braces" — the
    ///   test attaches the *second* layer to that player, while production
    ///   attaches the *first* to a model-owned one, so the delivery the test
    ///   rides on may simply not exist in the arrangement that ships. Keeping
    ///   it costs nothing; removing it on the strength of a test that does not
    ///   cover the production case would be trading a known-safe line for an
    ///   unmeasured one.
    ///
    /// Do not "clean up" the inner option on the grounds that the suite still
    /// passes. The suite passing is the documented starting point here, not new
    /// information.
    ///
    /// **Neither hop reads the KVO change payload**, and that is what makes
    /// them order-safe: `Task { @MainActor }` gives no ordering guarantee
    /// between two notifications, so a captured value can settle stale, while
    /// re-reading the current item and its current size makes every hop
    /// converge on the player's present state no matter what order they run
    /// in. `ViewerModel.startObservingRate` spells out the same rule and is
    /// the precedent to follow if this is ever "optimised" into using
    /// `change.newValue`. The identity guards are a separate concern — they
    /// drop deliveries for a player or item this view has already moved on
    /// from, which converging alone would not.
    private func observeVideoSize(of player: AVPlayer) {
        videoSizeObserver = nil
        itemObserver = player.observe(\.currentItem, options: [.initial, .new]) { [weak self, weak player] _, _ in
            Task { @MainActor in
                guard let self, let player, self.playerLayer.player === player else { return }
                self.observePresentationSize(of: player.currentItem)
            }
        }
    }

    private func observePresentationSize(of item: AVPlayerItem?) {
        guard let item else {
            videoSizeObserver = nil
            placeLayer()
            return
        }
        videoSizeObserver = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, let item, self.playerLayer.player?.currentItem === item else { return }
                self.placeLayer()
            }
        }
    }
}
#else
import UIKit

private struct PlayerLayerRepresentable: UIViewRepresentable {
    let player: AVPlayer
    let zoom: VideoZoom

    func makeUIView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.attach(player)
        view.apply(zoom)
        return view
    }

    func updateUIView(_ view: PlayerLayerHostView, context: Context) {
        view.attach(player)
        view.apply(zoom)
    }

    // Same rule as the macOS branch: detach on teardown so a discarded view's
    // layer stops holding the player.
    static func dismantleUIView(_ view: PlayerLayerHostView, coordinator: ()) {
        view.detach()
    }
}

/// The UIKit twin of the macOS host above, deliberately line-for-line the same
/// shape. It used to override `layerClass` so the `AVPlayerLayer` *was* the
/// view's layer — which cannot be given a frame independent of the view, and
/// so cannot be zoomed at all. It now holds a separate `AVPlayerLayer`
/// sublayer like macOS does. See the macOS branch for why the layer is
/// clipped, why the frame changes are non-animating, and why the video size
/// has to be observed rather than read once.
///
/// **The one thing that is not shared is the flip, and it is not shared
/// because it does not need to be.** A `UIView`'s layer measures sublayer
/// frames from the top left, which is the convention `layerFrame` is written
/// in, so this branch needs nothing. The macOS host overrides `isFlipped` to
/// reach the same convention from AppKit's bottom-left default — see the
/// measurement recorded there. The result is one geometry *contract* on both
/// platforms, arrived at two different ways; it was previously two opposite
/// contracts, which nothing on screen showed because `center.y == 0.5` is the
/// one value where the expression is symmetric.
final class PlayerLayerHostView: UIView {
    private let playerLayer = AVPlayerLayer()
    private var zoom = VideoZoom()
    private var itemObserver: NSKeyValueObservation?
    private var videoSizeObserver: NSKeyValueObservation?

    /// Which clip this view is drawing; see the macOS branch for why it is
    /// readable.
    var attachedPlayer: AVPlayer? { playerLayer.player }

    var playerLayerFrame: CGRect { playerLayer.frame }

    var appliedZoom: VideoZoom { zoom }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        playerLayer.videoGravity = .resizeAspect
        layer.masksToBounds = true
        layer.addSublayer(playerLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeLayer()
    }

    /// Ignores a zoom equal to the one already applied; see the macOS twin for
    /// why that means this is not a way to force a refresh.
    func apply(_ zoom: VideoZoom) {
        guard zoom != self.zoom else { return }
        self.zoom = zoom
        placeLayer()
    }

    func attach(_ player: AVPlayer) {
        if playerLayer.player !== player {
            playerLayer.player = player
            observeVideoSize(of: player)
        }
    }

    func detach() {
        playerLayer.player = nil
        itemObserver = nil
        videoSizeObserver = nil
    }

    private func placeLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = zoom.layerFrame(
            in: bounds.size,
            videoSize: playerLayer.player?.currentItem?.presentationSize ?? .zero
        )
        CATransaction.commit()
    }

    /// See the macOS twin for the whole argument. The two claims that matter
    /// here, stated at the strength they were measured at:
    ///
    /// - The **outer** `.initial`, on `\.currentItem`, is load-bearing and
    ///   measured — on macOS, by mutation:
    ///   `testTheLayerIsRePlacedWhenThePresentationSizeArrives` fails without
    ///   it. The iPad has no test of its own, so this branch inherits the
    ///   reasoning rather than the measurement.
    /// - The **inner** `.initial`, on `\.presentationSize`, is **not pinned by
    ///   any test on either platform**; it is kept on the argument set out on
    ///   the macOS twin, not on evidence that it fires. Do not delete it on the
    ///   grounds that the suite still passes — that is the documented starting
    ///   point, not new information.
    ///
    /// Neither hop may be "optimised" into reading `change.newValue`; the twin
    /// says why that is what makes them order-safe.
    private func observeVideoSize(of player: AVPlayer) {
        videoSizeObserver = nil
        itemObserver = player.observe(\.currentItem, options: [.initial, .new]) { [weak self, weak player] _, _ in
            Task { @MainActor in
                guard let self, let player, self.playerLayer.player === player else { return }
                self.observePresentationSize(of: player.currentItem)
            }
        }
    }

    private func observePresentationSize(of item: AVPlayerItem?) {
        guard let item else {
            videoSizeObserver = nil
            placeLayer()
            return
        }
        videoSizeObserver = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, let item, self.playerLayer.player?.currentItem === item else { return }
                self.placeLayer()
            }
        }
    }
}
#endif
