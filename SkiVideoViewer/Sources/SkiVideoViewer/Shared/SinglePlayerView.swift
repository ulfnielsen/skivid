import AVFoundation
import SkiVideoCore
import SwiftUI

/// One `AVPlayer` rendered by an `AVPlayerLayer`, with no transport controls.
/// The overlay stacks two of these, so it needs a bare layer rather than the
/// full player controller `NativePlayerView` provides.
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
    /// whole of the zoom behaviour, and pixels cannot answer "did it zoom".
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
    /// rather than assumed alongside it: the flip moves the layer's *frame*
    /// without turning the video content upside down (at 1x the white band
    /// stays at the top of the pane in both variants, 191 vs 0), and
    /// `layer.isGeometryFlipped = true` — the other obvious candidate — does
    /// **nothing** here, giving byte-identical readings to the unflipped case,
    /// because AppKit owns the backing layer's geometry for a layer-backed
    /// view and overwrites it.
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
    /// **`.initial` on each is load-bearing, not belt and braces.** The models
    /// own long-lived players and load clips into them; the SwiftUI view is
    /// built — and rebuilt on every navigation — afterwards, so `attach`
    /// normally arrives at a player whose item already has a real size and
    /// which will never post a change. Dropping either `.initial` leaves every
    /// already-loaded clip on the pane fallback for good.
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

    /// See the macOS twin: both `.initial` options are load-bearing, and
    /// neither hop may be "optimised" into reading `change.newValue`.
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
