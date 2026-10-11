import XCTest
@testable import SkiVideoCore

@MainActor
final class DrawingSessionTests: XCTestCase {
    private let frame = 1.0 / 30
    /// A 1000×1000 picture at the pane's origin: pane points / 1000 = fractions.
    private let g = DrawingGeometry(pictureFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                                    videoSize: CGSize(width: 1000, height: 1000))

    private func drag(_ s: DrawingSession, _ from: CGPoint, _ to: CGPoint, time: Double = 1) {
        s.dragBegan(at: from, geometry: g, time: time, frameDuration: frame)
        s.dragChanged(to: CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2), geometry: g)
        s.dragEnded(at: to, geometry: g)
    }

    func testALineIsCommittedWithTheArrowheadSetting() {
        let s = DrawingSession()
        s.tool = .line
        drag(s, CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 100))
        XCTAssertEqual(s.drawings.drawings.count, 1)
        let line = s.drawings.drawings[0]
        XCTAssertEqual(line.kind, .line)
        XCTAssertTrue(line.arrow, "arrowheads are on by default")
        XCTAssertEqual(line.points, [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.5, y: 0.1)])
        XCTAssertEqual(line.start, 1)
        XCTAssertNil(s.inProgress)
    }

    func testATooShortLineIsDiscarded() {
        let s = DrawingSession()
        s.tool = .line
        drag(s, CGPoint(x: 100, y: 100), CGPoint(x: 104, y: 100))
        XCTAssertTrue(s.drawings.isEmpty)
    }

    func testPenPointsCloserThanTwoScreenPointsAreDropped() {
        let s = DrawingSession()
        s.tool = .pen
        s.dragBegan(at: CGPoint(x: 100, y: 100), geometry: g, time: 0, frameDuration: frame)
        s.dragChanged(to: CGPoint(x: 101, y: 100), geometry: g)   // dropped
        s.dragChanged(to: CGPoint(x: 110, y: 100), geometry: g)
        s.dragEnded(at: CGPoint(x: 110, y: 100), geometry: g)      // same point: dropped
        XCTAssertEqual(s.drawings.drawings.first?.points.count, 2)
    }

    func testAnAngleTakesADragThenATap() {
        let s = DrawingSession()
        s.tool = .angle
        drag(s, CGPoint(x: 500, y: 500), CGPoint(x: 800, y: 500))
        XCTAssertTrue(s.awaitingSecondArm)
        XCTAssertTrue(s.drawings.isEmpty, "not committed until the second arm is placed")
        XCTAssertEqual(s.inProgress?.points.count, 2)
        s.tapped(at: CGPoint(x: 500, y: 100), geometry: g, time: 1, frameDuration: frame)
        XCTAssertFalse(s.awaitingSecondArm)
        let angle = s.drawings.drawings[0]
        XCTAssertEqual(angle.points.count, 3)
        XCTAssertEqual(DrawingGeometry.angle(corner: angle.points[0], a: angle.points[1], b: angle.points[2],
                                             videoSize: g.videoSize), 90, accuracy: 1e-9)
    }

    func testAnAnglesSecondArmCanBeDraggedInstead() {
        let s = DrawingSession()
        s.tool = .angle
        drag(s, CGPoint(x: 500, y: 500), CGPoint(x: 800, y: 500))
        drag(s, CGPoint(x: 500, y: 450), CGPoint(x: 500, y: 100))
        XCTAssertEqual(s.drawings.drawings.first?.points.last, CGPoint(x: 0.5, y: 0.1))
    }

    func testSwitchingToolAbandonsAHalfPlacedAngle() {
        let s = DrawingSession()
        s.tool = .angle
        drag(s, CGPoint(x: 500, y: 500), CGPoint(x: 800, y: 500))
        s.tool = .line
        XCTAssertFalse(s.awaitingSecondArm)
        XCTAssertNil(s.inProgress)
    }

    func testATapSelectsAndATapOnNothingDeselects() {
        let s = DrawingSession()
        s.tool = .line
        drag(s, CGPoint(x: 100, y: 500), CGPoint(x: 900, y: 500))
        s.tapped(at: CGPoint(x: 500, y: 505), geometry: g, time: 1, frameDuration: frame)
        XCTAssertEqual(s.selection, s.drawings.drawings[0].id)
        s.tapped(at: CGPoint(x: 500, y: 900), geometry: g, time: 1, frameDuration: frame)
        XCTAssertNil(s.selection)
    }

    func testOnlyMarksOnThisFrameCanBeSelected() {
        let s = DrawingSession()
        s.tool = .line
        drag(s, CGPoint(x: 100, y: 500), CGPoint(x: 900, y: 500), time: 5)
        s.tapped(at: CGPoint(x: 500, y: 500), geometry: g, time: 1, frameDuration: frame)
        XCTAssertNil(s.selection)
    }

    func testDraggingASelectedLinesHandleMovesThatPoint() {
        let s = DrawingSession()
        s.tool = .line
        drag(s, CGPoint(x: 100, y: 500), CGPoint(x: 900, y: 500))
        s.tapped(at: CGPoint(x: 500, y: 500), geometry: g, time: 1, frameDuration: frame)
        drag(s, CGPoint(x: 900, y: 500), CGPoint(x: 900, y: 200))
        XCTAssertEqual(s.drawings.drawings.count, 1, "a handle drag must not start a new line")
        XCTAssertEqual(s.drawings.drawings[0].points[1], CGPoint(x: 0.9, y: 0.2))
    }

    func testDeleteRemovesTheSelection() {
        let s = DrawingSession()
        s.tool = .line
        drag(s, CGPoint(x: 100, y: 500), CGPoint(x: 900, y: 500))
        s.tapped(at: CGPoint(x: 500, y: 500), geometry: g, time: 1, frameDuration: frame)
        s.deleteSelection()
        XCTAssertTrue(s.drawings.isEmpty)
        XCTAssertNil(s.selection)
    }

    func testTextIsCommittedOnlyWhenItHasWords() {
        let s = DrawingSession()
        s.tool = .text
        s.tapped(at: CGPoint(x: 300, y: 300), geometry: g, time: 1, frameDuration: frame)
        XCTAssertNotNil(s.editingText)
        s.finishText("   ")
        XCTAssertTrue(s.drawings.isEmpty)
        s.tapped(at: CGPoint(x: 300, y: 300), geometry: g, time: 1, frameDuration: frame)
        s.finishText("Hips forward")
        XCTAssertEqual(s.drawings.drawings.first?.text, "Hips forward")
    }

    func testTappingExistingTextEditsItAndEmptyingItDeletesIt() {
        let s = DrawingSession()
        s.tool = .text
        s.tapped(at: CGPoint(x: 300, y: 300), geometry: g, time: 1, frameDuration: frame)
        s.finishText("Edge")
        s.tapped(at: CGPoint(x: 300, y: 300), geometry: g, time: 1, frameDuration: frame)
        XCTAssertEqual(s.editingText?.text, "Edge")
        s.finishText("")
        XCTAssertTrue(s.drawings.isEmpty)
    }

    func testUndoAndRedoCoverDrawStretchAndClear() {
        let s = DrawingSession()
        s.tool = .line
        drag(s, CGPoint(x: 100, y: 500), CGPoint(x: 900, y: 500), time: 1)
        s.stretch(from: 1, to: 1 + frame, frameDuration: frame)
        s.clear(at: 1, frameDuration: frame)
        XCTAssertTrue(s.drawings.isEmpty)
        s.undo()
        XCTAssertEqual(s.drawings.drawings.first?.end ?? 0, 1 + frame, accuracy: 1e-9)
        s.undo()
        XCTAssertEqual(s.drawings.drawings.first?.end, 1)
        s.undo()
        XCTAssertTrue(s.drawings.isEmpty)
        XCTAssertFalse(s.canUndo)
        s.redo()
        XCTAssertEqual(s.drawings.drawings.count, 1)
        XCTAssertTrue(s.canRedo)
    }

    func testAStretchThatChangesNothingIsNotAnUndoStep() {
        let s = DrawingSession()
        s.stretch(from: 1, to: 1 + frame, frameDuration: frame)
        XCTAssertFalse(s.canUndo)
    }

    func testTheMoveToolDrawsNothing() {
        let s = DrawingSession()
        s.tool = .move
        drag(s, CGPoint(x: 100, y: 100), CGPoint(x: 600, y: 600))
        XCTAssertTrue(s.drawings.isEmpty)
    }

    func testAHiddenMarksHandlesCannotBeGrabbed() {
        let s = DrawingSession()
        s.tool = .line
        drag(s, CGPoint(x: 100, y: 500), CGPoint(x: 900, y: 500), time: 1)
        s.tapped(at: CGPoint(x: 500, y: 500), geometry: g, time: 1, frameDuration: frame)
        XCTAssertNotNil(s.selection)
        drag(s, CGPoint(x: 900, y: 500), CGPoint(x: 900, y: 200), time: 5)
        XCTAssertEqual(s.drawings.drawings.count, 2, "a new line starts instead")
        XCTAssertEqual(s.drawings.drawings[0].points[1], CGPoint(x: 0.9, y: 0.5))
    }

    func testASecondArmTapTooCloseToTheCornerIsIgnored() {
        let s = DrawingSession()
        s.tool = .angle
        drag(s, CGPoint(x: 500, y: 500), CGPoint(x: 800, y: 500))
        s.tapped(at: CGPoint(x: 503, y: 500), geometry: g, time: 1, frameDuration: frame)
        XCTAssertTrue(s.awaitingSecondArm)
        XCTAssertEqual(s.inProgress?.points.count, 2)
        XCTAssertTrue(s.drawings.isEmpty)
    }

    func testASecondArmDragTooCloseToTheCornerIsIgnored() {
        let s = DrawingSession()
        s.tool = .angle
        drag(s, CGPoint(x: 500, y: 500), CGPoint(x: 800, y: 500))
        drag(s, CGPoint(x: 500, y: 450), CGPoint(x: 503, y: 500))
        XCTAssertTrue(s.awaitingSecondArm)
        XCTAssertEqual(s.inProgress?.points.count, 2)
        XCTAssertTrue(s.drawings.isEmpty)
    }

    func testAHandlePressWithoutMovementIsNotAnUndoStep() {
        let s = DrawingSession()
        s.tool = .line
        drag(s, CGPoint(x: 100, y: 500), CGPoint(x: 900, y: 500))
        s.tapped(at: CGPoint(x: 500, y: 500), geometry: g, time: 1, frameDuration: frame)
        s.undo()  // placeholder to reset below
        s.redo()
        s.tapped(at: CGPoint(x: 500, y: 500), geometry: g, time: 1, frameDuration: frame)
        let before = s.drawings
        s.dragBegan(at: CGPoint(x: 900, y: 500), geometry: g, time: 1, frameDuration: frame)
        s.dragEnded(at: CGPoint(x: 900, y: 500), geometry: g)
        XCTAssertEqual(s.drawings, before)
        s.undo()
        XCTAssertTrue(s.drawings.isEmpty, "the only undo step is the line itself")
    }

    func testAHandleDragIsExactlyOneUndoStep() {
        let s = DrawingSession()
        s.tool = .line
        drag(s, CGPoint(x: 100, y: 500), CGPoint(x: 900, y: 500))
        s.tapped(at: CGPoint(x: 500, y: 500), geometry: g, time: 1, frameDuration: frame)
        drag(s, CGPoint(x: 900, y: 500), CGPoint(x: 900, y: 200))
        s.undo()
        XCTAssertEqual(s.drawings.drawings[0].points[1], CGPoint(x: 0.9, y: 0.5))
        s.undo()
        XCTAssertTrue(s.drawings.isEmpty)
        XCTAssertFalse(s.canUndo)
    }

    func testFinishingUnchangedTextIsNotAnUndoStep() {
        let s = DrawingSession()
        s.tool = .text
        s.tapped(at: CGPoint(x: 300, y: 300), geometry: g, time: 1, frameDuration: frame)
        s.finishText("Edge")
        s.undo(); s.redo()
        s.tapped(at: CGPoint(x: 300, y: 300), geometry: g, time: 1, frameDuration: frame)
        s.finishText("Edge")
        s.undo()
        XCTAssertTrue(s.drawings.isEmpty, "unchanged text added no step beyond the original")
        XCTAssertFalse(s.canUndo)
    }
}
