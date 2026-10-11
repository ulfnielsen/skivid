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
}
