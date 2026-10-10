import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import SkiVideoCore
@testable import SkiVideoViewer

/// The athlete-search field's focus, against the real AppKit responder chain.
///
/// The reported bug: the sidebar's "Jump to athlete…" field auto-selects as
/// you type, so the operator never presses Return, `onSubmit` never fires, and
/// focus sits in the field indefinitely — Space, the app's play/pause key, is
/// typed into the field as a literal space instead of reaching the transport.
///
/// `@FocusState` is a SwiftUI-private property wrapper with no test seam, so
/// these tests read the thing it drives instead: on macOS a focused SwiftUI
/// `TextField` renders as an `AppKitTextField` whose `currentEditor()` is the
/// window's field editor, and `currentEditor() != nil` is exactly "this field
/// has the focus". Measured here: `window.makeFirstResponder(field)` gives it
/// (`currentEditor()` becomes non-nil), and `athleteSearchIsFocused = false`
/// takes it away (`currentEditor()` returns to nil and `window.firstResponder`
/// falls back to the window itself). The window never needs to be key —
/// `isKeyWindow` is false throughout, matching `ViewerControlsWiringTests`'
/// `.orderFront` windows — because the field editor is installed by
/// `makeFirstResponder`, not by activation.
///
/// Empty fixture files are enough, for the reason `ViewerControlsWiringTests`
/// gives: `togglePlayback` only needs `currentVideo != nil` and sets
/// `AVPlayer.rate` directly, which does not require a decodable item.
@MainActor
final class AthleteSearchFocusWiringTests: XCTestCase {
    private var temporaryDirectory: URL?

    override func setUp() {
        super.setUp()
        // Matches `ViewerControlsWiringTests`: `NSHostingView` needs the shared
        // application to exist before it lays anything out.
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    override func tearDown() {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        super.tearDown()
    }

    /// The fix itself. Focus is in the search field — as it is for the whole
    /// session once the operator has typed a name, because the auto-select
    /// means they never press Return — and then playback starts. The field must
    /// let go, or the next Space goes into the text instead of pausing.
    ///
    /// Driven through `applyTransport(.playPause)`, a real public entry point,
    /// so the chain under test is the whole one: transport → player rate → KVO
    /// → `model.isPlaying` → `ContentView`'s `onChange` → `@FocusState` → the
    /// AppKit responder chain.
    func testStartingPlaybackGivesUpTheAthleteSearchFocus() throws {
        let (model, window, field) = try makeHostedContentView()

        XCTAssertTrue(window.makeFirstResponder(field), "precondition: the field must accept focus")
        settle(window)
        XCTAssertNotNil(field.currentEditor(), "precondition: the search field starts out focused")
        XCTAssertFalse(model.isPlaying, "precondition: nothing is playing yet")

        model.applyTransport(.playPause)
        settle(window)

        XCTAssertTrue(model.isPlaying, "precondition: playback must actually have started")
        XCTAssertNil(
            field.currentEditor(),
            "starting playback must give up the athlete-search focus, so Space reaches the transport"
        )
    }

    /// The other half, and the one that keeps the fix from overreaching:
    /// pausing is what an operator does *in order to* type a name, so
    /// `isPlaying` falling must leave the field alone. A `onChange` that
    /// resigned focus on every change rather than only on `true` would rip the
    /// field away at exactly the wrong moment.
    ///
    /// The field is focused *while playing* here, so the transition under test
    /// is genuinely true → false with focus held across it.
    func testPausingDoesNotDisturbTheAthleteSearchFocus() throws {
        let (model, window, field) = try makeHostedContentView()

        model.applyTransport(.playPause)
        settle(window)
        XCTAssertTrue(model.isPlaying, "precondition: playback must be running before the field is focused")

        XCTAssertTrue(window.makeFirstResponder(field), "precondition: the field must accept focus")
        settle(window)
        XCTAssertNotNil(field.currentEditor(), "precondition: the operator has clicked into the field mid-playback")

        model.applyTransport(.playPause)
        settle(window)

        XCTAssertFalse(model.isPlaying, "precondition: playback must actually have stopped")
        XCTAssertNotNil(
            field.currentEditor(),
            "pausing must leave the search field focused: pausing is how the operator makes room to type"
        )
    }

    /// Return means "I am done searching". The auto-select makes it optional,
    /// but honouring it costs nothing — and an operator who does press it
    /// expects the next Space to pause, not to be typed.
    ///
    /// Driven by `insertNewline(_:)` on the real field editor, which is what
    /// the Return key produces; SwiftUI turns it into `.onSubmit`.
    func testPressingReturnGivesUpTheAthleteSearchFocus() throws {
        let (model, window, field) = try makeHostedContentView()

        XCTAssertTrue(window.makeFirstResponder(field), "precondition: the field must accept focus")
        settle(window)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "precondition: the field must be focused")

        editor.insertText("Nora", replacementRange: NSRange(location: 0, length: 0))
        settle(window)
        editor.insertNewline(nil)
        settle(window)

        XCTAssertNil(
            field.currentEditor(),
            "pressing Return in the athlete search must give the focus up"
        )
        // Return still has to do its original job. Asserted on the second
        // athlete, not the first: `selectFirstMatchingAthlete` on an empty
        // query would land on "Idun Nielsen" and pass without the query ever
        // reaching the model.
        XCTAssertEqual(
            model.currentAthlete?.name, "Nora Nielsen",
            "Return must still select the matching athlete"
        )
    }

    /// The guard on the fix. The tempting cheap version of this bug report is
    /// to make Space in the field pause the video — which breaks every athlete
    /// in the library, because they all have two names. A space typed into the
    /// focused field must still land in the query as a space.
    func testASpaceTypedIntoTheSearchFieldStaysInTheQuery() throws {
        let (model, window, field) = try makeHostedContentView()

        XCTAssertTrue(window.makeFirstResponder(field), "precondition: the field must accept focus")
        settle(window)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "precondition: the field must be focused")

        for character in "Nora N" {
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            settle(window)
        }

        XCTAssertEqual(
            model.athleteQuery, "Nora N",
            "the space between first and last name must reach the query, not be stolen as a play/pause key"
        )
        XCTAssertNotNil(field.currentEditor(), "typing a space must not cost the field its focus either")
        XCTAssertEqual(
            model.currentAthlete?.name, "Nora Nielsen",
            "the two-word query must still select the athlete it matches"
        )
    }

    // MARK: - Fixtures

    /// Two athletes, both with a space in the name — the shape of the real
    /// library, and the reason Space cannot be intercepted in the field.
    /// "Nora" is deliberately the *second* one so a test asserting on the
    /// selection cannot pass by defaulting to the first.
    private func makeHostedContentView() throws -> (ViewerModel, NSWindow, NSTextField) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        temporaryDirectory = root
        for name in ["Idun Nielsen", "Nora Nielsen"] {
            let athlete = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: athlete, withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: athlete.appendingPathComponent("run1.mp4").path,
                contents: Data()
            )
        }

        let model = ViewerModel(
            input: AppKitInputSource(),
            folderPicker: AppKitFolderPicker(),
            oauthPresenter: StubOAuthPresenter()
        )
        model.openDirectory(root)
        XCTAssertEqual(model.currentAthlete?.name, "Idun Nielsen", "precondition: the library must have loaded")

        let host = NSHostingView(
            rootView: ContentView(
                model: model,
                initialDirectory: nil,
                secondaryScreens: NoSecondaryScreensForFocus()
            )
            .frame(width: 1400, height: 900)
        )
        // A real `NSWindow` is the load-bearing part, not its style mask: the
        // field editor lives on the window, so a field hosted outside one can
        // never take focus at all. `.titled` matches an actual app window;
        // measured, `.borderless` works here too, so nothing depends on the
        // choice.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        settle(window)

        let field = try XCTUnwrap(
            textField(in: host),
            "expected the sidebar's athlete-search TextField to render as a real NSTextField"
        )
        XCTAssertEqual(
            field.placeholderString, "Jump to athlete…",
            "precondition: the field found must be the athlete search, not some other text field"
        )
        return (model, window, field)
    }

    /// SwiftUI's focus changes and `ViewerModel.isPlaying`'s KVO hop both land
    /// on the main run loop a turn or two later, so every step spins it rather
    /// than reading immediately.
    private func settle(_ window: NSWindow, seconds: TimeInterval = 0.25) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Walked by AppKit subview identity, like `ViewerControlsWiringTests`'
    /// `transportButtons` and `nsSlider`: this is the tree `NSHostingView`
    /// builds, not the accessibility tree (which, as that file measured, is
    /// empty in a `swift test` host process).
    private func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for sub in view.subviews {
            if let found = textField(in: sub) { return found }
        }
        return nil
    }
}

/// Neither secondary screen is offered and neither is ever expected to be
/// presented: these tests only render `ContentView` to reach the real search
/// field in its sidebar.
@MainActor
private final class NoSecondaryScreensForFocus: SecondaryScreenPresenter {
    let canPresentComparison = false
    let canPresentSorting = false
    let screensCoverTheViewer = false
    let hasOpenWindow = false

    func presentComparison(
        initialLeftVideo: URL?,
        openLibrary: [ComparisonAthleteChoice],
        prepare: ClipPreparer,
        onClose: @escaping () -> Void
    ) {
        XCTFail("presentComparison must not be called by this test")
    }

    func presentSorting(
        libraryAthletes: [AthleteGroup],
        upload: Result<UploadTarget, UploadRefusal>,
        openResizedLibrary: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    ) {
        XCTFail("presentSorting must not be called by this test")
    }
}
