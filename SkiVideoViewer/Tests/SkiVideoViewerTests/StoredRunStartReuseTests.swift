import AppKit
import SwiftUI
import XCTest
@testable import SkiVideoCore
@testable import SkiVideoViewer

/// Confirming a pick the sidecar already answers for must not re-run the
/// twenty-second pass — and, far more importantly, must not lose the operator's
/// correction on the way.
///
/// **The assertion is the analyser's call count, not elapsed time.** A test that
/// timed the confirm would pass on a warm page cache, on a fast machine, and on
/// a short fixture whether or not the reuse rule existed at all.
/// `ComparisonView.record` therefore takes the pass as a parameter, the way
/// `SubjectSessionModel` already takes its analysis, and these hand it a closure
/// that counts.
///
/// The numbers are the operator's own, read out of
/// `Idun Nielsen/C0094.skianalysis.json`: `detected = 0.640s`, corrected to
/// `18.290s`, with `segmentIDs` stored as `[15, 8, 6, 3, 4, 5, 1]`. That id list
/// is **not** in time order, which is why an ordered comparison is not merely
/// theoretically wrong: it would have recomputed that clip on every single
/// confirm, forever, and — before this task — reverted it to 0.640s each time.
@MainActor
final class StoredRunStartReuseTests: XCTestCase {
    /// The measured start C0094's sidecar holds, which is eighteen seconds
    /// early.
    private let detected = StoredRunStart.started(
        time: 0.64, baseline: 0.4575163398692810, threshold: 0.8235294117647058
    )
    private let correction: TimeInterval = 18.29
    /// The stored ids, as they actually sit in the file.
    private let storedIDs = [15, 8, 6, 3, 4, 5, 1]
    /// The same segments as the sheet hands them back, in time order.
    private let timeOrderedIDs = [1, 3, 4, 5, 6, 8, 15]

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        NSApplication.shared.setActivationPolicy(.prohibited)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - 1. The reported defect

    /// The whole of the report: "it recomputes every time". With the stored ids
    /// handed back exactly as stored, nothing may run.
    func testConfirmingTheStoredPickDoesNotRunThePass() async throws {
        let clip = try clipWithSidecar(subject: pick())
        let session = try loadedSession(for: clip)
        var calls: [[Int]] = []

        let outcome = try await ComparisonView.record(
            segmentIDs: storedIDs, clip: clip, in: session,
            measuringWith: { _, _, ids in calls.append(ids); return .noSamples }
        )

        XCTAssertEqual(
            calls.count, 0,
            "confirming the pick that is already stored re-read the whole clip; that is the reported twenty seconds"
        )
        XCTAssertEqual(outcome, .reused(correction))
    }

    // MARK: - 2. The same segments, differently ordered

    /// The case the operator's own file is in. Re-picking through the sheet
    /// yields `selectedInTimeOrder`, which is not the order the sidecar holds,
    /// and the same segments in a different order are the same subject.
    func testConfirmingTheSameSegmentsInADifferentOrderDoesNotRunThePass() async throws {
        let clip = try clipWithSidecar(subject: pick())
        let session = try loadedSession(for: clip)
        XCTAssertNotEqual(
            storedIDs, timeOrderedIDs,
            "precondition: the two orders must differ, or this test cannot see an ordered comparison"
        )
        var calls = 0

        let outcome = try await ComparisonView.record(
            segmentIDs: timeOrderedIDs, clip: clip, in: session,
            measuringWith: { _, _, _ in calls += 1; return .noSamples }
        )

        XCTAssertEqual(
            calls, 0,
            "the same segments in a different order are the same subject and must not trigger a recompute"
        )
        XCTAssertEqual(outcome, .reused(correction))
    }

    // MARK: - 3. A different subject

    /// The other half, without which a rule that never recomputed would pass
    /// every test above: drop one segment and the previous answer does not
    /// apply.
    func testConfirmingADifferentSetRunsThePass() async throws {
        let clip = try clipWithSidecar(subject: pick())
        let session = try loadedSession(for: clip)
        let different = Array(timeOrderedIDs.dropLast())
        var calls: [[Int]] = []

        let outcome = try await ComparisonView.record(
            segmentIDs: different, clip: clip, in: session,
            measuringWith: { _, _, ids in
                calls.append(ids)
                return .started(RunStart(time: 12.5, baseline: 1.0, threshold: 1.8))
            }
        )

        XCTAssertEqual(calls, [different], "a different set of segments is a different subject and must be measured")
        XCTAssertEqual(outcome, .measured(12.5))
        XCTAssertEqual(
            session.pickedSubject?.correctedRunStart, nil,
            "a correction is to a particular detected start, and a fresh measurement is not that start"
        )
        XCTAssertEqual(session.pickedSubject?.syncTime, 12.5)
    }

    // MARK: - 4. A stale analysis

    /// Staleness means the segment list itself came out of different settings,
    /// so "segment 6" in the stored pick and "segment 6" in the grid the
    /// operator just picked from are not necessarily the same detections. The
    /// ids matching is not enough.
    func testAStaleAnalysisRunsThePassEvenWithMatchingSegments() async throws {
        let clip = try clipWithSidecar(subject: pick(), parameters: olderParameters)
        let session = try loadedSession(for: clip)
        XCTAssertTrue(session.isStale, "precondition: the sidecar must read as stale")
        var calls = 0

        let outcome = try await ComparisonView.record(
            segmentIDs: storedIDs, clip: clip, in: session,
            measuringWith: { _, _, _ in
                calls += 1
                return .started(RunStart(time: 12.5, baseline: 1.0, threshold: 1.8))
            }
        )

        XCTAssertEqual(calls, 1, "a stale analysis must be re-measured; its segment ids mean something else")
        XCTAssertEqual(outcome, .measured(12.5))
    }

    /// And with no stored pick at all there is nothing to reuse.
    func testAClipWithNoStoredPickRunsThePass() async throws {
        let clip = try clipWithSidecar(subject: nil)
        let session = try loadedSession(for: clip)
        var calls = 0

        _ = try await ComparisonView.record(
            segmentIDs: timeOrderedIDs, clip: clip, in: session,
            measuringWith: { _, _, _ in
                calls += 1
                return .started(RunStart(time: 12.5, baseline: 1.0, threshold: 1.8))
            }
        )

        XCTAssertEqual(calls, 1)
    }

    // MARK: - 5. The one that protects the operator's work

    /// Re-confirming an unchanged pick must leave the *corrected* start in
    /// force, not the detected one.
    ///
    /// **Every assertion here names 18.29 against 0.64 deliberately.** A version
    /// of this test that checked only "there is still a run start", or only
    /// `runStart.syncTime`, would pass while the effective start silently
    /// reverted eighteen seconds — which is the exact data-loss case, and is why
    /// the mutation "apply `runStart.syncTime` rather than the effective start"
    /// has to fail here rather than pass.
    ///
    /// Four separate places, because the revert can happen at any of them: the
    /// outcome the caller applies, the correction on the in-memory pick, the
    /// effective start the rest of the app reads (`runStarts` feeds
    /// `applySync` from exactly this), and the file after a reopen.
    func testReusingAStoredPickKeepsTheOperatorsCorrection() async throws {
        let clip = try clipWithSidecar(subject: pick())
        let session = try loadedSession(for: clip)
        XCTAssertEqual(
            session.pickedSubject?.runStart.syncTime, 0.64,
            "precondition: the detector was eighteen seconds early on this clip"
        )

        let outcome = try await ComparisonView.record(
            segmentIDs: timeOrderedIDs, clip: clip, in: session,
            measuringWith: { _, _, _ in
                XCTFail("the pass must not run for an unchanged pick")
                return .noSamples
            }
        )

        XCTAssertEqual(
            outcome, .reused(18.29),
            "the reuse must apply the corrected start; 0.64 here is the operator losing eighteen seconds of judgement"
        )
        let after = try XCTUnwrap(session.pickedSubject)
        XCTAssertEqual(
            after.correctedRunStart, 18.29,
            "re-confirming dropped the correction, so the next sync lands on the detector's 0.64s"
        )
        XCTAssertEqual(
            after.syncTime, 18.29,
            "the effective start is what `runStarts` hands `applySync`; 0.64 would sync the pair somewhere absurd"
        )
        XCTAssertNotEqual(after.syncTime, 0.64, "the detected start must not be the one that applies")
        XCTAssertEqual(
            after.runStart.syncTime, 0.64,
            "the measurement must still be stored beside the correction — it is the evidence about the detector"
        )

        let reopened = SubjectSessionModel()
        let onDisk = try XCTUnwrap(reopened.loadStored(for: clip)?.subject, "the sidecar must still hold a pick")
        XCTAssertEqual(onDisk.correctedRunStart, 18.29, "the correction must survive the write this confirm performs")
        XCTAssertEqual(onDisk.syncTime, 18.29)
        XCTAssertEqual(onDisk.runStart.syncTime, 0.64)
    }

    /// The reuse rule itself, stated where the sheet reads it: `confirmSubject`
    /// consults this *before* it decides whether to show the twenty-second
    /// working state, so a spinner is never flashed for a pass that will not
    /// run.
    func testTheReuseRuleComparesSegmentsAsSets() {
        let analysis = ClipAnalysis(
            version: 1, analysedAt: Date(timeIntervalSince1970: 1_754_121_660),
            parameters: .current, segments: segments, subject: pick()
        )
        XCTAssertNotNil(ComparisonView.reusablePick(in: analysis, isStale: false, segmentIDs: storedIDs))
        XCTAssertNotNil(
            ComparisonView.reusablePick(in: analysis, isStale: false, segmentIDs: timeOrderedIDs),
            "order is not part of the question"
        )
        XCTAssertNil(
            ComparisonView.reusablePick(in: analysis, isStale: false, segmentIDs: storedIDs + [2]),
            "a superset is a different subject"
        )
        XCTAssertNil(
            ComparisonView.reusablePick(in: analysis, isStale: true, segmentIDs: storedIDs),
            "a stale analysis is not reused"
        )
        XCTAssertNil(
            ComparisonView.reusablePick(in: analysis, isStale: false, segmentIDs: []),
            "an empty pick has nothing to reuse"
        )
    }

    // MARK: - 6. The caption

    /// The wording, exactly. The corrected form is the brief's own example, and
    /// the numbers in it are C0094's.
    func testTheCaptionShowsBothValuesAndTheSignedDifference() {
        XCTAssertEqual(
            SubjectPickList.storedStartCaption(for: pick()),
            "Run start 18.3s — detected 0.6s, corrected by +17.7s"
        )
        XCTAssertEqual(
            SubjectPickList.storedStartCaption(for: pick(corrected: nil)),
            "Detected run start 0.6s",
            "with no correction there is only the detected value to show"
        )
        XCTAssertNil(
            SubjectPickList.storedStartCaption(for: nil),
            "a clip with no stored pick has no start to report, and 0.0s would be a claim about the detector"
        )
    }

    /// A correction *earlier* than the detection reads as negative. The sign is
    /// the whole point: "seventeen seconds late" and "seventeen seconds early"
    /// are opposite facts about the detector, and this caption exists to
    /// accumulate exactly that evidence.
    func testACorrectionBackwardsReadsAsNegative() {
        let earlier = SubjectPick(
            segmentIDs: [3, 1],
            runStart: .started(time: 18.64, baseline: 1.89, threshold: 3.39),
            correctedRunStart: 16.84
        )
        XCTAssertEqual(
            SubjectPickList.storedStartCaption(for: earlier),
            "Run start 16.8s — detected 18.6s, corrected by -1.8s"
        )
    }

    /// `alreadyRunning` is not a measurement — `StoredRunStart`'s own note says
    /// the UI must not present it as one — so the caption does not call it a
    /// detection.
    func testAnAlreadyRunningStartIsNotCalledADetection() {
        let running = SubjectPick(segmentIDs: [1], runStart: .alreadyRunning(firstSeen: 4.42))
        XCTAssertEqual(SubjectPickList.storedStartCaption(for: running), "Already running at 4.4s")
        XCTAssertFalse(
            SubjectPickList.storedStartCaption(for: running)?.contains("detected") ?? true,
            "a subject that was never demonstrably still has no detected start to report"
        )

        let corrected = SubjectPick(
            segmentIDs: [1], runStart: .alreadyRunning(firstSeen: 4.42), correctedRunStart: 9.0
        )
        XCTAssertEqual(
            SubjectPickList.storedStartCaption(for: corrected),
            "Run start 9.0s — already running at 4.4s, corrected by +4.6s"
        )
    }

    /// The caption is not merely computable — the shipped `SubjectPickList`
    /// lays it out, as a line of its own that the footer did not have before.
    ///
    /// **Measured as height, because the text itself is unreadable from here,
    /// and that was checked rather than assumed.** A hosted `SubjectPickSheet`
    /// reports *zero* accessibility children (dumped: the `NSHostingView` is a
    /// bare `AXGroup`, and the view tree under it is `_FocusRingView`s and
    /// scroll plumbing with no label, value or title anywhere), so there is no
    /// string in this process to assert on. What a layout does answer is whether
    /// the line was built: with the stored pick supplied the list is one caption
    /// line taller, holding the pick model — and therefore the selection, the
    /// summary and the button — identical.
    ///
    /// It is **not** a claim that the caption is legible, unclipped or on
    /// screen; this project has measured four separate ways an offscreen render
    /// lies about that, and the running-app check in the report is what answers
    /// it.
    func testTheListLaysOutTheStoredStartAsItsOwnLine() {
        let model = SubjectPickModel(segments: segments, selected: storedIDs)
        let withCaption = listHeight(stored: pick(), pick: model)
        let without = listHeight(stored: nil, pick: model)

        XCTAssertGreaterThan(
            withCaption, without,
            "the stored start must occupy a line of the footer; the caption was not laid out at all"
        )
    }

    /// The link the test above cannot see: `SubjectPickSheet`'s ready state has
    /// to hand the *session's* stored pick down to that list.
    ///
    /// Kills the mutation of `stored: nil` in `ReadySection` — by construction,
    /// since the sheet is compared against both list heights and must equal the
    /// captioned one. The seeded selection is the same in both, so the two
    /// heights differ in the caption and nothing else.
    func testTheSheetHandsTheStoredPickToTheList() throws {
        let clip = try clipWithSidecar(subject: pick())
        let session = try loadedSession(for: clip)
        let model = SubjectPickModel(segments: segments, selected: storedIDs)
        let withCaption = listHeight(stored: pick(), pick: model)
        let without = listHeight(stored: nil, pick: model)
        XCTAssertNotEqual(
            withCaption, without,
            "precondition: the two list heights must differ, or this test cannot tell them apart"
        )

        let sheet = height(
            of: SubjectPickSheet(session: session, clip: clip, onConfirm: { _ in }), width: captionWidth
        )

        XCTAssertEqual(
            sheet, withCaption,
            "the sheet's ready state must render the list *with* the stored pick's caption"
        )
        XCTAssertNotEqual(
            sheet, without,
            "the sheet is rendering the list with no stored start; the caption never reaches the operator"
        )
    }

    // MARK: - Fixtures

    private var segments: [AnalysedSegment] {
        [1, 3, 4, 5, 6, 8, 15].enumerated().map { index, id in
            AnalysedSegment(
                id: id, firstSeen: Double(index) * 3, lastSeen: Double(index) * 3 + 2,
                detectionCount: 40, peakHeightFraction: 0.4, previews: []
            )
        }
    }

    /// `AnalysisParameters.current` with one value changed, which is all
    /// `isStale` asks about.
    private var olderParameters: AnalysisParameters {
        AnalysisParameters(
            fps: 25, detectionWidth: 256, initialJump: 0.06, speedMultiplier: 4.0,
            maxHeightRatio: 1.15, maxMisses: 10, cutOnAmbiguity: true, minSamples: 8
        )
    }

    private func pick(corrected: TimeInterval? = 18.29) -> SubjectPick {
        SubjectPick(segmentIDs: storedIDs, runStart: detected, correctedRunStart: corrected)
    }

    /// A sidecar on disk, which is the only way to reach a `.ready` session that
    /// is also `isStale` — `SubjectSessionModel.state` is `private(set)` and
    /// `analyse` always clears staleness.
    private func clipWithSidecar(
        subject: SubjectPick?, parameters: AnalysisParameters = .current
    ) throws -> URL {
        let clip = root.appendingPathComponent("C0094.MP4")
        try ClipAnalysisStore.save(
            ClipAnalysis(
                version: 1, analysedAt: Date(timeIntervalSince1970: 1_754_121_660),
                parameters: parameters, segments: segments, subject: subject
            ),
            for: clip
        )
        return clip
    }

    private func loadedSession(for clip: URL) throws -> SubjectSessionModel {
        let session = SubjectSessionModel()
        session.loadStored(for: clip)
        guard case .ready = session.state else {
            throw XCTSkip("precondition: the session must load the sidecar, got \(session.state)")
        }
        return session
    }

    /// Wide enough that the summary above the caption is one line either way,
    /// so a height difference is the caption and not a wrap somewhere else.
    private let captionWidth: CGFloat = 420

    private func listHeight(stored: SubjectPick?, pick: SubjectPickModel) -> CGFloat {
        height(
            of: SubjectPickList(
                pick: pick, stored: stored, clip: URL(fileURLWithPath: "/dev/null"),
                onConfirm: { _ in }
            ),
            width: captionWidth
        )
    }

    /// The natural height of a view laid out at a fixed width, in a real
    /// off-screen window — the technique `ComparisonLayoutMeasurementTests`
    /// uses, including its reason for a window: `NSHostingView` will not lay
    /// anything out without the shared application, and `fittingSize` before a
    /// layout pass reports the frame it was given rather than the one it needs.
    ///
    /// Measured when it stops changing, not after a fixed sleep. The two tests
    /// above compare heights for equality, so a height read mid-layout would
    /// fail them for a reason that has nothing to do with the caption — the
    /// same discipline `CorrectedStartEndToEndTests.settle` applies to seeks,
    /// and for the same reason.
    private func height(of view: some View, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: AnyView(view.frame(width: width)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 1200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        var previous = CGFloat.nan
        var stable = 0
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            let now = host.fittingSize.height
            stable = now == previous ? stable + 1 : 0
            previous = now
            if stable >= 3 { return now }
        }
        XCTFail("the hosted view's height never settled; the comparison below would be meaningless")
        return previous
    }
}
