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
        controller.videoGravity = .resizeAspectFill
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}
