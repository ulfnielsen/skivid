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

    override func tearDown() async throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    private func makeModel() throws -> (ViewerModel, FakeInputSource, TestClock) {
        let input = FakeInputSource()
        let clock = TestClock()
        let model = ViewerModel(
            input: input,
            folderPicker: FakeFolderPicker(),
            oauthPresenter: FakeOAuthPresenter(),
            now: clock.now,
            holdThreshold: 0.02
        )
        model.openDirectory(try makeLibrary())
        return (model, input, clock)
    }

    func testSingleTapSeeksOneSecond() throws {
        let (model, input, _) = try makeModel()

        input.emit(.scrubBegan(.forward))
        input.emit(.scrubEnded(.forward, performTap: true))

        XCTAssertEqual(model.lastSeekOffset ?? .nan, 1.0, accuracy: 0.0001)
        XCTAssertEqual(model.status, "Forward 1 seconds")
    }

    func testDoubleTapWithinWindowSeeksFiveSeconds() throws {
        let (model, input, clock) = try makeModel()

        input.emit(.scrubBegan(.forward))
        input.emit(.scrubEnded(.forward, performTap: true))

        clock.advance(by: 0.2)   // inside the 0.38s window

        input.emit(.scrubBegan(.forward))
        input.emit(.scrubEnded(.forward, performTap: true))

        XCTAssertEqual(model.lastSeekOffset ?? .nan, 5.0, accuracy: 0.0001)
        XCTAssertEqual(model.status, "Forward 5 seconds")
    }

    func testTapsOutsideWindowAreNotTreatedAsDoubleTap() throws {
        let (model, input, clock) = try makeModel()

        input.emit(.scrubBegan(.forward))
        input.emit(.scrubEnded(.forward, performTap: true))

        clock.advance(by: 0.5)   // outside the 0.38s window

        input.emit(.scrubBegan(.forward))
        input.emit(.scrubEnded(.forward, performTap: true))

        XCTAssertEqual(model.lastSeekOffset ?? .nan, 1.0, accuracy: 0.0001)
        XCTAssertEqual(model.status, "Forward 1 seconds")
    }

    func testHoldEntersSlowScrub() async throws {
        let (model, input, _) = try makeModel()

        input.emit(.scrubBegan(.forward))
        try await Task.sleep(nanoseconds: 60_000_000)   // past the 0.02s threshold

        XCTAssertEqual(model.status, "Slow forward")
    }

    func testCancelledScrubDoesNotSeek() throws {
        let (model, input, _) = try makeModel()

        input.emit(.scrubBegan(.backward))
        input.emit(.scrubEnded(.backward, performTap: false))

        XCTAssertNil(model.lastSeekOffset)
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
            now: Date.init,
            holdThreshold: 0.02
        )

        await model.chooseDirectory()

        XCTAssertEqual(picker.pickFolderCallCount, 1)
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
            now: Date.init,
            holdThreshold: 0.02
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
