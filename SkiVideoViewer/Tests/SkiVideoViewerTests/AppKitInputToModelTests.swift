import AppKit
import XCTest
@testable import SkiVideoCore
@testable import SkiVideoViewer

/// Drives a real `AppKitInputSource` into a real `ViewerModel`. This file owns
/// **only** the assertions that need both halves at once; everything provable
/// about the model alone lives in `SkiVideoCoreTests/ViewerModelIntentTests`
/// and everything provable about the key mapping alone lives in
/// `AppKitInputSourceTests`. Task 6 moved `ViewerModel` into `SkiVideoCore`,
/// so the tap/double-tap/clip-index coverage that used to be duplicated here
/// was removed in favour of the platform-agnostic copies.
///
/// What survives is what needs both halves at once. The mid-hold guard that
/// used to live here — `AppKitInputSource` and `ViewerModel` each keeping their
/// own `heldDirection` — went with the bare-arrow hold; it comes back against
/// the ⌘ keys in the next commit.
///
/// `makeStack()` passes a real `AppKitFolderPicker` only to satisfy the
/// initializer; nothing here calls `chooseDirectory()`, so `runModal()` is
/// never invoked.
@MainActor
final class AppKitInputToModelTests: XCTestCase {
    private var temporaryDirectory: URL?

    override func tearDown() async throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    /// `VideoLibrary.scan` only inspects file extensions, so empty files are
    /// enough to give the model a `currentVideo`. No playable media is needed:
    /// `seek` records the requested offset before it touches the player.
    private func makeLibrary() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let athlete = root.appendingPathComponent("Idun", isDirectory: true)
        try FileManager.default.createDirectory(at: athlete, withIntermediateDirectories: true)
        for name in ["a.mp4", "b.mp4"] {
            FileManager.default.createFile(
                atPath: athlete.appendingPathComponent(name).path,
                contents: Data()
            )
        }
        temporaryDirectory = root
        return root
    }

    private func makeStack() throws -> (ViewerModel, AppKitInputSource) {
        let source = AppKitInputSource()
        let model = ViewerModel(
            input: source,
            folderPicker: AppKitFolderPicker(),
            oauthPresenter: StubOAuthPresenter(),
            // Frozen: no test here spans the 0.38s double-tap window, and a
            // fixed date keeps that true however slowly the host runs.
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        model.openDirectory(try makeLibrary())
        return (model, source)
    }

    private func key(
        _ code: UInt16,
        type: NSEvent.EventType = .keyDown
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: code
        )!
    }

    private func tapRightArrow(_ source: AppKitInputSource) {
        _ = source.handle(key(124))
        _ = source.handle(key(124, type: .keyUp))
    }

    /// `ViewerModelIntentTests` proves the model forwards the flag to whatever
    /// source it holds; this proves the *real* source honours it end to end.
    func testDisablingKeyboardControlsStopsTheSource() throws {
        let (model, source) = try makeStack()

        model.setKeyboardControlsEnabled(false)
        tapRightArrow(source)

        XCTAssertNil(model.lastSeekOffset, "a disabled source must not reach the model")
    }
}
