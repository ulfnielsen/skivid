import Foundation
import SkiVideoCore

/// iPad has no separate windows, so Compare is a full-screen cover: this object
/// publishes the request and `SkiVideoViewerApp_iOS` renders it.
///
/// Sort stays unavailable, but no longer for the reason it once was: the
/// pipeline it drives is `AVFoundationMediaPipeline`, which runs in-process and
/// compiles for iOS. What is missing is the sorting UI itself — the screen is
/// built around a Mac window and a folder picker that have no iPad counterpart
/// yet — so there is nothing to present. Reporting `canPresentSorting == false`
/// keeps its button off the toolbar instead of offering a dead control.
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
        let onClose: () -> Void
    }

    @Published var comparison: ComparisonRequest?

    var canPresentComparison: Bool { true }
    var canPresentSorting: Bool { false }

    func presentComparison(
        initialLeftVideo: URL?,
        openLibrary: [ComparisonAthleteChoice],
        onClose: @escaping () -> Void
    ) {
        comparison = ComparisonRequest(
            initialLeftVideo: initialLeftVideo,
            openLibrary: openLibrary,
            onClose: onClose
        )
    }

    func presentSorting(
        openResizedLibrary: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    ) {
        // Sort & Resize needs the AVFoundation pipeline from phase 2. Calling
        // this is harmless; `canPresentSorting` keeps the button off the
        // toolbar so it should not happen.
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
}
