import Foundation

/// Presents the Compare and Sort screens. macOS opens real `NSWindow`s; iPadOS
/// will use full-screen covers in a later phase. `ContentView` consults
/// `canPresent` so a platform that cannot yet show them simply hides the
/// buttons rather than offering a dead control.
@MainActor
public protocol SecondaryScreenPresenter: AnyObject {
    var canPresent: Bool { get }

    func presentComparison(
        initialLeftVideo: URL?,
        openLibrary: [ComparisonAthleteChoice],
        onClose: @escaping () -> Void
    )

    func presentSorting(
        openResizedLibrary: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    )
}
