import SkiVideoCore
import UIKit
import UniformTypeIdentifiers

/// iPad counterpart of `AppKitFolderPicker`. `UIDocumentPickerViewController`
/// is delegate-based, so the continuation is resumed from the delegate and
/// guarded against a double resume — the picker can report both a selection
/// and a cancellation if it is dismissed while a choice is in flight.
///
/// `title` and `confirmLabel` are dropped: the document browser owns its own
/// navigation bar and accept button, and the `FolderPicker` doc comment says a
/// platform without a prompt may ignore them.
///
/// Not unit-tested: presenting requires a live foreground window scene, and no
/// test target compiles this file — `Package.swift` excludes
/// `Sources/SkiVideoViewer/iOS`, and the iOS test scheme covers `SkiVideoCore`
/// only. Task 6's simulator run exercises it.
@MainActor
final class UIKitFolderPicker: NSObject, FolderPicker {
    private let access = SecurityScopedFolderAccess()
    private var continuation: CheckedContinuation<URL?, Never>?
    /// Identifies whose callback the pending continuation belongs to, so a
    /// late callback from a superseded picker cannot resume the wrong await.
    private weak var activePicker: UIDocumentPickerViewController?

    func pickFolder(startingAt: URL?, title: String, confirmLabel: String) async -> URL? {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.directoryURL = startingAt
        guard let url = await present(picker) else { return nil }
        // Without the scope the URL is unreadable, so a scan would report an
        // empty folder rather than a failure. Reporting nil instead makes the
        // caller treat it as a cancelled pick and keep the folder it has.
        guard access.begin(url) else { return nil }
        return url
    }

    func pickFile(ofType type: UTType, title: String) async -> URL? {
        // Deliberately unscoped: the reachable caller stores `url.path` in
        // UserDefaults and reopens it much later, which a scope held here
        // would not cover anyway. See the task 5 report — this needs a
        // security-scoped bookmark, not a scope, before Drive works on iPad.
        await present(UIDocumentPickerViewController(forOpeningContentTypes: [type]))
    }

    private func present(_ picker: UIDocumentPickerViewController) async -> URL? {
        guard let presenter = Self.topViewController() else { return nil }
        picker.allowsMultipleSelection = false
        picker.delegate = self
        return await withCheckedContinuation { continuation in
            // A pick already in flight would otherwise be overwritten and
            // never resumed, hanging its caller forever. Resolving it as a
            // cancel is the only safe handling.
            finish(nil)
            self.continuation = continuation
            self.activePicker = picker
            presenter.present(picker, animated: true)
        }
    }

    /// Resumes at most once. Niling first is what makes a second delegate
    /// callback a no-op instead of a double resume, which traps.
    private func finish(_ url: URL?) {
        guard let continuation else { return }
        self.continuation = nil
        self.activePicker = nil
        continuation.resume(returning: url)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        // The first folder pick is kicked off from `ContentView.onAppear`,
        // which can run before the scene reaches `.foregroundActive`. Falling
        // back to any scene with a key window keeps that pick from silently
        // resolving to nil.
        let scene = scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.keyWindow != nil }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

extension UIKitFolderPicker: UIDocumentPickerDelegate {
    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard controller === activePicker else { return }
        finish(urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard controller === activePicker else { return }
        finish(nil)
    }
}
