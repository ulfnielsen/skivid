import SkiVideoCore
import UniformTypeIdentifiers

/// Stub so the iPad target builds at the end of task 4. Task 5 replaces
/// this with a real UIDocumentPickerViewController plus security-scoped
/// access. Returning nil means "user cancelled", which every caller
/// already handles.
@MainActor
final class UIKitFolderPicker: FolderPicker {
    func pickFolder(startingAt: URL?, title: String, confirmLabel: String) async -> URL? { nil }
    func pickFile(ofType type: UTType, title: String) async -> URL? { nil }
}
