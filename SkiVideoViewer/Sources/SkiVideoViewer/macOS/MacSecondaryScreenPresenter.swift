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

    private let comparisonWindow = ComparisonWindowController()
    private let sortingWindow = SortingWindowController()

    func presentComparison(
        initialLeftVideo: URL?,
        openLibrary: [ComparisonAthleteChoice],
        onClose: @escaping () -> Void
    ) {
        comparisonWindow.show(
            initialLeftVideo: initialLeftVideo,
            openLibrary: openLibrary,
            onClose: onClose
        )
    }

    func presentSorting(
        openResizedLibrary: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    ) {
        sortingWindow.show(
            openResizedLibrary: openResizedLibrary,
            onClose: onClose
        )
    }
}
