import AVFoundation
import SwiftUI

/// One `AVPlayer` rendered by an `AVPlayerLayer`, with no transport controls.
/// The overlay stacks two of these, so it needs a bare layer rather than the
/// full player controller `NativePlayerView` provides.
///
/// `resizeAspect`, not `resizeAspectFill`: the overlay compares two clips, and
/// cropping either one would make the comparison lie. Phase 3 established the
/// same rule for the main viewer on iPad.
struct SinglePlayerView: View {
    let player: AVPlayer

    var body: some View {
        PlayerLayerRepresentable(player: player)
    }
}

#if os(macOS)
import AppKit

private struct PlayerLayerRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.attach(player)
        return view
    }

    func updateNSView(_ view: PlayerLayerHostView, context: Context) {
        view.attach(player)
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
        host.addSublayer(playerLayer)
    }

    override func layout() {
        super.layout()
        // Layer frame changes animate implicitly, which lags the video during a
        // window resize. Apply them immediately.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func attach(_ player: AVPlayer) {
        if playerLayer.player !== player {
            playerLayer.player = player
        }
    }

    func detach() {
        playerLayer.player = nil
    }
}
#else
import UIKit

private struct PlayerLayerRepresentable: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.attach(player)
        return view
    }

    func updateUIView(_ view: PlayerLayerHostView, context: Context) {
        view.attach(player)
    }

    // Same rule as the macOS branch: detach on teardown so a discarded view's
    // layer stops holding the player.
    static func dismantleUIView(_ view: PlayerLayerHostView, coordinator: ()) {
        view.detach()
    }
}

final class PlayerLayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    /// Which clip this view is drawing; see the macOS branch for why it is
    /// readable.
    var attachedPlayer: AVPlayer? { playerLayer.player }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        playerLayer.videoGravity = .resizeAspect
    }

    func attach(_ player: AVPlayer) {
        if playerLayer.player !== player {
            playerLayer.player = player
        }
    }

    func detach() {
        playerLayer.player = nil
    }
}
#endif
