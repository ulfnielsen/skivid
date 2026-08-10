import AVFoundation
import XCTest
@testable import SkiVideoCore

/// The platform-agnostic contract of `ViewerModel`: intents in, playback and
/// library state out, with every seam faked. Nothing here touches AppKit, so
/// this is the suite an iPadOS target inherits unchanged.
///
/// `SkiVideoViewerTests/AppKitInputToModelTests` covers only what this cannot:
/// a real `AppKitInputSource` driving a real model. Assertions are not
/// duplicated between the two files.
@MainActor
final class ViewerModelIntentTests: XCTestCase {
    private var temporaryDirectory: URL!

    /// `VideoLibrary.scan` only inspects file extensions, so empty files are
    /// enough to populate the model. No playable media is required.
    private func makeLibrary(athletes: [String] = ["Idun"]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        for athleteName in athletes {
            let athlete = root.appendingPathComponent(athleteName, isDirectory: true)
            try FileManager.default.createDirectory(at: athlete, withIntermediateDirectories: true)
            for name in ["a.mp4", "b.mp4"] {
                FileManager.default.createFile(
                    atPath: athlete.appendingPathComponent(name).path,
                    contents: Data()
                )
            }
        }
        temporaryDirectory = root
        return root
    }

    override func tearDown() async throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    private func makeModel(
        athletes: [String] = ["Idun"]
    ) throws -> (ViewerModel, FakeInputSource, TestClock) {
        let input = FakeInputSource()
        let clock = TestClock()
        let model = ViewerModel(
            input: input,
            folderPicker: FakeFolderPicker(),
            oauthPresenter: FakeOAuthPresenter(),
            now: clock.now
        )
        model.openDirectory(try makeLibrary(athletes: athletes))
        return (model, input, clock)
    }

    func testSingleTapSeeksOneSecond() throws {
        let (model, input, _) = try makeModel()

        input.emit(.seek(.forward))

        XCTAssertEqual(model.lastSeekOffset ?? .nan, 1.0, accuracy: 0.0001)
        XCTAssertEqual(model.status, "Forward 1 seconds")
    }

    func testDoubleTapWithinWindowSeeksFiveSeconds() throws {
        let (model, input, clock) = try makeModel()

        input.emit(.seek(.forward))
        clock.advance(by: 0.2)   // inside the 0.38s window
        input.emit(.seek(.forward))

        XCTAssertEqual(model.lastSeekOffset ?? .nan, 5.0, accuracy: 0.0001)
        XCTAssertEqual(model.status, "Forward 5 seconds")
    }

    func testTapsOutsideWindowAreNotTreatedAsDoubleTap() throws {
        let (model, input, clock) = try makeModel()

        input.emit(.seek(.forward))
        clock.advance(by: 0.5)   // outside the 0.38s window
        input.emit(.seek(.forward))

        XCTAssertEqual(model.lastSeekOffset ?? .nan, 1.0, accuracy: 0.0001)
        XCTAssertEqual(model.status, "Forward 1 seconds")
    }

    func testSlowMotionBeganEntersSlowPlaybackImmediately() throws {
        let (model, input, _) = try makeModel()

        input.emit(.slowMotionBegan(.forward))

        XCTAssertEqual(model.status, "Slow forward")
    }

    func testSlowMotionEndedDoesNotSeek() throws {
        let (model, input, _) = try makeModel()

        input.emit(.slowMotionBegan(.backward))
        input.emit(.slowMotionEnded)

        XCTAssertNil(model.lastSeekOffset, "releasing a hold must not seek")
    }

    /// The hold is a held key now, so Space during one is an ordinary
    /// play/pause rather than a steering control for the hold. Pinning it
    /// because the old model had a dedicated branch in `togglePlayback` that
    /// paused and resumed the hold in place, and that branch is gone.
    func testSpaceDuringAHoldIsAnOrdinaryPlayPause() throws {
        let (model, input, _) = try makeModel()

        input.emit(.slowMotionBegan(.forward))
        XCTAssertEqual(model.status, "Slow forward")

        input.emit(.togglePlayback)

        // Positively, not as a `!= "Slow forward paused"`: nothing in `Sources`
        // produces that literal any more, so the negative form could only fail
        // if someone retyped the exact string. Space on a hold taken from a
        // paused clip ends the hold, finds the restored rate at 0, and plays.
        XCTAssertEqual(model.status, "Playing",
                       "Space must fall through to the plain play/pause branch")
    }

    /// A second begin while a hold runs is refused — auto-repeat delivers
    /// several key-downs per press — and a refused begin must not write the
    /// status either, or the line describes a hold that never started. The
    /// press that exposes it is the cross-direction one: ⌘→ held, then ⌘←
    /// without releasing, where the player is still running forward.
    func testASecondBeginInTheOtherDirectionIsRefusedWithoutRewordingTheStatus() throws {
        let (model, input, _) = try makeModel()

        input.emit(.slowMotionBegan(.forward))
        input.emit(.slowMotionBegan(.backward))

        XCTAssertEqual(model.status, "Slow forward",
                       "a refused begin must not word the status after itself")
    }

    /// Every library change used to clear the hold as part of its teardown, and
    /// the replacement (`endSlowMotion`) must keep doing it.
    ///
    /// Asserts that a *later* hold is accepted, not that the rate is 0 after the
    /// change: `loadCurrentVideo` calls `player.pause()` unconditionally, so a
    /// rate assertion is satisfied by that line whether or not the hold was torn
    /// down, and would pass with `endSlowMotion` deleted from `changeVideo`.
    /// Acceptance is exactly what a stranded `hold.isActive` destroys — `begin`
    /// refuses every hold for the rest of the session — and the status is how a
    /// refusal shows from outside, since a refused begin writes nothing and
    /// leaves `loadCurrentVideo`'s "Paused" standing.
    func testChangingClipEndsAnActiveHold() throws {
        let (model, input, _) = try makeModel()

        input.emit(.slowMotionBegan(.forward))
        input.emit(.clip(.next))
        input.emit(.slowMotionBegan(.backward))

        XCTAssertEqual(model.status, "Slow backward",
                       "a hold must not survive a clip change and lock out every later hold")
    }

    /// Both directions matter. `changeVideo(by:)` wraps with
    /// `(videoIndex + offset + count) % count`, and the `+ count` term exists
    /// only so Swift's `%` behaves for a negative offset. Without a
    /// `.clip(.previous)` step here, dropping that term leaves every forward
    /// assertion passing while the previous-clip button in `ContentView`
    /// (`model.changeVideo(by: -1)`) computes an out-of-bounds -1.
    func testClipIntentStepsAndWrapsTheVideoIndexInBothDirections() throws {
        let (model, input, _) = try makeModel()

        XCTAssertEqual(model.videoIndex, 0)
        input.emit(.clip(.next))
        XCTAssertEqual(model.videoIndex, 1)
        input.emit(.clip(.next))
        XCTAssertEqual(model.videoIndex, 0, "should wrap forward")

        input.emit(.clip(.previous))
        XCTAssertEqual(model.videoIndex, 1, "should wrap backward, not to -1")
        input.emit(.clip(.previous))
        XCTAssertEqual(model.videoIndex, 0)
    }

    /// The athlete twin of the clip test above, and load-bearing for the same
    /// reason: `changeAthlete(by:)` wraps with
    /// `(currentIndex + offset + athletes.count) % athletes.count`. Page Up
    /// reaches it as `.athlete(.previous)`, and without the `+ count` term
    /// Swift's `%` yields -1 from the first athlete, so `athletes[-1]` is read
    /// out of bounds. Both directions are asserted because a forward-only test
    /// passes with the term removed.
    func testAthleteIntentStepsAndWrapsTheAthleteInBothDirections() throws {
        let (model, input, _) = try makeModel(athletes: ["Alma", "Idun", "Sindre"])

        XCTAssertEqual(model.athletes.map(\.name), ["Alma", "Idun", "Sindre"])
        XCTAssertEqual(model.currentAthlete?.name, "Alma")

        input.emit(.athlete(.next))
        XCTAssertEqual(model.currentAthlete?.name, "Idun")
        input.emit(.athlete(.next))
        XCTAssertEqual(model.currentAthlete?.name, "Sindre")
        input.emit(.athlete(.next))
        XCTAssertEqual(model.currentAthlete?.name, "Alma", "should wrap forward")

        input.emit(.athlete(.previous))
        XCTAssertEqual(
            model.currentAthlete?.name,
            "Sindre",
            "should wrap backward to the last athlete, not index -1"
        )
        input.emit(.athlete(.previous))
        XCTAssertEqual(model.currentAthlete?.name, "Idun")
    }

    func testDisablingInputIsForwardedToTheSource() throws {
        let (model, input, _) = try makeModel()

        model.setKeyboardControlsEnabled(false)
        XCTAssertFalse(input.isEnabled)
    }

    func testChooseDirectoryOpensWhatThePickerReturns() async throws {
        let input = FakeInputSource()
        let picker = FakeFolderPicker()
        picker.folderToReturn = try makeLibrary()
        let model = ViewerModel(
            input: input,
            folderPicker: picker,
            oauthPresenter: FakeOAuthPresenter(),
            now: Date.init
        )

        await model.chooseDirectory()

        XCTAssertEqual(picker.pickFolderCallCount, 1)
        // The viewer's panel keeps its own wording; only the sorting panel says
        // "Choose folder containing raw videos" / "Choose".
        XCTAssertEqual(picker.lastPickFolderTitle, "Choose organized video directory")
        XCTAssertEqual(picker.lastPickFolderConfirmLabel, "Open")
        XCTAssertEqual(model.athletes.count, 1)
        XCTAssertEqual(model.athletes.first?.name, "Idun")
    }

    func testChooseDirectoryDoesNothingWhenCancelled() async throws {
        let input = FakeInputSource()
        let picker = FakeFolderPicker()
        picker.folderToReturn = nil
        let model = ViewerModel(
            input: input,
            folderPicker: picker,
            oauthPresenter: FakeOAuthPresenter(),
            now: Date.init
        )

        await model.chooseDirectory()

        XCTAssertEqual(picker.pickFolderCallCount, 1)
        XCTAssertTrue(model.athletes.isEmpty)
    }

    func testChooseClientSecretsFileStoresWhatThePickerReturns() async throws {
        let picker = FakeFolderPicker()
        let secretsURL = URL(fileURLWithPath: "/tmp/does-not-need-to-exist-client_secret.json")
        picker.fileToReturn = secretsURL
        let model = ViewerModel(
            input: FakeInputSource(),
            folderPicker: picker,
            oauthPresenter: FakeOAuthPresenter()
        )

        await model.chooseClientSecretsFile()

        XCTAssertEqual(picker.pickFileCallCount, 1)
        XCTAssertEqual(model.clientSecretsPath, secretsURL.path)
        XCTAssertEqual(
            picker.lastPickFileTitle,
            "Choose Google OAuth Client Secret",
            "regression guard: the panel title the user sees must survive routing through the FolderPicker seam"
        )
    }

    func testChooseClientSecretsFileDoesNothingWhenCancelled() async throws {
        let picker = FakeFolderPicker()
        picker.fileToReturn = nil
        let model = ViewerModel(
            input: FakeInputSource(),
            folderPicker: picker,
            oauthPresenter: FakeOAuthPresenter()
        )
        let pathBefore = model.clientSecretsPath

        await model.chooseClientSecretsFile()

        XCTAssertEqual(picker.pickFileCallCount, 1)
        XCTAssertEqual(model.clientSecretsPath, pathBefore)
    }
}
