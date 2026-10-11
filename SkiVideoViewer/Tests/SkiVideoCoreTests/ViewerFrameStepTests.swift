import AVFoundation
import XCTest
@testable import SkiVideoCore

/// Against real media: frame rate and presentation size come from the track.
@MainActor
final class ViewerFrameStepTests: XCTestCase {
    private var temporaryDirectory: URL?

    override func tearDown() {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        temporaryDirectory = nil
        super.tearDown()
    }

    private func makeLoadedModel(seconds: Double = 2, fps: Int32 = 25) throws -> ViewerModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        temporaryDirectory = root
        _ = try makeRealVideoFile(in: root.appendingPathComponent("Athlete", isDirectory: true),
                                  name: "run1.mov", seconds: seconds, fps: fps)
        let model = ViewerModel(input: FakeInputSource(), folderPicker: FakeFolderPicker(),
                                oauthPresenter: FakeOAuthPresenter())
        model.openDirectory(root)
        waitUntil("the clip must load") { model.duration > 0 && model.pictureSize != .zero }
        return model
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 20, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition(), message)
    }

    func testFrameDurationAndPictureSizeComeFromTheTrack() throws {
        let model = try makeLoadedModel(fps: 25)
        waitUntil("the frame rate must be read") { abs(model.frameDuration - 1.0 / 25) < 1e-6 }
        XCTAssertEqual(model.pictureSize, CGSize(width: 160, height: 90))
    }

    func testAStepForwardMovesExactlyOneFrame() throws {
        let model = try makeLoadedModel(fps: 25)
        waitUntil("the frame rate must be read") { abs(model.frameDuration - 1.0 / 25) < 1e-6 }
        model.stepFrame(.forward)
        XCTAssertEqual(model.currentTime, 1.0 / 25, accuracy: 1e-9)
        waitUntil("the player must land on the frame") { abs(model.player.currentTime().seconds - 1.0 / 25) < 0.002 }
    }

    /// Review Focus 1: no movement, and no step reported, at either end.
    func testStepsStopAtBothEnds() throws {
        let model = try makeLoadedModel(seconds: 1, fps: 25)
        waitUntil("the frame rate must be read") { abs(model.frameDuration - 1.0 / 25) < 1e-6 }
        var steps: [(Double, Double)] = []
        model.onFrameStep = { steps.append(($0, $1)) }
        model.stepFrame(.backward)
        XCTAssertEqual(model.currentTime, 0)
        XCTAssertTrue(steps.isEmpty)
        model.scrub(to: model.duration)
        model.stepFrame(.forward)
        XCTAssertTrue(steps.isEmpty, "the last frame has no frame after it")
    }

    func testAStepReportsWhereItCameFromAndWentTo() throws {
        let model = try makeLoadedModel(fps: 25)
        waitUntil("the frame rate must be read") { abs(model.frameDuration - 1.0 / 25) < 1e-6 }
        var steps: [(Double, Double)] = []
        model.onFrameStep = { steps.append(($0, $1)) }
        model.stepFrame(.forward)
        model.stepFrame(.forward)
        model.stepFrame(.backward)
        XCTAssertEqual(steps.count, 3)
        for (got, want) in zip(steps.map(\.1), [1.0 / 25, 2.0 / 25, 1.0 / 25]) {
            XCTAssertEqual(got, want, accuracy: 1e-9)
        }
        XCTAssertEqual(steps.first?.0, 0)
    }

    /// During playback `currentTime` is written only by the 0.1 s periodic
    /// observer, so after a pause it can trail the picture by 2-3 frames.
    func testAStepDuringPlaybackStartsFromWhereThePictureIs() throws {
        let model = try makeLoadedModel(seconds: 2, fps: 25)
        waitUntil("the frame rate must be read") { abs(model.frameDuration - 1.0 / 25) < 1e-6 }
        model.applyTransport(.playPause)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        var from: Double?
        model.onFrameStep = { f, _ in from = f }
        let actual = model.player.currentTime().seconds
        model.stepFrame(.forward)
        let reported = try XCTUnwrap(from, "the step must be reported")
        XCTAssertEqual(reported, actual, accuracy: 0.5 / 25 + 0.01,
                       "from must follow the picture, not the last periodic playhead")
    }

    /// Two clips at different rates and sizes: the second must replace the
    /// first's values, not inherit them.
    func testChangingClipReplacesFrameDurationAndPictureSize() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        temporaryDirectory = root
        let athlete = root.appendingPathComponent("Athlete", isDirectory: true)
        _ = try makeRealVideoFile(in: athlete, name: "run1.mov", seconds: 2, fps: 25, width: 160, height: 90)
        _ = try makeRealVideoFile(in: athlete, name: "run2.mov", seconds: 2, fps: 10, width: 120, height: 80)
        let model = ViewerModel(input: FakeInputSource(), folderPicker: FakeFolderPicker(),
                                oauthPresenter: FakeOAuthPresenter())
        model.openDirectory(root)
        waitUntil("clip A must load") {
            model.pictureSize == CGSize(width: 160, height: 90) && abs(model.frameDuration - 1.0 / 25) < 1e-6
        }
        XCTAssertTrue(model.changeVideo(by: 1))
        XCTAssertEqual(model.pictureSize, .zero, "A's size must not linger")
        XCTAssertEqual(model.frameDuration, ClipDrawings.fallbackFrameDuration)
        waitUntil("clip B's values must arrive") {
            model.pictureSize == CGSize(width: 120, height: 80) && abs(model.frameDuration - 1.0 / 10) < 1e-6
        }
        // A late answer for A must not overwrite B's values.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(model.pictureSize, CGSize(width: 120, height: 80))
        XCTAssertEqual(model.frameDuration, 1.0 / 10, accuracy: 1e-6)
    }
}
