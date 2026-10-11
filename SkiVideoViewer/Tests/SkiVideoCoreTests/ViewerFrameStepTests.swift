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
        try makeLoadedModel(seconds: seconds, frameDuration: CMTime(value: 1, timescale: fps))
    }

    private func makeLoadedModel(seconds: Double, frameDuration: CMTime) throws -> ViewerModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        temporaryDirectory = root
        _ = try makeRealVideoFile(in: root.appendingPathComponent("Athlete", isDirectory: true),
                                  name: "run1.mov", seconds: seconds, frameDuration: frameDuration)
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
        // A quarter of a frame in, not on the boundary: see
        // `ViewerModel.frameSeekBias`.
        waitUntil("the player must land on the frame") { abs(model.player.currentTime().seconds - 1.25 / 25) < 0.002 }
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

    // MARK: - The frame on screen is the frame reported

    /// Steps forward `count` times and returns each step whose picture is not
    /// the frame `currentTime` reports.
    ///
    /// The picture is identified the way the final review measured it: an
    /// `AVAssetImageGenerator` with zero tolerance, asked for the time the
    /// player actually seeked to (`player.currentTime()` once the seek has
    /// landed), reports in `actualTime` the presentation time of the frame
    /// that is on screen at that time — the frame at or before it, the same
    /// rule the player displays by. An `AVPlayerItemVideoOutput` on the item
    /// was tried first and dropped: with no layer attached it served a stale
    /// buffer, or none for five seconds, on 2 of 90 steps even at 50 fps,
    /// where every seek is exact.
    private func framesShownWrong(_ model: ViewerModel, steps count: Int) throws -> [String] {
        let frameDuration = model.frameDuration
        let item = try XCTUnwrap(model.player.currentItem)
        var landed: [(reported: Int, seekTime: CMTime)] = []
        var previous = model.player.currentTime()
        for _ in 0..<count {
            model.stepFrame(.forward)
            let reported = Int((model.currentTime / frameDuration).rounded())
            let deadline = Date().addingTimeInterval(5)
            func hasLanded() -> Bool {
                let now = model.player.currentTime()
                return now != previous && abs(now.seconds - model.currentTime) < frameDuration / 2
            }
            while !hasLanded(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            XCTAssertTrue(hasLanded(), "the seek for frame \(reported) never landed")
            previous = model.player.currentTime()
            landed.append((reported, previous))
        }

        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Keyed by microseconds, not `CMTime`: the generator hands the
        // requested time back in another timescale (0.14 s as 7/50 rather
        // than 84/600), and `CMTime`'s `==` sees those as different keys.
        func key(_ time: CMTime) -> Int { Int((time.seconds * 1e6).rounded()) }
        var shown: [Int: Int] = [:]
        let done = expectation(description: "every frame decoded")
        done.expectedFulfillmentCount = landed.count
        generator.generateCGImagesAsynchronously(forTimes: landed.map { NSValue(time: $0.seekTime) }) { requested, _, actual, _, _ in
            DispatchQueue.main.async {
                shown[key(requested)] = actual.isNumeric ? Int((actual.seconds / frameDuration).rounded()) : -1
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 60)
        return landed.compactMap { step in
            let frame = shown[key(step.seekTime)] ?? -1
            return frame == step.reported ? nil : "reported \(step.reported), shown \(frame)"
        }
    }

    /// 59.94 fps: frame k's presentation time k·1001/60000 s is not a whole
    /// number of the seek's 1/600 s ticks. Rounded to them, a seek to exactly
    /// k·frameDuration falls just *before* frame k, and the player shows k−1
    /// — the final review measured 148 of 150 steps wrong this way.
    ///
    /// The rate is checked loosely on purpose: the fixture writer stores the
    /// track's duration in its default 1/600 s movie timescale, and
    /// `nominalFrameRate` is frames over that rounded duration — measured,
    /// 59.9496 here rather than 59.9401. Camera files carry the same kind of
    /// rounding, so the fix has to tolerate it, and this test keeps it in.
    func testEveryStepAt5994ShowsTheFrameItReports() throws {
        let model = try makeLoadedModel(seconds: 2, frameDuration: CMTime(value: 1001, timescale: 60000))
        waitUntil("the frame rate must be read") { abs(model.frameDuration - 1001.0 / 60000) < 1e-5 }
        let wrong = try framesShownWrong(model, steps: 100)
        XCTAssertEqual(wrong.count, 0, "\(wrong.count) of 100 steps showed another frame: \(wrong.prefix(5))")
    }

    /// The control: at 50 fps every frame time is a whole number of ticks, so
    /// this held before the fix too. It must keep holding after it.
    func testEveryStepAt50ShowsTheFrameItReports() throws {
        let model = try makeLoadedModel(seconds: 2, fps: 50)
        waitUntil("the frame rate must be read") { abs(model.frameDuration - 1.0 / 50) < 1e-6 }
        let wrong = try framesShownWrong(model, steps: 90)
        XCTAssertEqual(wrong.count, 0, "\(wrong.count) of 90 steps showed another frame: \(wrong.prefix(5))")
    }

    // MARK: - Drawing mode: the picture and the stored time agree

    /// The frame on screen once the player has caught up with `currentTime`,
    /// identified the same way as `framesShownWrong` does.
    private func shownFrame(_ model: ViewerModel) throws -> Int {
        let frameDuration = model.frameDuration
        waitUntil("the seek must land") {
            abs(model.player.currentTime().seconds - model.currentTime) < frameDuration / 2
        }
        let generator = AVAssetImageGenerator(asset: try XCTUnwrap(model.player.currentItem).asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var actual = CMTime.invalid
        let done = expectation(description: "frame decoded")
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: model.player.currentTime())]) { _, _, time, _, _ in
            actual = time
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        return Int((try XCTUnwrap(actual.isNumeric ? actual : nil, "no frame decoded").seconds / frameDuration).rounded())
    }

    /// The frame a mark drawn now would be stored on: the overlay stamps
    /// marks with `currentTime` snapped to the nearest frame.
    private func stampedFrame(_ model: ViewerModel) -> Int {
        Int((ClipDrawings.snap(model.currentTime, frameDuration: model.frameDuration) / model.frameDuration).rounded())
    }

    private func loadedFor25() throws -> ViewerModel {
        let model = try makeLoadedModel(seconds: 2, fps: 25)
        waitUntil("the frame rate must be read") { abs(model.frameDuration - 1.0 / 25) < 1e-6 }
        return model
    }

    /// Scrubbed 0.6 of the way into frame 5, the picture shows frame 5 but a
    /// mark would be stamped on frame 6 — the one it would vanish on.
    func testEnteringDrawingModeShowsTheFrameMarksWillBeStoredOn() throws {
        let model = try loadedFor25()
        model.scrub(to: 5.6 * model.frameDuration)
        model.setDrawing(true)
        XCTAssertTrue(model.drawing.isDrawing)
        XCTAssertEqual(model.currentTime, 6 * model.frameDuration, accuracy: 1e-9, "entering re-seeks to the nearest frame")
        XCTAssertEqual(try shownFrame(model), stampedFrame(model), "the picture must be the frame marks are stamped with")
    }

    func testAScrubWhileDrawingLandsOnAWholeFrame() throws {
        let model = try loadedFor25()
        model.setDrawing(true)
        model.scrub(to: 7.6 * model.frameDuration)
        XCTAssertEqual(model.currentTime, 8 * model.frameDuration, accuracy: 1e-9)
        XCTAssertEqual(try shownFrame(model), stampedFrame(model), "the picture must be the frame marks are stamped with")
        // The periodic observer must not replace the snapped time with the
        // player's, which sits a quarter frame in.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(model.currentTime, 8 * model.frameDuration, accuracy: 1e-9)
    }

    /// Clear frame passes `currentTime` straight through. After a scrub that
    /// was a time inside a frame, and the cut landed between frames.
    func testClearFrameAfterAScrubCutsOnAFrameBoundary() throws {
        let model = try loadedFor25()
        let frame = model.frameDuration
        model.setDrawing(true)
        let session = try XCTUnwrap(model.drawing.session)
        let geometry = DrawingGeometry(pictureFrame: CGRect(x: 0, y: 0, width: 160, height: 90), videoSize: model.pictureSize)
        session.tool = .line
        session.dragBegan(at: CGPoint(x: 10, y: 45), geometry: geometry, time: 0, frameDuration: frame)
        session.dragEnded(at: CGPoint(x: 150, y: 45), geometry: geometry)
        session.stretch(from: 0, to: 20 * frame, frameDuration: frame)
        model.scrub(to: 9.6 * frame)
        session.clear(at: model.currentTime, frameDuration: frame)
        let end = try XCTUnwrap(session.drawings.drawings.first?.end)
        XCTAssertEqual(end, 9 * frame, accuracy: 1e-9, "the mark must stop on the frame before the cleared one")
    }

    func testAScrubWhileDrawingDropsTheSelection() throws {
        let model = try loadedFor25()
        let frame = model.frameDuration
        model.setDrawing(true)
        let session = try XCTUnwrap(model.drawing.session)
        let geometry = DrawingGeometry(pictureFrame: CGRect(x: 0, y: 0, width: 160, height: 90), videoSize: model.pictureSize)
        session.tool = .line
        session.dragBegan(at: CGPoint(x: 10, y: 45), geometry: geometry, time: 0, frameDuration: frame)
        session.dragEnded(at: CGPoint(x: 150, y: 45), geometry: geometry)
        session.tool = .move
        session.tapped(at: CGPoint(x: 80, y: 45), geometry: geometry, time: 0, frameDuration: frame)
        XCTAssertNotNil(session.selection, "precondition: the line is selected")
        model.scrub(to: 10 * frame)
        XCTAssertNil(session.selection, "Delete must not reach a mark that is no longer on screen")
    }
}
