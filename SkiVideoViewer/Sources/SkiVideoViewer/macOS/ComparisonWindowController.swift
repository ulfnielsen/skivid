import AppKit
import SkiVideoCore
import SwiftUI

final class ComparisonWindowController: NSObject, ObservableObject, NSWindowDelegate {
    /// Readable for tests; only this controller sets it.
    private(set) var window: NSWindow?
    /// The source handed to this window's model, kept so a test can check
    /// what it is scoped to. Weak: the model owns it.
    private(set) weak var inputSource: AppKitInputSource?
    private var closingWindows: [NSWindow] = []
    private var onClose: (() -> Void)?

    /// `@MainActor` because it now builds the two `@MainActor` seam instances
    /// the comparison model needs. Every caller is already on the main actor.
    @MainActor
    func show(
        initialLeftVideo: URL?,
        openLibrary: [ComparisonAthleteChoice],
        prepare: ClipPreparer,
        onClose: @escaping () -> Void
    ) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        self.onClose = onClose
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let input = AppKitInputSource()
        let root = ComparisonView(
            initialLeftVideo: initialLeftVideo,
            openLibrary: openLibrary,
            input: input,
            folderPicker: AppKitFolderPicker(),
            prepare: prepare
        ) { [weak window] in
            window?.performClose(nil)
        }
        window.title = "Compare Videos"
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.delegate = self
        self.window = window
        inputSource = input
        // The viewer stays keyboard-live beside this window, so this source
        // must only hear keys typed here — see `AppKitInputSource.ownWindow`.
        input.ownWindow = window
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        closingWindow.delegate = nil
        closingWindows.append(closingWindow)
        if window === closingWindow {
            window = nil
        }
        let callback = onClose
        onClose = nil
        callback?()
        // Keep the window alive until AppKit has finished its closing transaction.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, closingWindow] in
            self?.closingWindows.removeAll { $0 === closingWindow }
        }
    }
}
