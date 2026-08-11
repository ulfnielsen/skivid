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

    override func layout() {
        super.layout()
        placeLayer()
    }

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
    /// `.initial` on each covers the case where the value is already there.
    /// `ComparisonModel.observeDuration` is the same pattern for the same
    /// reason, including the staleness guard: KVO can deliver for a player or
    /// item this view has already moved on from.
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
/// sublayer like macOS does, so both platforms have exactly one geometry path
/// and the comments above apply verbatim: see the macOS branch for why the
/// layer is clipped, why the frame changes are non-animating, and why the
/// video size has to be observed rather than read once.
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
