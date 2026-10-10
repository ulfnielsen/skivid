import SkiVideoCore
import SwiftUI
import UIKit

@main
struct SkiVideoViewerApp_iOS: App {
    init() {
        // One binary, two devices. Core cannot ask which — see `LocalSource` —
        // so the app tells it, once, before anything renders a sentence with
        // the device's name in it.
        LocalSource.deviceName = UIDevice.current.userInterfaceIdiom == .phone ? "iPhone" : "iPad"
        // Photos copies from a session that was killed, or closed while resizes
        // were running, are still in Caches. Nothing from a previous launch can
        // be reading them, so launch is the one moment this is always safe.
        PhotosClipExporter().clear()
        #if DEBUG
        // Before the models below exist: their stores must already point at
        // the UI test's throwaway ones.
        if UITestPhotosToDriveSeam.isActive { UITestPhotosToDriveSeam.isolateStorage() }
        #endif
    }

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
            #if DEBUG
            .task {
                if UITestPhotosToDriveSeam.isActive { await UITestPhotosToDriveSeam.openFakeDrive(in: model) }
            }
            #endif
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
            .fullScreenCover(item: $secondaryScreens.sorting) { request in
                SortingSheet(
                    // `SortingSheet` speaks `isPresented`, not `closeWindow`
                    // like `ComparisonView` — this binding is what lets its
                    // own Cancel / Open Resized Library buttons close the
                    // cover the same way clearing `secondaryScreens.sorting`
                    // does everywhere else.
                    isPresented: Binding(
                        get: { secondaryScreens.sorting != nil },
                        set: { isPresented in
                            if !isPresented { secondaryScreens.dismissSorting() }
                        }
                    ),
                    openResizedLibrary: request.openResizedLibrary,
                    mediaPipeline: AVFoundationMediaPipeline(),
                    // Same inert source as Compare, for the same reason:
                    // Phase 4 owns iPad input, so this screen is driven by its
                    // on-screen controls only, same as the Mac's arrow-key
                    // shortcuts are simply absent here rather than emulated.
                    input: InertInputSource(),
                    folderPicker: UIKitFolderPicker(),
                    // `~/Ski/athletes.txt` is a macOS convention; iPadOS has no
                    // equivalent default location, so autocomplete starts
                    // empty until the coach picks a names file explicitly —
                    // `destination`'s roster below is what fills it instead.
                    defaultNamesURL: nil,
                    // The "Upload to" choice, forwarded from
                    // `IOSSecondaryScreenPresenter.SortingRequest` — see
                    // `ContentView.presentSortingScreen`, which builds it.
                    destination: request.destination,
                    // The one pairing this initializer exists to make explicit:
                    // an iPad's source is a Files location — very often the SD
                    // card itself — so this session must never write into it.
                    keepsSourceIntact: true,
                    outputRoot: Self.sortingOutputRoot,
                    // Copies land in Caches, never under `outputRoot`: the
                    // resized, tagged clips outlive the sort, the copies do not.
                    photosImporter: Self.makePhotosImporter()
                )
                #if DEBUG
                .overlay(alignment: .top) {
                    if UITestPhotosToDriveSeam.isActive {
                        FakeClubDriveReadout(log: UITestPhotosToDriveSeam.drive.log)
                    }
                }
                #endif
            }
        }
    }

    private static var sortingOutputRoot: URL {
        #if DEBUG
        if UITestPhotosToDriveSeam.isActive { return UITestPhotosToDriveSeam.outputRoot }
        #endif
        return SortingModel.defaultOutputRoot()
    }

    @MainActor private static func makePhotosImporter() -> PhotosImporting {
        #if DEBUG
        // PHPicker runs out of process and XCUITest cannot drive it; see
        // `UITestPhotosToDriveSeam`.
        if UITestPhotosToDriveSeam.isActive { return UITestPhotosToDriveSeam.photosImporter() }
        #endif
        return PHPickerPhotosImporter()
    }
}
