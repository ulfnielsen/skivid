import SkiVideoCore
import SwiftUI

@main
struct SkiVideoViewerApp_iOS: App {
    @StateObject private var model = ViewerModel(
        input: InertInputSource(),
        folderPicker: UIKitFolderPicker(),
        oauthPresenter: UnavailableOAuthPresenter()
    )
    private let secondaryScreens = NoSecondaryScreenPresenter()

    var body: some Scene {
        WindowGroup {
            ContentView(
                model: model,
                initialDirectory: nil,
                secondaryScreens: secondaryScreens
            )
        }
    }
}
