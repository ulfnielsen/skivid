import AppKit
import SkiVideoCore
import UniformTypeIdentifiers

/// Translates folder/file selection into `NSOpenPanel` presentations. This is
/// the macOS half of the `FolderPicker` seam.
///
/// Not unit-tested: `NSOpenPanel.runModal()` blocks waiting for a human, so a
/// test that calls it would hang the suite forever. Its behaviour is covered
/// indirectly through `FakeFolderPicker` in the tests of the code that calls
/// it, and by the phase 3 XCUITest.
@MainActor
final class AppKitFolderPicker: FolderPicker {
    func pickFolder(startingAt: URL?) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose organized video directory"
        panel.prompt = "Open"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = startingAt
        return panel.runModal() == .OK ? panel.url : nil
    }

    func pickFile(ofType type: UTType, title: String) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [type]
        return panel.runModal() == .OK ? panel.url : nil
    }
}
