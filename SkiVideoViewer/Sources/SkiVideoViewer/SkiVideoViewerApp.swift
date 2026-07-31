import AppKit
import SwiftUI

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let iconURL = Bundle.main.url(forResource: "AlbisViewerIcon", withExtension: "png"),
              let icon = NSImage(contentsOf: iconURL) else {
            return
        }
        NSApp.applicationIconImage = icon
    }
}

@main
struct SkiVideoViewerApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @StateObject private var model = ViewerModel(
        input: AppKitInputSource(),
        folderPicker: AppKitFolderPicker(),
        oauthPresenter: AppKitOAuthPresenter()
    )
    private let initialDirectory: URL?

    init() {
        if let argument = CommandLine.arguments.dropFirst().first {
            let expanded = NSString(string: argument).expandingTildeInPath
            initialDirectory = URL(fileURLWithPath: expanded, isDirectory: true)
        } else {
            initialDirectory = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, initialDirectory: initialDirectory)
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") {
                    Task { await model.chooseDirectory() }
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
