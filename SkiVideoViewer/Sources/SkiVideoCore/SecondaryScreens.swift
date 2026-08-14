import Foundation

/// Presents the Compare and Sort screens. macOS opens real `NSWindow`s; iPadOS
/// uses a full-screen cover. `ContentView` consults these flags so a platform
/// that cannot show a screen simply hides its button rather than offering a
/// dead control.
///
/// One flag per screen, not one for both: iPad can present Compare but not
/// Sort. The media pipeline is no longer the obstacle — it runs in-process on
/// AVFoundation and compiles for iOS — but no iPad sorting UI has been built,
/// so there is still nothing to present. A single flag would force the two to
/// be revealed together.
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

    func presentSorting(
        openResizedLibrary: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    )
}
