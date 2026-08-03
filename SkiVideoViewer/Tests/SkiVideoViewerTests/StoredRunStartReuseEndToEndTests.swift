import XCTest
@testable import SkiVideoCore
@testable import SkiVideoViewer

/// The reuse against the operator's own footage and the operator's own sidecar,
/// with the **real** `SubjectAnalyzer.runStart` behind the seam.
///
/// The unit tests above prove the decision with a stand-in. This proves the
/// thing that was reported: that confirming the pick already stored for
/// `Idun Nielsen/C0094.MP4` returns immediately instead of reading 290MB of
/// H.264 for twenty seconds — and that the 18.290s the operator corrected it to
/// is still what applies afterwards, not the 0.640s the detector produced.
///
/// Gated behind `SKI_E2E=1` for the same reasons `SubjectSyncEndToEndTests` is:
/// it needs the footage and it spends real minutes.
///
///     SKI_E2E=1 swift test --filter StoredRunStartReuseEndToEndTests
///
/// The clip and its sidecar are **cloned** into a scratch directory rather than
/// used in place. The second half of this test deliberately confirms a different
/// pick, which overwrites the sidecar; doing that to the operator's file would
/// destroy the correction this whole task exists to protect.
@MainActor
final class StoredRunStartReuseEndToEndTests: XCTestCase {
    private static let source =
        "/Users/ulfnielsen/Ski/Neuss2026/organized/2026-07-19_Neuss/Idun Nielsen/C0094.MP4"

    func testConfirmingTheStoredPickOnC0094IsImmediateAndKeepsTheCorrection() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SKI_E2E"] == "1",
            "set SKI_E2E=1 to run the real-footage check"
        )
        let original = URL(fileURLWithPath: Self.source)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: ClipAnalysisStore.sidecarURL(for: original).path),
            "C0094's sidecar is not present; there is no stored pick to reuse"
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let clip = root.appendingPathComponent(original.lastPathComponent)
        try FileManager.default.copyItem(at: original, to: clip)
        try FileManager.default.copyItem(
            at: ClipAnalysisStore.sidecarURL(for: original),
            to: ClipAnalysisStore.sidecarURL(for: clip)
        )

        let session = SubjectSessionModel()
        session.loadStored(for: clip)
        let stored = try XCTUnwrap(session.pickedSubject, "the cloned sidecar must hold the operator's pick")
        XCTAssertFalse(session.isStale, "precondition: the operator's sidecar is not stale")
        print("E2E C0094 stored: ids \(stored.segmentIDs), detected \(stored.runStart.syncTime)s, "
            + "corrected \(String(describing: stored.correctedRunStart))")
        print("E2E C0094 caption: \(SubjectPickList.storedStartCaption(for: stored) ?? "-")")

        // As the sheet hands them back: `selectedInTimeOrder`, which for this
        // clip is *not* the order the sidecar stores.
        let analysis = try XCTUnwrap(session.analysis)
        let asPicked = SubjectPickModel(
            segments: analysis.segments, selected: stored.segmentIDs
        ).selectedInTimeOrder
        XCTAssertEqual(Set(asPicked), Set(stored.segmentIDs), "precondition: the same segments")

        var passes = 0
        let began = Date()
        let outcome = try await ComparisonView.record(
            segmentIDs: asPicked, clip: clip, in: session,
            measuringWith: { clip, analysis, ids in
                passes += 1
                return try await SubjectAnalyzer.runStart(clip: clip, analysis: analysis, segmentIDs: ids)
            }
        )
        let elapsed = -began.timeIntervalSinceNow
        print(String(format: "E2E C0094 re-confirm: %.3fs, %d passes, outcome %@",
                     elapsed, passes, String(describing: outcome)))

        XCTAssertEqual(passes, 0, "confirming the stored pick re-read the clip; that is the reported twenty seconds")
        XCTAssertLessThan(elapsed, 0.5, "the reuse must be immediate, took \(elapsed)s")
        XCTAssertEqual(outcome, .reused(stored.syncTime))
        let after = try XCTUnwrap(session.pickedSubject)
        XCTAssertEqual(after.correctedRunStart, stored.correctedRunStart,
                       "the operator's correction must survive the re-confirm")
        XCTAssertEqual(after.syncTime, stored.syncTime, accuracy: 1e-9,
                       "the effective start must still be the corrected one")
        XCTAssertEqual(after.runStart.syncTime, stored.runStart.syncTime, accuracy: 1e-9,
                       "the measurement must still be beside it")

        // The other half: a different pick is a different question, and it does
        // run the pass.
        let fewer = Array(asPicked.dropLast())
        let secondBegan = Date()
        let second = try await ComparisonView.record(
            segmentIDs: fewer, clip: clip, in: session,
            measuringWith: { clip, analysis, ids in
                passes += 1
                return try await SubjectAnalyzer.runStart(clip: clip, analysis: analysis, segmentIDs: ids)
            }
        )
        let secondElapsed = -secondBegan.timeIntervalSinceNow
        print(String(format: "E2E C0094 changed pick: %.1fs, %d passes total, outcome %@",
                     secondElapsed, passes, String(describing: second)))

        XCTAssertEqual(passes, 1, "a different set of segments must be measured")
        XCTAssertGreaterThan(secondElapsed, 1.0, "the real pass cannot complete in \(secondElapsed)s")
        XCTAssertNil(try XCTUnwrap(session.pickedSubject).correctedRunStart,
                     "a fresh measurement is not the start the correction was made against")
    }
}
