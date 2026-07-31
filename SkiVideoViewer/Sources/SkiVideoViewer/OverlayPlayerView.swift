import AVFoundation
import AppKit
import CoreImage
import SwiftUI

/// Draws two players into the same rect: `bottomPlayer` underneath,
/// `topPlayer` on top. Both use aspect-fit so neither clip is cropped and
/// both occupy the same frame. There is deliberately no spatial alignment.
struct OverlayPlayerView: NSViewRepresentable {
    let bottomPlayer: AVPlayer
    let topPlayer: AVPlayer
    let topOpacity: Double
    let blend: OverlayBlend

    func makeNSView(context: Context) -> OverlayPlayerNSView {
        let view = OverlayPlayerNSView()
        view.attach(bottomPlayer: bottomPlayer, topPlayer: topPlayer)
        view.apply(topOpacity: topOpacity, blend: blend)
        return view
    }

    func updateNSView(_ view: OverlayPlayerNSView, context: Context) {
        view.attach(bottomPlayer: bottomPlayer, topPlayer: topPlayer)
        view.apply(topOpacity: topOpacity, blend: blend)
    }

    static func dismantleNSView(_ view: OverlayPlayerNSView, coordinator: ()) {
        view.detachPlayers()
    }
}

final class OverlayPlayerNSView: NSView {
    private let bottomLayer = AVPlayerLayer()
    private let topLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayers()
    }

    private func configureLayers() {
        wantsLayer = true
        let host = layer ?? CALayer()
        layer = host
        host.backgroundColor = NSColor.black.cgColor
        for playerLayer in [bottomLayer, topLayer] {
            playerLayer.videoGravity = .resizeAspect
            playerLayer.frame = bounds
            host.addSublayer(playerLayer)
        }
    }

    override func layout() {
        super.layout()
        // Layer frame changes are implicitly animated by default, which makes
        // window resizing lag the video. Apply them without animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bottomLayer.frame = bounds
        topLayer.frame = bounds
        CATransaction.commit()
    }

    func attach(bottomPlayer: AVPlayer, topPlayer: AVPlayer) {
        if bottomLayer.player !== bottomPlayer {
            bottomLayer.player = bottomPlayer
        }
        if topLayer.player !== topPlayer {
            topLayer.player = topPlayer
        }
    }

    func detachPlayers() {
        bottomLayer.player = nil
        topLayer.player = nil
    }

    func apply(topOpacity: Double, blend: OverlayBlend) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch blend {
        case .blend:
            topLayer.compositingFilter = nil
            topLayer.opacity = Float(max(0, min(1, topOpacity)))
        case .difference:
            // CIFilter(name:) is optional; if the filter is unavailable we fall
            // back to an ordinary full-opacity draw rather than crashing.
            topLayer.compositingFilter = CIFilter(name: "CIDifferenceBlendMode")
            topLayer.opacity = 1
        }
        CATransaction.commit()
    }
}
