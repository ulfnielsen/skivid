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

    func pickFolder(startingAt: URL?) async -> URL? {
        pickFolderCallCount += 1
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
        return callbackToReturn
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

    func writeMetadata(athlete: String, to url: URL) async throws {
        if let errorToThrow { throw errorToThrow }
        metadataCalls.append((athlete, url))
    }

    func resize(source: URL, destination: URL, athlete: String) async throws {
        if let errorToThrow { throw errorToThrow }
        resizeCalls.append((source, destination, athlete))
    }
}
