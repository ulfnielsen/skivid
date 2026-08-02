import XCTest
@testable import SkiVideoCore

final class SubjectPickModelTests: XCTestCase {
    private func segment(
        _ id: Int, _ firstSeen: TimeInterval, _ lastSeen: TimeInterval, count: Int = 100
    ) -> AnalysedSegment {
        AnalysedSegment(
            id: id, firstSeen: firstSeen, lastSeen: lastSeen,
            detectionCount: count, peakHeightFraction: 0.3, previews: []
        )
    }

    func testEverythingIsSelectableBeforeAnythingIsPicked() {
        let model = SubjectPickModel(segments: [
            segment(1, 0.0, 5.3), segment(2, 3.1, 9.7), segment(3, 11.4, 18.2),
        ])

        XCTAssertTrue(model.segments.allSatisfy { model.isSelectable($0) })
    }

    func testSelectingASegmentExcludesOnlyThoseOverlappingIt() {
        let model = SubjectPickModel(segments: [
            segment(1, 0.0, 5.3), segment(2, 3.1, 9.7), segment(3, 11.4, 18.2),
        ])
        model.toggle(1)

        XCTAssertFalse(model.isSelectable(model.segments[1]), "#2 overlaps #1")
        XCTAssertTrue(model.isSelectable(model.segments[2]), "#3 does not")
        XCTAssertNotNil(model.exclusionReason(for: model.segments[1]))
        XCTAssertNil(model.exclusionReason(for: model.segments[2]))
    }

    func testDeselectingRestoresWhatItExcluded() {
        let model = SubjectPickModel(segments: [segment(1, 0.0, 5.3), segment(2, 3.1, 9.7)])
        model.toggle(1)
        model.toggle(1)

        XCTAssertTrue(model.selected.isEmpty)
        XCTAssertTrue(model.isSelectable(model.segments[1]))
    }

    func testASegmentOverlappingTwoDisjointOnesIsExcludedByEither() {
        // #2 straddles #1 and #3, which do not touch each other. Picking either
        // end must exclude the straddler, and picking both must keep it out.
        let model = SubjectPickModel(segments: [
            segment(1, 0.0, 4.1), segment(2, 3.7, 12.6), segment(3, 11.9, 17.4),
        ])
        model.toggle(3)
        XCTAssertFalse(model.isSelectable(model.segments[1]))
        model.toggle(1)
        XCTAssertFalse(model.isSelectable(model.segments[1]))
    }

    func testAnExcludedSegmentCannotBeSelected() {
        let model = SubjectPickModel(segments: [segment(1, 0.0, 5.3), segment(2, 3.1, 9.7)])
        model.toggle(1)
        model.toggle(2)

        XCTAssertEqual(model.selected, [1])
    }

    func testSelectedIDsComeBackInTimeOrder() {
        let model = SubjectPickModel(segments: [
            segment(1, 20.4, 29.8), segment(2, 0.0, 6.2), segment(3, 8.1, 14.9),
        ])
        model.toggle(1)
        model.toggle(3)
        model.toggle(2)

        XCTAssertEqual(model.selectedInTimeOrder, [2, 3, 1])
    }

    func testSegmentsThatOnlyTouchAtAnEndpointStillOverlap() {
        // #1 ends exactly when #4 begins. A single instant in common is still
        // shared time: `overlaps` must treat the boundary as inclusive, or a
        // detection at that exact timestamp could belong to either pick.
        let model = SubjectPickModel(segments: [segment(1, 0.0, 5.3), segment(4, 5.3, 9.0)])
        model.toggle(1)

        XCTAssertFalse(model.isSelectable(model.segments[1]), "#4 touches #1 at 5.3")
        XCTAssertNotNil(model.exclusionReason(for: model.segments[1]))
    }
}
