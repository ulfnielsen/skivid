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

    // MARK: Validation

    func testDecodingWithEndBeforeStartThrows() throws {
        let json = """
        {
            "version": 1,
            "drawings": [
                {
                    "id": "550e8400-e29b-41d4-a716-446655440000",
                    "kind": "line",
                    "color": "red",
                    "points": [[0.1, 0.1], [0.9, 0.9]],
                    "arrow": true,
                    "text": "",
                    "start": 2.0,
                    "end": 1.0
                }
            ]
        }
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(ClipDrawings.self, from: json.data(using: .utf8)!)
        ) { error in
            if case .dataCorrupted = error as? DecodingError {
                XCTAssert(true)
            } else {
                XCTFail("Expected dataCorrupted, got \(error)")
            }
        }
    }

    func testDecodingAngleWithWrongPointCountThrows() throws {
        let json = """
        {
            "version": 1,
            "drawings": [
                {
                    "id": "550e8400-e29b-41d4-a716-446655440000",
                    "kind": "angle",
                    "color": "red",
                    "points": [[0.1, 0.1], [0.9, 0.9]],
                    "arrow": false,
                    "text": "",
                    "start": 1.0,
                    "end": 1.0
                }
            ]
        }
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(ClipDrawings.self, from: json.data(using: .utf8)!)
        ) { error in
            if case .dataCorrupted = error as? DecodingError {
                XCTAssert(true)
            } else {
                XCTFail("Expected dataCorrupted, got \(error)")
            }
        }
    }

    func testValidDrawingStillRoundTrips() throws {
        let drawing = Drawing(kind: .angle, color: .blue, points: [
            CGPoint(x: 0.1, y: 0.1),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.9, y: 0.1)
        ], start: 1.0, end: 2.0)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let encoded = try encoder.encode(drawing)
        let decoded = try decoder.decode(Drawing.self, from: encoded)

        XCTAssertEqual(decoded, drawing)
    }

    func testDecodingLineWithWrongPointCountThrows() throws {
        let json = """
        {
            "version": 1,
            "drawings": [
                {
                    "id": "550e8400-e29b-41d4-a716-446655440000",
                    "kind": "line",
                    "color": "red",
                    "points": [[0.1, 0.1]],
                    "arrow": true,
                    "text": "",
                    "start": 1.0,
                    "end": 1.0
                }
            ]
        }
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(ClipDrawings.self, from: json.data(using: .utf8)!)
        ) { error in
            if case .dataCorrupted = error as? DecodingError {
                XCTAssert(true)
            } else {
                XCTFail("Expected dataCorrupted, got \(error)")
            }
        }
    }

    func testDecodingTextWithWrongPointCountThrows() throws {
        let json = """
        {
            "version": 1,
            "drawings": [
                {
                    "id": "550e8400-e29b-41d4-a716-446655440000",
                    "kind": "text",
                    "color": "yellow",
                    "points": [[0.1, 0.1], [0.9, 0.9]],
                    "arrow": false,
                    "text": "Label",
                    "start": 1.0,
                    "end": 1.0
                }
            ]
        }
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(ClipDrawings.self, from: json.data(using: .utf8)!)
        ) { error in
            if case .dataCorrupted = error as? DecodingError {
                XCTAssert(true)
            } else {
                XCTFail("Expected dataCorrupted, got \(error)")
            }
        }
    }

    // MARK: Pulling a scrub onto a drawing

    /// 10 s on a 600pt timeline: 6pt of reach is 0.1 s.
    private func landing(_ time: Double, _ spans: [ClosedRange<Double>]) -> Double? {
        ClipDrawings.scrubLanding(for: time, spans: spans, duration: 10, width: 600)
    }

    func testAScrubWithinReachOfAOneFrameMarkLandsOnIt() {
        XCTAssertEqual(landing(4.91, [5...5]), 5, "from before")
        XCTAssertEqual(landing(5.09, [5...5]), 5, "from after")
    }

    func testAScrubBeyondReachLandsWhereItWasAsked() {
        XCTAssertNil(landing(4.89, [5...5]))
        XCTAssertNil(landing(5.11, [5...5]))
    }

    /// Reach is in points, so a narrower timeline reaches further in time.
    func testReachScalesWithTheTimelinesWidth() {
        XCTAssertNil(ClipDrawings.scrubLanding(for: 4.85, spans: [5...5], duration: 10, width: 600))
        XCTAssertEqual(ClipDrawings.scrubLanding(for: 4.85, spans: [5...5], duration: 10, width: 300), 5)
    }

    func testALongSpanPullsToItsNearerEndAndLeavesItsInsideAlone() {
        XCTAssertEqual(landing(1.95, [2...4]), 2)
        XCTAssertEqual(landing(4.05, [2...4]), 4, "not back across the whole span to its start")
        XCTAssertNil(landing(3, [2...4]), "the mark is already on screen")
    }

    func testTheNearerOfTwoSpansWins() {
        XCTAssertEqual(landing(5.04, [5...5, 5.1...5.1]), 5)
        XCTAssertEqual(landing(5.06, [5...5, 5.1...5.1]), 5.1)
    }

    func testNothingToMeasureAgainstMeansNoPull() {
        XCTAssertNil(ClipDrawings.scrubLanding(for: 4.95, spans: [5...5], duration: 10, width: 0))
        XCTAssertNil(ClipDrawings.scrubLanding(for: 4.95, spans: [5...5], duration: 0, width: 600))
        XCTAssertNil(landing(4.95, []))
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
