import Foundation
import SkiVideoCore

/// Compare and Sort reach iPad in phase 5. Reporting `canPresent == false`
/// makes `ContentView` hide their toolbar buttons rather than offering
/// controls that do nothing. `canPresent` is a constant on purpose:
/// `ContentView` reads it while building `body` and this presenter is not
/// observable, so a value that changed at runtime would never reach the
/// toolbar.
@MainActor
final class NoSecondaryScreenPresenter: SecondaryScreenPresenter {
    var canPresent: Bool { false }

    func presentComparison(
        initialLeftVideo: URL?,
        openLibrary: [ComparisonAthleteChoice],
        onClose: @escaping () -> Void
    ) {}

    func presentSorting(
        openResizedLibrary: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    ) {}
}
