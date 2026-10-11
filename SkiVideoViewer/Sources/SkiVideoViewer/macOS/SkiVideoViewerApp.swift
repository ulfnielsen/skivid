import AppKit
import SkiVideoCore
import SwiftUI

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    /// Set by `SkiVideoViewerApp` once its window is up; the delegate is
    /// created by SwiftUI and has no other way to reach the model.
    var beforeQuit: (() -> Void)?

    /// Quitting does not take the scene through `.background`, so
    /// `ContentView`'s save on a phase change never runs on ⌘Q, and the
    /// debounced save is cancelled with the process: the last mark, and any
    /// label being typed, would be lost.
    func applicationWillTerminate(_ notification: Notification) {
        beforeQuit?()
    }

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
    @StateObject private var model: ViewerModel
    /// The viewer's keyboard source, kept so its window can be named once
    /// SwiftUI has built it — see `HostWindowReader` below.
    private let viewerInput: AppKitInputSource
    private let initialDirectory: URL?
    private let secondaryScreens = MacSecondaryScreenPresenter()
    /// Owned here rather than by `ContentView` so the delegate's quit hook can
    /// commit a label being typed.
    private let drawingTyping = DrawingTyping()

    init() {
        let input = AppKitInputSource()
        viewerInput = input
        _model = StateObject(wrappedValue: ViewerModel(
            input: input,
            folderPicker: AppKitFolderPicker(),
            // Not AppKitOAuthPresenter directly: that one only speaks loopback,
            // which the built-in Desktop client uses but a club-supplied iOS
            // client is forbidden. MacOAuthPresenter picks between the two.
            oauthPresenter: MacOAuthPresenter()
        ))
        if let argument = CommandLine.arguments.dropFirst().first {
            let expanded = NSString(string: argument).expandingTildeInPath
            initialDirectory = URL(fileURLWithPath: expanded, isDirectory: true)
        } else {
            initialDirectory = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                model: model,
                initialDirectory: initialDirectory,
                secondaryScreens: secondaryScreens,
                drawingTyping: drawingTyping
            )
            .onAppear {
                applicationDelegate.beforeQuit = { [model, drawingTyping] in
                    drawingTyping.keepAndSave(model.drawing)
                }
            }
            // The viewer's source stays enabled while the sorting and
            // comparison windows are open, so it is scoped to the viewer's
            // own window, as theirs are to theirs — see
            // `AppKitInputSource.ownWindow`. A nil (the view leaving its
            // window) is ignored: the weak reference already lets go, and the
            // source then handles nothing until a window is named again.
            .background(HostWindowReader { window in
                if let window { viewerInput.ownWindow = window }
            })
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
