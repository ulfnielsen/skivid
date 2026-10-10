import SkiVideoCore
import SwiftUI

/// The macOS side of the `SecondaryScreenPresenter` seam. It owns the two
/// window controllers that `ContentView` used to hold directly; their
/// behaviour is unchanged.
@MainActor
final class MacSecondaryScreenPresenter: SecondaryScreenPresenter {
    // Constants: macOS has real windows for both screens, and `ContentView`
    // reads these while building `body` without observing this object.
    var canPresentComparison: Bool { true }
    var canPresentSorting: Bool { true }
    /// Both screens are separate windows; the viewer stays on screen and
    /// keyboard-live beside them. See the protocol requirement.
    var screensCoverTheViewer: Bool { false }
    /// Live, unlike the flags above; read only when an action needs it.
    var hasOpenWindow: Bool { comparisonWindow.isOpen || sortingWindow.isOpen }

    private let comparisonWindow = ComparisonWindowController()
    private let sortingWindow = SortingWindowController()

    func presentComparison(
        initialLeftVideo: URL?,
        openLibrary: [ComparisonAthleteChoice],
        prepare: ClipPreparer,
        onClose: @escaping () -> Void
    ) {
        comparisonWindow.show(
            initialLeftVideo: initialLeftVideo,
            openLibrary: openLibrary,
            prepare: prepare,
            onClose: onClose
        )
    }

    func presentSorting(
        destination: UploadLibraryChoice,
        openResizedLibrary: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    ) {
        sortingWindow.show(
            destination: destination,
            openResizedLibrary: openResizedLibrary,
            onClose: onClose
        )
    }
}
