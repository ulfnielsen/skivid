import XCTest
@testable import SkiVideoCore

final class DrawingTests: XCTestCase {
    private let frame = 1.0 / 30

    private func line(start: Double, end: Double? = nil) -> Drawing {
        Drawing(kind: .line, color: .red, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.9)],
                arrow: true, start: start, end: end)
    }

    func testAFreshDrawingCoversOnlyItsOwnFrame() {
        let d = line(start: 1.0)
        XCTAssertEqual(d.end, 1.0)
        XCTAssertTrue(d.isVisible(at: 1.0, frameDuration: frame))
        XCTAssertFalse(d.isVisible(at: 1.0 + frame, frameDuration: frame))
    }

    func testVisibilityIncludesHalfAFrameEitherSideAndNoMore() {
        let d = line(start: 1.0, end: 2.0)
        XCTAssertTrue(d.isVisible(at: 1.0 - frame / 2, frameDuration: frame))
        XCTAssertTrue(d.isVisible(at: 2.0 + frame / 2, frameDuration: frame))
        XCTAssertFalse(d.isVisible(at: 1.0 - frame / 2 - 0.001, frameDuration: frame))
        XCTAssertFalse(d.isVisible(at: 2.0 + frame / 2 + 0.001, frameDuration: frame))
    }

    func testStretchingForwardExtendsTheEndOfWhatIsVisible() {
        var all = ClipDrawings(drawings: [line(start: 1.0), line(start: 5.0)])
        XCTAssertTrue(all.stretch(from: 1.0, to: 1.0 + frame, frameDuration: frame))
        XCTAssertEqual(all.drawings[0].end, 1.0 + frame, accuracy: 1e-9)
        XCTAssertEqual(all.drawings[1].start, 5.0, "a drawing not on screen must not stretch")
        XCTAssertEqual(all.drawings[1].end, 5.0)
    }

    func testStretchingBackwardExtendsTheStart() {
        var all = ClipDrawings(drawings: [line(start: 1.0)])
        all.stretch(from: 1.0, to: 1.0 - frame, frameDuration: frame)
        XCTAssertEqual(all.drawings[0].start, 1.0 - frame, accuracy: 1e-9)
        XCTAssertEqual(all.drawings[0].end, 1.0)
    }

    func testStretchingWithNothingVisibleChangesNothing() {
        var all = ClipDrawings(drawings: [line(start: 3.0)])
        XCTAssertFalse(all.stretch(from: 1.0, to: 1.0 + frame, frameDuration: frame))
        XCTAssertEqual(all, ClipDrawings(drawings: [line(start: 3.0)]).withIDs(of: all))
    }

    func testStretchingInsideASpanChangesNothing() {
        var all = ClipDrawings(drawings: [line(start: 1.0, end: 2.0)])
        XCTAssertFalse(all.stretch(from: 1.5, to: 1.5 + frame, frameDuration: frame))
    }

    func testClearOnAFirstFrameDeletes() {
        var all = ClipDrawings(drawings: [line(start: 1.0, end: 2.0)])
        XCTAssertTrue(all.clear(at: 1.0, frameDuration: frame))
        XCTAssertTrue(all.isEmpty)
    }

    /// Review Focus 5: within half a frame of the start counts as the first
    /// frame, so a clear there deletes instead of leaving `end < start`.
    func testClearWithinHalfAFrameOfTheStartDeletes() {
        var all = ClipDrawings(drawings: [line(start: 1.0, end: 2.0)])
        all.clear(at: 1.0 + frame * 0.4, frameDuration: frame)
        XCTAssertTrue(all.isEmpty)
    }

    func testClearLaterInASpanCutsItBackToThePreviousFrame() {
        var all = ClipDrawings(drawings: [line(start: 1.0, end: 2.0)])
        all.clear(at: 1.5, frameDuration: frame)
        XCTAssertEqual(all.drawings.count, 1)
        XCTAssertEqual(all.drawings[0].end, 1.5 - frame, accuracy: 1e-9)
        XCTAssertFalse(all.drawings[0].isVisible(at: 1.5, frameDuration: frame))
    }

    func testClearLeavesDrawingsElsewhereAlone() {
        var all = ClipDrawings(drawings: [line(start: 4.0)])
        XCTAssertFalse(all.clear(at: 1.0, frameDuration: frame))
        XCTAssertEqual(all.drawings.count, 1)
    }

    func testSnapRoundsToTheNearestFrameBoundary() {
        XCTAssertEqual(ClipDrawings.snap(1.0 / 30 * 10 + 0.004, frameDuration: frame), 1.0 / 30 * 10, accuracy: 1e-9)
        XCTAssertEqual(ClipDrawings.snap(0.7, frameDuration: 0), 0.7, "a zero frame duration must not divide by zero")
    }

    func testRoundTripsThroughJSON() throws {
        let all = ClipDrawings(drawings: [
            line(start: 1, end: 2),
            Drawing(kind: .text, color: .yellow, points: [CGPoint(x: 0.5, y: 0.5)], text: "Hips!", start: 3),
        ])
        let decoded = try JSONDecoder().decode(ClipDrawings.self, from: JSONEncoder().encode(all))
        XCTAssertEqual(decoded, all)
        XCTAssertEqual(decoded.version, 1)
    }
}

private extension ClipDrawings {
    /// Equality across two values built separately needs the same ids.
    func withIDs(of other: ClipDrawings) -> ClipDrawings {
        var copy = self
        for i in copy.drawings.indices where other.drawings.indices.contains(i) {
            copy.drawings[i].id = other.drawings[i].id
        }
        return copy
    }
}
