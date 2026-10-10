import Foundation
import SkiVideoCore

/// iPad has no separate windows, so Compare and Sort & Resize are both
/// full-screen covers: this object publishes the request and
/// `SkiVideoViewerApp_iOS` renders it.
///
/// Sort now works on iPad. Its pipeline, `AVFoundationMediaPipeline`, runs
/// in-process and compiles for iOS; its screen, `SortingSheet`, is plain
/// SwiftUI with no AppKit dependency, unlike the `SortingWindowController`
/// that hosts the same view on macOS. An iPad session's source is a Files
/// location — very often the SD card still holding the only copy of a
/// training session — so the session built here sets
/// `SortingModel.keepsSourceIntact = true` and pairs it with `.outputRoot`,
/// which writes resizes into the app's own storage instead of moving a
/// coach's originals out of wherever they came from.
///
/// Both flags are constants on purpose: `ContentView` reads them while building
/// `body` and does not observe this object, so a value that changed at runtime
/// would never reach the toolbar.
@MainActor
final class IOSSecondaryScreenPresenter: ObservableObject, SecondaryScreenPresenter {
    /// `Identifiable` because `fullScreenCover(item:)` needs it. The identity is
    /// per-request, so a second Compare after a dismiss presents again.
    struct ComparisonRequest: Identifiable {
        let id = UUID()
        let initialLeftVideo: URL?
        let openLibrary: [ComparisonAthleteChoice]
        let prepare: ClipPreparer
        let onClose: () -> Void
    }

    /// `Identifiable` for the same reason as `ComparisonRequest`, and, like it,
    /// carries no `SortingModel` of its own — `SkiVideoViewerApp_iOS` builds
    /// `SortingSheet` (and the `SortingModel` inside it) when this request is
    /// consumed, passing `keepsSourceIntact: true` and `outputRoot:` into its
    /// initializer so both are set before anything is presented.
    struct SortingRequest: Identifiable {
        let id = UUID()
        let libraryAthletes: [AthleteGroup]
        let upload: Result<UploadTarget, UploadRefusal>
        let openResizedLibrary: (URL) -> Void
        let onClose: () -> Void
    }

    @Published var comparison: ComparisonRequest?
    @Published var sorting: SortingRequest?

    var canPresentComparison: Bool { true }
    var canPresentSorting: Bool { true }
    /// Both screens are full-screen covers. See the protocol requirement.
    var screensCoverTheViewer: Bool { true }

    func presentComparison(
        initialLeftVideo: URL?,
        openLibrary: [ComparisonAthleteChoice],
        prepare: ClipPreparer,
        onClose: @escaping () -> Void
    ) {
        comparison = ComparisonRequest(
            initialLeftVideo: initialLeftVideo,
            openLibrary: openLibrary,
            prepare: prepare,
            onClose: onClose
        )
    }

    func presentSorting(
        libraryAthletes: [AthleteGroup],
        upload: Result<UploadTarget, UploadRefusal>,
        openResizedLibrary: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    ) {
        sorting = SortingRequest(
            libraryAthletes: libraryAthletes,
            upload: upload,
            openResizedLibrary: openResizedLibrary,
            onClose: onClose
        )
    }

    /// Clears the cover and then runs the request's `onClose`, which is what
    /// re-enables the viewer's keyboard controls. Ordering matters only in that
    /// `onClose` must run exactly once — reading the request before clearing
    /// makes a second `dismissComparison` a no-op.
    func dismissComparison() {
        let request = comparison
        comparison = nil
        request?.onClose()
    }

    /// Mirrors `dismissComparison`: clear first, then run `onClose` exactly
    /// once so a second `dismissSorting` (SwiftUI can call the cover's
    /// dismissal path more than once) is a no-op.
    func dismissSorting() {
        let request = sorting
        sorting = nil
        request?.onClose()
    }
}
