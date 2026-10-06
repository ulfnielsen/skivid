import Foundation
import UniformTypeIdentifiers
@testable import SkiVideoCore

@MainActor
final class FakeInputSource: PlaybackInputSource {
    var onIntent: ((PlaybackIntent) -> Void)?
    private(set) var isEnabled = true

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    /// Drives the model exactly as a real input source would.
    func emit(_ intent: PlaybackIntent) {
        onIntent?(intent)
    }
}

@MainActor
final class FakeFolderPicker: FolderPicker {
    var folderToReturn: URL?
    var fileToReturn: URL?
    private(set) var pickFolderCallCount = 0
    private(set) var pickFileCallCount = 0
    private(set) var lastPickFileTitle: String?
    private(set) var lastPickFileType: UTType?
    private(set) var lastPickFolderTitle: String?
    private(set) var lastPickFolderConfirmLabel: String?

    func pickFolder(startingAt: URL?, title: String, confirmLabel: String) async -> URL? {
        pickFolderCallCount += 1
        lastPickFolderTitle = title
        lastPickFolderConfirmLabel = confirmLabel
        return folderToReturn
    }

    func pickFile(ofType type: UTType, title: String) async -> URL? {
        pickFileCallCount += 1
        lastPickFileTitle = title
        lastPickFileType = type
        return fileToReturn
    }
}

/// Stands in for the loopback server (macOS) or `ASWebAuthenticationSession`
/// (iOS). Records the two phases so a test can assert the redirect URI reaches
/// the authorization URL without any browser or network involvement.
@MainActor
final class FakeOAuthPresenter: OAuthPresenter {
    var redirectURIToReturn = "http://127.0.0.1:49152"
    var callbackToReturn: URL?
    var errorToThrow: Error?
    private(set) var prepareCallCount = 0
    private(set) var lastAuthorizationURL: URL?
    private(set) var lastRedirectURI: String?

    func prepareRedirectURI() async throws -> String {
        prepareCallCount += 1
        if let errorToThrow { throw errorToThrow }
        return redirectURIToReturn
    }

    func authorize(authorizationURL: URL, redirectURI: String) async throws -> URL {
        lastAuthorizationURL = authorizationURL
        lastRedirectURI = redirectURI
        if let errorToThrow { throw errorToThrow }
        guard let callbackToReturn else {
            throw NSError(domain: "FakeOAuthPresenter", code: 1)
        }
        return Self.reflectingState(from: authorizationURL, onto: callbackToReturn)
    }

    /// A real browser redirect echoes back whatever `state` Google was sent —
    /// `authorize` generates a fresh random one on every call and rejects a
    /// callback that doesn't carry it back, as its CSRF check. A test fixing
    /// `callbackToReturn`'s `state` to a literal ahead of time cannot know
    /// that value, so this substitutes the real one in, the way an actual
    /// redirect would, and leaves everything else about `callbackToReturn`
    /// untouched.
    private static func reflectingState(from authorizationURL: URL, onto callback: URL) -> URL {
        guard let realState = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "state" })?.value,
            var components = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        else {
            return callback
        }
        var items = components.queryItems ?? []
        if let index = items.firstIndex(where: { $0.name == "state" }) {
            items[index] = URLQueryItem(name: "state", value: realState)
        } else {
            items.append(URLQueryItem(name: "state", value: realState))
        }
        components.queryItems = items
        return components.url ?? callback
    }
}

/// Stands in for `KeychainTokenStore`, so a `GoogleDriveProvider` built from a
/// `GoogleOAuthConfiguration` — `connect`, and requests made before it — never
/// touches the real login Keychain in a test.
final class InMemoryOAuthTokenStore: OAuthTokenStore, @unchecked Sendable {
    private var storage: [String: String] = [:]

    func load(account: String) -> String? {
        storage[account]
    }

    func save(_ token: String, account: String) throws {
        storage[account] = token
    }

    func remove(account: String) {
        storage[account] = nil
    }
}

/// Deterministic replacement for `Date.init` so double-tap window tests do not
/// depend on wall-clock timing.
final class TestClock: @unchecked Sendable {
    private(set) var current = Date(timeIntervalSince1970: 1_000)

    func advance(by interval: TimeInterval) {
        current = current.addingTimeInterval(interval)
    }

    var now: () -> Date {
        { [self] in current }
    }
}

final class FakeMediaPipeline: MediaPipeline, @unchecked Sendable {
    private(set) var resizeCalls: [(source: URL, destination: URL, athlete: String)] = []
    private(set) var metadataCalls: [(athlete: String, url: URL)] = []
    var errorToThrow: Error?
    /// Set to make the next `resize` throw. The real pipeline throws
    /// `MediaPipelineError.unreadableSource` for Matroska and friends, and
    /// nothing pinned that the message reaches the user.
    var resizeError: Error?

    func writeMetadata(athlete: String, to url: URL) async throws {
        if let errorToThrow { throw errorToThrow }
        metadataCalls.append((athlete, url))
    }

    func resize(source: URL, destination: URL, athlete: String) async throws {
        if let resizeError { throw resizeError }
        if let errorToThrow { throw errorToThrow }
        resizeCalls.append((source, destination, athlete))
    }
}

@MainActor
final class FakePhotosImporter: PhotosImporting {
    var folderToReturn: URL?
    var errorToThrow: Error?
    private(set) var importCallCount = 0
    private(set) var discardCallCount = 0

    func importClips() async throws -> URL? {
        importCallCount += 1
        if let errorToThrow { throw errorToThrow }
        return folderToReturn
    }

    func discard() { discardCallCount += 1 }
}
