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

    /// `prepare` is how a pane materialises a cloud clip it was just handed:
    /// called with the choice the operator picked, it returns the local file
    /// URL once the bytes are on disk, or nil if they could not be fetched —
    /// in which case the caller falls back to the choice's own `playbackURL`.
    ///
    /// A closure rather than a `ViewerModel` reference, deliberately.
    /// `ComparisonModel` already has an overload that takes a `ViewerModel`
    /// directly (`load(_:side:fetching:)`), but wiring *that* into the UI
    /// would mean every step from here down to `ClipSourceMenu` — in
    /// `Sources/SkiVideoViewer/Shared`, compiled for both platforms — would
    /// have to learn what a `ViewerModel` is, purely to hand one along.
    /// `ContentView` is the only thing that captures `ViewerModel.prepareClip`
    /// into this shape; every step between here and where a pane's clip is
    /// actually chosen just forwards the closure unopened.
    func presentComparison(
        initialLeftVideo: URL?,
        openLibrary: [ComparisonAthleteChoice],
        prepare: @escaping (ComparisonVideoChoice) async -> URL?,
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
