import Foundation

/// Presents the Compare and Sort screens. macOS opens real `NSWindow`s; iPadOS
/// uses a full-screen cover. `ContentView` consults these flags so a platform
/// that cannot show a screen simply hides its button rather than offering a
/// dead control.
///
/// One flag per screen, not one for both: the two screens were built and
/// enabled on separate schedules, so a single flag would have forced them to
/// be revealed together. Both are now true on every platform this app ships —
/// iPad presents Compare and Sort exactly as macOS does, with
/// `SortingModel.keepsSourceIntact` steering the latter away from writing to
/// the source when it is backed by a card in the camera rather than a folder
/// on disk.
///
/// Both flags must be answered by a constant. `ContentView` reads them while
/// building `body` and does not observe the presenter, so a value computed from
/// runtime state would never reach the toolbar.
@MainActor
public protocol SecondaryScreenPresenter: AnyObject {
    var canPresentComparison: Bool { get }
    var canPresentSorting: Bool { get }

    /// `prepare` is how a pane materialises a cloud clip it was just handed.
    /// This protocol only forwards it — see `ClipPreparer`, which carries the
    /// whole rationale, including why it is a closure and not a `ViewerModel`.
    func presentComparison(
        initialLeftVideo: URL?,
        openLibrary: [ComparisonAthleteChoice],
        prepare: ClipPreparer,
        onClose: @escaping () -> Void
    )

    /// `libraryAthletes` is the open library's roster — `ViewerModel.athletes`
    /// — passed the same way `presentComparison`'s `openLibrary` is: `ContentView`
    /// is the only thing that reads `ViewerModel` directly, so this is how its
    /// athletes reach `SortingModel` without `SortingSheet` or either window
    /// controller learning what a `ViewerModel` is.
    func presentSorting(
        libraryAthletes: [AthleteGroup],
        openResizedLibrary: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    )
}
