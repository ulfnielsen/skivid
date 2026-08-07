import Foundation
import UniformTypeIdentifiers

// MARK: - Playback input

public enum Step: Sendable {
    case previous
    case next

    /// Offset applied to an index. Matches the `by:` arguments the models
    /// already take.
    public var offset: Int {
        switch self {
        case .previous: return -1
        case .next: return 1
        }
    }
}

public enum ScrubDirection: Int, Sendable {
    case backward = -1
    case forward = 1
}

public enum PlaybackIntent: Sendable {
    case togglePlayback
    case clip(Step)
    case athlete(Step)
    case scrubBegan(ScrubDirection)
    /// `performTap` is false when the scrub is being cancelled rather than
    /// released — for example when the app resigns active.
    case scrubEnded(ScrubDirection, performTap: Bool)
    case focusAthleteSearch
    case openFolder
}

/// Produces user intents from whatever input the platform offers: an `NSEvent`
/// monitor on macOS, gestures and key presses on iOS.
@MainActor
public protocol PlaybackInputSource: AnyObject {
    var onIntent: ((PlaybackIntent) -> Void)? { get set }
    func setEnabled(_ enabled: Bool)
}

// MARK: - File selection

@MainActor
public protocol FolderPicker: AnyObject {
    /// `confirmLabel` names the accept button. macOS puts it on the panel's
    /// prompt; a platform without one is free to ignore it.
    func pickFolder(startingAt: URL?, title: String, confirmLabel: String) async -> URL?
    func pickFile(ofType type: UTType, title: String) async -> URL?
}

// MARK: - OAuth

/// Runs the interactive part of the OAuth flow and returns the redirect URL
/// carrying the authorization code. The loopback server on macOS and
/// `ASWebAuthenticationSession` on iOS both satisfy this.
@MainActor
public protocol OAuthPresenter: AnyObject {
    /// Returns the redirect URI this presenter can receive on. macOS starts a
    /// loopback server and reports its port; iOS returns its custom scheme.
    /// Called before the authorization URL is built, because the URI is one of
    /// its query parameters.
    func prepareRedirectURI() async throws -> String

    func authorize(
        authorizationURL: URL,
        redirectURI: String
    ) async throws -> URL
}

// MARK: - Media

/// Transcoding operations, backed by AVFoundation in `AVFoundationMediaPipeline`.
public protocol MediaPipeline: Sendable {
    func writeMetadata(athlete: String, to url: URL) async throws
    func resize(source: URL, destination: URL, athlete: String) async throws
}
