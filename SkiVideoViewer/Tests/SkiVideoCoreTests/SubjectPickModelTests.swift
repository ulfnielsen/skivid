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

    // MARK: - A stored selection, seeded back in

    /// The sidecar's whole visible payoff: reopening the sheet shows the pick
    /// the operator made, rather than an empty grid that reads as "it was
    /// lost".
    ///
    /// Declared so the stored order and the time order differ — ids `[1, 3]`
    /// against a time order of `[3, 1]` — so a seed that happened to sort, or
    /// one that reported `selected` where `selectedInTimeOrder` was asked for,
    /// is visible here.
    func testAStoredSelectionIsRestoredAndStillReportsTimeOrder() {
        let model = SubjectPickModel(
            segments: [segment(1, 20.4, 29.8), segment(2, 0.0, 6.2), segment(3, 8.1, 14.9)],
            selected: [1, 3]
        )

        XCTAssertEqual(model.selected, [1, 3], "the stored ids must come back, in the order stored")
        XCTAssertEqual(model.selectedInTimeOrder, [3, 1], "time order is still computed, not stored")
        XCTAssertTrue(model.isSelected(model.segments[0]))
        XCTAssertTrue(model.isSelected(model.segments[2]))
        XCTAssertFalse(model.isSelected(model.segments[1]), "an unstored segment must not be selected")
    }

    /// A sidecar written before a re-analysis can name a segment that no longer
    /// exists. Retaining it would put an id in `selected` that no card can show
    /// and no tap can clear, and `selectedInTimeOrder` would drop it anyway —
    /// so it is not admitted in the first place.
    func testAnIDThatIsNotInTheSegmentsIsIgnored() {
        let model = SubjectPickModel(
            segments: [segment(1, 0.0, 5.3), segment(3, 11.4, 18.2)],
            selected: [7, 3]
        )

        XCTAssertEqual(model.selected, [3], "an id with no segment must be dropped, not retained")
        XCTAssertEqual(model.selectedInTimeOrder, [3])
    }

    /// **The invariant beats the file.** Two overlapping segments cannot be the
    /// same person — the failure this class exists to prevent — and no
    /// interactive path can select both, so a stored pair naming both is stale
    /// or hand-edited. The first named wins and the second is simply not
    /// selected, where it then reports its own reason like any other clash.
    ///
    /// Asserted in both orders, because "keeps the first named" and "keeps the
    /// lower id" are the same answer for `[1, 2]` and different answers for
    /// `[2, 1]`.
    func testTwoOverlappingStoredIDsKeepOnlyTheFirstNamed() throws {
        let overlapping = [segment(1, 0.0, 5.3), segment(2, 3.1, 9.7)]

        let firstWins = SubjectPickModel(segments: overlapping, selected: [1, 2])
        XCTAssertEqual(firstWins.selected, [1], "the second of two overlapping stored ids must be dropped")
        XCTAssertFalse(
            firstWins.isSelectable(firstWins.segments[1]),
            "the dropped segment must read as unselectable, not merely unselected"
        )
        let reason = try XCTUnwrap(
            firstWins.exclusionReason(for: firstWins.segments[1]),
            "the operator is owed the reason the stored id did not survive"
        )
        XCTAssertTrue(reason.contains("Overlaps segment 1"), "unexpected reason: \(reason)")

        let reversed = SubjectPickModel(segments: overlapping, selected: [2, 1])
        XCTAssertEqual(
            reversed.selected, [2],
            "the order given decides which survives, not the id's value"
        )
        XCTAssertNotNil(reversed.exclusionReason(for: reversed.segments[0]))
    }

    /// The same id twice cannot come from a tap — `toggle` would remove it the
    /// second time — so it can only come from a file. `selected` is a list the
    /// UI reads as a set, and a duplicate would be counted twice in the
    /// summary and handed to the analyser twice.
    func testADuplicateStoredIDIsAdmittedOnlyOnce() {
        let model = SubjectPickModel(
            segments: [segment(1, 0.0, 5.3), segment(3, 11.4, 18.2)],
            selected: [3, 3, 1]
        )

        XCTAssertEqual(model.selected, [3, 1], "a repeated id must be admitted exactly once")
    }

    /// The default. Every test above this section constructs the model without
    /// a selection and must keep behaving identically — an empty seed is not a
    /// special case, it is the loop running zero times.
    func testAnEmptyStoredSelectionBehavesExactlyAsNoSelection() {
        let segments = [segment(1, 0.0, 5.3), segment(2, 3.1, 9.7), segment(3, 11.4, 18.2)]
        let seeded = SubjectPickModel(segments: segments, selected: [])
        let unseeded = SubjectPickModel(segments: segments)

        XCTAssertEqual(seeded.selected, unseeded.selected)
        XCTAssertTrue(seeded.selected.isEmpty)
        XCTAssertTrue(seeded.segments.allSatisfy { seeded.isSelectable($0) })

        // And it is still a live model, not a frozen one.
        seeded.toggle(1)
        unseeded.toggle(1)
        XCTAssertEqual(seeded.selected, unseeded.selected, "toggling must behave the same either way")
        XCTAssertFalse(seeded.isSelectable(seeded.segments[1]), "#2 overlaps #1")
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
