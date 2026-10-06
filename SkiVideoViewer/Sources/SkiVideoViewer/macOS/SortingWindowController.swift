import AppKit
import SkiVideoCore
import SwiftUI

final class SortingWindowController: NSObject, ObservableObject, NSWindowDelegate {
    private var window: NSWindow?
    private var closingWindows: [NSWindow] = []
    private var onClose: (() -> Void)?

    /// `@MainActor` because it now builds the two `@MainActor` seam instances
    /// the sorting model needs. Every caller is already on the main actor.
    ///
    /// `libraryAthletes` comes from the already-open `ViewerModel.athletes` —
    /// see `MacSecondaryScreenPresenter.presentSorting`. If a window is
    /// already showing, this call's names are dropped along with its other
    /// parameters; that mirrors the existing early return below and is not
    /// new to this change.
    @MainActor
    func show(
        libraryAthletes: [AthleteGroup],
        upload: Result<UploadTarget, UploadRefusal>,
        openResizedLibrary: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    ) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        self.onClose = onClose
        let presented = Binding<Bool>(
            get: { [weak self] in self?.window != nil },
            set: { [weak self] isPresented in
                if !isPresented {
                    self?.window?.performClose(nil)
                }
            }
        )
        // The sorting sheet keeps focus in the athlete field, so its arrows have
        // to reach the model through the field editor. Scoped to this instance:
        // the viewer's own input source keeps the exemption.
        let input = AppKitInputSource()
        input.arrowsBypassTextFieldFocus = true
        // Also scoped to this instance: holding ←/→ here fast-scans the clip at
        // the key-repeat rate, as the sorting window's own monitor did. Safe
        // because `SortingModel`'s ±5s seek is stateless. The viewer must keep
        // suppressing repeats or its double-tap detector runs away — see
        // `arrowsRepeat`.
        input.arrowsRepeat = true
        let rootView = SortingSheet(
            isPresented: presented,
            openResizedLibrary: openResizedLibrary,
            mediaPipeline: AVFoundationMediaPipeline(),
            input: input,
            folderPicker: AppKitFolderPicker(),
            // The macOS convention the model used to hardcode. The core cannot
            // assume a home-directory layout, so the platform supplies it.
            defaultNamesURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Ski/athletes.txt"),
            libraryAthletes: libraryAthletes,
            upload: upload,
            // Unchanged Mac behaviour: the source is a folder on this Mac, not
            // a card, so the session still organizes it in place.
            // `outputRoot` is passed for the pairing's sake even though it is
            // ignored while `keepsSourceIntact` is false.
            keepsSourceIntact: false,
            outputRoot: SortingModel.defaultOutputRoot()
        )
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sort & Resize Videos"
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: rootView)
        window.delegate = self
        self.window = window
        // Fill the usable display area while retaining the normal macOS title bar.
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
