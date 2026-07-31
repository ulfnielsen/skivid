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

    func pickFolder(startingAt: URL?) async -> URL? {
        pickFolderCallCount += 1
        return folderToReturn
    }

    func pickFile(ofType: UTType) async -> URL? {
        fileToReturn
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
