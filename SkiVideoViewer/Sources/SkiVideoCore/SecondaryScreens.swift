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
