import SkiVideoCore
import SwiftUI

@main
struct SkiVideoViewerApp_iOS: App {
    @StateObject private var model = ViewerModel(
        input: InertInputSource(),
        folderPicker: UIKitFolderPicker(),
        oauthPresenter: IOSOAuthPresenter()
    )
    // A @StateObject, not a `let`: this scene has to re-render when the
    // presenter publishes a comparison request, which is what drives the cover.
    // ContentView still takes it as a plain `SecondaryScreenPresenter` and does
    // not observe it — its toolbar flags are constants.
    @StateObject private var secondaryScreens = IOSSecondaryScreenPresenter()

    var body: some Scene {
        WindowGroup {
            ContentView(
                model: model,
                initialDirectory: nil,
                secondaryScreens: secondaryScreens
            )
            .fullScreenCover(item: $secondaryScreens.comparison) { request in
                ComparisonView(
                    initialLeftVideo: request.initialLeftVideo,
                    openLibrary: request.openLibrary,
                    // Phase 4 owns iPad input. Until then the comparison screen
                    // is driven only by its on-screen controls, matching the
                    // main viewer, which uses the same inert source.
                    input: InertInputSource(),
                    folderPicker: UIKitFolderPicker(),
                    prepare: request.prepare,
                    closeWindow: { secondaryScreens.dismissComparison() }
                )
            }
        }
    }
}
