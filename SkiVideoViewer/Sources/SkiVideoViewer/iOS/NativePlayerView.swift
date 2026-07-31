import AVKit
import SwiftUI

/// iPad counterpart of the macOS `NativePlayerView`. Same name and the same
/// `init(player:)`, so `ContentView` is identical on both platforms.
/// Controls are hidden because the app supplies its own transport row.
struct NativePlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        // .resizeAspect, not the macOS view's .resizeAspectFill. The Mac
        // window's minimum aspect (980/640 ≈ 1.53) is close enough to 16:9
        // that fill crops a sliver; an iPad detail pane in portrait is about
        // 0.65, where fill would scale to the height and throw away roughly
        // 63% of the frame width (~34% in landscape). A skier leaving the
        // visible frame defeats the point of a coaching viewer, so letterbox
        // instead of crop.
        controller.videoGravity = .resizeAspect
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}
