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

    /// Whether Compare and Sort take the viewer's place while they are up.
    ///
    /// True on iPad and iPhone, where both are full-screen covers: the viewer
    /// is not on screen to receive a key, so `ContentView` switches its
    /// keyboard controls off for the duration and back on at `onClose`.
    ///
    /// False on macOS, where each opens in a window of its own beside the
    /// viewer's. The viewer must keep playing on Space there while either is
    /// open, so its controls stay on; what keeps three live sources from
    /// answering each other's keys is that every one is scoped to its own
    /// window (`AppKitInputSource.ownWindow`). Switching the viewer off was
    /// exactly why Space did nothing in it while the sorting window was open.
    ///
    /// A constant, like the two flags above, for the same reason.
    var screensCoverTheViewer: Bool { get }

    /// Read when an action needs it, never while building `body` — the
    /// presenter is not observed. True while a comparison or sorting
    /// window holds clip paths that a library change would invalidate.
    ///
    /// Unlike the flags above this is live state, which is exactly why it
    /// may only be read at the moment of an action: `ContentView` asks it
    /// when "Rename Event…" is chosen, and refuses while it is true.
    var hasOpenWindow: Bool { get }

    /// `prepare` is how a pane materialises a cloud clip it was just handed.
    /// This protocol only forwards it — see `ClipPreparer`, which carries the
    /// whole rationale, including why it is a closure and not a `ViewerModel`.
    func presentComparison(
        initialLeftVideo: URL?,
        openLibrary: [ComparisonAthleteChoice],
        prepare: ClipPreparer,
        onClose: @escaping () -> Void
    )

    /// `destination` is the screen's "Upload to" choice, and through it the
    /// roster of whatever library is open — built by `ContentView`, the only
    /// thing that reads `ViewerModel` directly, out of closures, so neither
    /// `SortingSheet` nor either window controller learns what a
    /// `ViewerModel` is. It says, before any tagging, where tagged clips will
    /// upload or why they cannot. Sorting itself works either way.
    func presentSorting(
        destination: UploadLibraryChoice,
        openResizedLibrary: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    )
}
