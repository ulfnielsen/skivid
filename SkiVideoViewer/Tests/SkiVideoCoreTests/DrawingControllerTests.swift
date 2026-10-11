import AVFoundation
import XCTest
@testable import SkiVideoCore

@MainActor
final class DrawingControllerTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defaults = UserDefaults(suiteName: "DrawingControllerTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func clip(_ name: String) -> URL { root.appendingPathComponent("Athlete/\(name)") }

    private func makeModel(clips: [String] = ["run1.mov", "run2.mov"]) throws -> ViewerModel {
        for name in clips {
            _ = try makeRealVideoFile(in: root.appendingPathComponent("Athlete", isDirectory: true),
                                      name: name, seconds: 2, fps: 25)
        }
        let model = ViewerModel(input: FakeInputSource(), folderPicker: FakeFolderPicker(),
                                oauthPresenter: FakeOAuthPresenter(),
                                drawing: DrawingController(defaults: defaults, saveDelay: 0.05))
        model.openDirectory(root)
        waitUntil("the clip must load") { model.pictureSize != .zero && abs(model.frameDuration - 0.04) < 1e-6 }
        return model
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 20, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition(), message)
    }

    private let g = DrawingGeometry(pictureFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                                    videoSize: CGSize(width: 160, height: 90))

    private func drawALine(_ model: ViewerModel) {
        let session = model.drawing.session!
        session.tool = .line
        session.dragBegan(at: CGPoint(x: 100, y: 500), geometry: g, time: model.currentTime,
                          frameDuration: model.frameDuration)
        session.dragEnded(at: CGPoint(x: 900, y: 500), geometry: g)
    }

    func testEnteringDrawingModePauses() throws {
        let model = try makeModel()
        model.applyTransport(.playPause)
        model.setDrawing(true)
        XCTAssertTrue(model.drawing.isDrawing)
        XCTAssertEqual(model.player.rate, 0)
    }

    func testSteppingWhileDrawingStretchesTheMarksOnScreen() throws {
        let model = try makeModel()
        model.setDrawing(true)
        drawALine(model)
        model.stepFrame(.forward)
        model.stepFrame(.forward)
        let line = model.drawing.session!.drawings.drawings[0]
        XCTAssertEqual(line.start, 0)
        XCTAssertEqual(line.end, 0.08, accuracy: 1e-9)
    }

    func testSteppingOutsideDrawingModeStretchesNothing() throws {
        let model = try makeModel()
        model.setDrawing(true)
        drawALine(model)
        model.setDrawing(false)
        model.stepFrame(.forward)
        XCTAssertEqual(model.drawing.session!.drawings.drawings[0].end, 0)
    }

    func testTheArrowKeysStepFramesOnlyWhileDrawing() throws {
        let model = try makeModel()
        model.setDrawing(true)
        model.handle(.seek(.forward))
        XCTAssertEqual(model.currentTime, 0.04, accuracy: 1e-9)
    }

    func testPlayLeavesDrawingModeAndSaves() throws {
        let model = try makeModel()
        model.setDrawing(true)
        drawALine(model)
        model.handle(.togglePlayback)
        XCTAssertFalse(model.drawing.isDrawing)
        XCTAssertNotEqual(model.player.rate, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: clip("run1.skidrawings.json").path))
    }

    func testTheDKeyIntentToggles() throws {
        let model = try makeModel()
        model.handle(.toggleDrawing)
        XCTAssertTrue(model.drawing.isDrawing)
        model.handle(.toggleDrawing)
        XCTAssertFalse(model.drawing.isDrawing)
    }

    func testAChangeIsSavedAfterTheDebounce() throws {
        let model = try makeModel()
        model.setDrawing(true)
        drawALine(model)
        waitUntil("the debounced save must write the file") {
            FileManager.default.fileExists(atPath: self.clip("run1.skidrawings.json").path)
        }
    }

    /// Review Focus 2: the old clip keeps its committed marks; the half-drawn
    /// one is dropped; the new clip starts clean.
    func testSwitchingClipSavesToTheOldClipAndDropsAHalfDrawnMark() throws {
        let model = try makeModel()
        model.setDrawing(true)
        drawALine(model)
        model.drawing.session!.dragBegan(at: CGPoint(x: 10, y: 10), geometry: g, time: 0, frameDuration: 0.04)
        model.changeVideo(by: 1)
        XCTAssertFalse(model.drawing.isDrawing)
        XCTAssertEqual(ClipDrawingsStore.load(for: ClipIdentity(clip("run1.mov"))).drawingCount, 1)
        XCTAssertTrue(model.drawing.session?.drawings.isEmpty ?? false)
        XCTAssertEqual(ClipDrawingsStore.load(for: ClipIdentity(clip("run2.mov"))), .none)
    }

    func testReopeningAClipBringsItsDrawingsBack() throws {
        let model = try makeModel()
        model.setDrawing(true)
        drawALine(model)
        model.changeVideo(by: 1)
        model.changeVideo(by: -1)
        XCTAssertEqual(model.drawing.session?.drawings.drawings.count, 1)
    }

    /// Review Focus 3: the second `loadCurrentVideo` for the same clip (a
    /// Drive clip's bytes landing) must not reload and lose what is in memory.
    func testLoadingTheSameClipAgainKeepsTheSession() throws {
        let model = try makeModel()
        model.setDrawing(true)
        drawALine(model)
        let session = model.drawing.session
        model.drawing.load(for: model.currentClipIdentity)
        XCTAssertTrue(model.drawing.session === session)
    }

    func testAnUnreadableFileRefusesDrawingAndSaysSo() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Athlete"), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: clip("run1.skidrawings.json"))
        let model = try makeModel()
        XCTAssertNil(model.drawing.session)
        XCTAssertEqual(model.drawing.notice, DrawingController.unreadableNotice)
        model.setDrawing(true)
        XCTAssertFalse(model.drawing.isDrawing)
        XCTAssertEqual(try Data(contentsOf: clip("run1.skidrawings.json")), Data("garbage".utf8))
    }


    /// A slow-motion hold's reverse fallback moves the playhead without
    /// updating `currentTime`, so a frame step during it would stretch
    /// drawings from a stale frame; the hold is refused while drawing.
    func testSlowMotionDoesNotStartWhileDrawing() throws {
        let model = try makeModel()
        model.setDrawing(true)
        model.handle(.slowMotionBegan(.forward))
        XCTAssertEqual(model.player.rate, 0)
        XCTAssertTrue(model.drawing.isDrawing)
    }

    /// A failed save must neither lose the marks nor hide the error: the
    /// drawings stay in memory across the clip change, and the notice stays.
    /// A directory where the file belongs makes the write fail reliably.
    func testAFailedSaveSurvivesAClipChangeAndIsRetried() throws {
        let model = try makeModel()
        let blocker = clip("run1.skidrawings.json")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        model.setDrawing(true)
        drawALine(model)
        model.changeVideo(by: 1)
        XCTAssertTrue(model.drawing.notice?.hasPrefix("Couldn't save drawings") == true, model.drawing.notice ?? "nil")
        try FileManager.default.removeItem(at: blocker)
        model.changeVideo(by: -1)
        XCTAssertEqual(model.drawing.session?.drawings.drawings.count, 1)
        model.drawing.saveNow()
        XCTAssertEqual(ClipDrawingsStore.load(for: ClipIdentity(clip("run1.mov"))).drawingCount, 1)
        XCTAssertNil(model.drawing.notice)
    }

    /// The same, when the old clip's file is still blocked on return: the
    /// session is rebuilt from memory, not from the (unreadable) disk.
    func testUnsavedDrawingsComeBackWhileTheFileIsStillBlocked() throws {
        let model = try makeModel()
        let blocker = clip("run1.skidrawings.json")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        model.setDrawing(true)
        drawALine(model)
        model.changeVideo(by: 1)
        model.changeVideo(by: -1)
        XCTAssertEqual(model.drawing.session?.drawings.drawings.count, 1)
        XCTAssertTrue(model.drawing.notice?.hasPrefix("Couldn't save drawings") == true)
    }

    func testTheUnreadableErrorHasAPlainDescription() {
        let text = ClipDrawingsStoreError.wouldOverwriteUnreadable.localizedDescription
        XCTAssertFalse(text.contains("couldn\u{2019}t be completed") || text.contains("couldn't be completed"), text)
        XCTAssertTrue(text.contains("left untouched"), text)
    }

    func testShowDrawingsIsRememberedAndOnByDefault() {
        let first = DrawingController(defaults: defaults)
        XCTAssertTrue(first.showsDrawings)
        first.showsDrawings = false
        XCTAssertFalse(DrawingController(defaults: defaults).showsDrawings)
    }
}

private extension ClipDrawingsLoad {
    var drawingCount: Int? {
        if case let .drawings(d) = self { return d.drawings.count }
        return nil
    }
}
