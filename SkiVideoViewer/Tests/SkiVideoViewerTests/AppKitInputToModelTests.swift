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
/// What survives is the pair: `AppKitInputSource` and `ViewerModel` each keep
/// their own `heldDirection`, and these two tests are the structural guard
/// against those two copies drifting apart again.
///
/// `makeStack()` passes a real `AppKitFolderPicker` only to satisfy the
/// initializer; nothing here calls `chooseDirectory()`, so `runModal()` is
/// never invoked.
@MainActor
final class AppKitInputToModelTests: XCTestCase {
    private var temporaryDirectory: URL?

    /// Deterministic stand-in for `Date.init` so the 0.38s double-tap window
    /// does not depend on how fast the test host runs.
    private final class Clock {
        private(set) var current = Date(timeIntervalSince1970: 1_000)
        var now: () -> Date { { [self] in current } }
    }

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

    /// A long hold threshold keeps every arrow press in this file a *tap*: the
    /// hold work item is scheduled on the main queue and these tests never
    /// yield, but being explicit keeps them immune to that detail.
    private func makeStack() throws -> (ViewerModel, AppKitInputSource) {
        let source = AppKitInputSource()
        let model = ViewerModel(
            input: source,
            folderPicker: AppKitFolderPicker(),
            oauthPresenter: StubOAuthPresenter(),
            now: Clock().now,
            holdThreshold: 60
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

    /// End-to-end form of the mid-hold regression: with Left held, pressing and
    /// releasing Right must change nothing, and releasing Left must still seek
    /// backward one second. Before the fix the Right *release* ended the scrub
    /// early and the Left release did nothing at all.
    ///
    /// This is the one assertion that pins `AppKitInputSource.heldDirection`
    /// and `ViewerModel.heldDirection` to each other. Neither file's own tests
    /// can catch them drifting.
    func testReleasingASecondArrowMidHoldDoesNotEndTheScrub() throws {
        let (model, source) = try makeStack()

        _ = source.handle(key(123))                  // press and hold Left
        _ = source.handle(key(124))                  // press Right mid-hold
        _ = source.handle(key(124, type: .keyUp))    // release Right

        XCTAssertNil(model.lastSeekOffset, "nothing about Right may seek")

        _ = source.handle(key(123, type: .keyUp))    // release Left

        XCTAssertEqual(model.lastSeekOffset ?? .nan, -1.0, accuracy: 0.0001)
        XCTAssertEqual(model.status, "Back 1 seconds")
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
