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
        prepare: @escaping (ComparisonVideoChoice) async -> URL?,
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
        libraryAthletes: [AthleteGroup],
        openResizedLibrary: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    ) {
        sortingWindow.show(
            libraryAthletes: libraryAthletes,
            openResizedLibrary: openResizedLibrary,
            onClose: onClose
        )
    }
}
