import XCTest
@testable import SkiVideoCore

/// The whole feature against the real footage, end to end: analyse, pick the
/// athlete's segments, measure the run start, write the sidecar, then reopen
/// and prove the second visit costs nothing.
///
/// Gated behind `SKI_E2E=1` because it takes about a minute and writes a
/// sidecar next to the operator's footage. Neither belongs in a routine test
/// run; both are exactly what needs proving before the feature is believed.
///
///     SKI_E2E=1 swift test --filter SubjectSyncEndToEndTests
final class SubjectSyncEndToEndTests: XCTestCase {
    private static let root =
        "/Users/ulfnielsen/Ski/Neuss2026/organized/2026-07-19_Neuss"

    /// Ground truth supplied by the project owner.
    private struct Clip {
        let path: String
        let truth: TimeInterval
        /// The athlete's segments, identified by eye from the thumbnail strips
        /// during Phase A verification, expressed as the time span they cover
        /// so the ids can be re-derived rather than hard-coded.
        let span: ClosedRange<TimeInterval>
        let minimumDetections: Int
    }

    private static let clips = [
        Clip(path: "Idun Nielsen/C0094.MP4", truth: 19.0, span: 13.0...46.5, minimumDetections: 100),
        Clip(path: "Fabien Wiest/C0092.MP4", truth: 4.4, span: 0.0...26.5, minimumDetections: 40),
    ]

    private func requireEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SKI_E2E"] == "1",
            "set SKI_E2E=1 to run the end-to-end check"
        )
    }

    @MainActor
    func testTheWholeRoundTripOnRealFootage() async throws {
        try requireEnabled()

        for clip in Self.clips {
            let url = URL(fileURLWithPath: Self.root).appendingPathComponent(clip.path)
            try XCTSkipUnless(
                FileManager.default.fileExists(atPath: url.path),
                "footage not present: \(clip.path)"
            )
            // Start from nothing, so "reused the sidecar" cannot be an artefact
            // of a file left by an earlier run — but the operator's own pick
            // lives in that file, and it cost them twenty seconds and a
            // judgement no algorithm can make.
            //
            // An earlier version simply deleted it, and did exactly the damage
            // that invites: a run cancelled between the delete and the rewrite
            // left a clip with no sidecar and the pick gone. This moves it
            // aside and puts it back however the test ends.
            let sidecar = ClipAnalysisStore.sidecarURL(for: url)
            let saved = try? Data(contentsOf: sidecar)
            try? FileManager.default.removeItem(at: sidecar)
            defer {
                if let saved {
                    try? saved.write(to: sidecar, options: .atomic)
                }
            }

            let session = SubjectSessionModel()
            let firstVisit = Date()
            await session.analyse(clip: url)
            let analyseSeconds = -firstVisit.timeIntervalSinceNow

            let sessionAnalysis = session.analysis
            let analysis = try XCTUnwrap(sessionAnalysis, "\(clip.path): no analysis")
            // A time-span filter stands in for the operator's eye. It is
            // cruder than a person looking at the strips — on C0094 it also
            // catches the bystander, whose segment overlaps two of the
            // athlete's — so the candidates go through `SubjectPickModel`,
            // which applies the same overlap rule the sheet enforces. What
            // survives is a pick the UI would actually permit, rather than one
            // no operator could have made.
            let candidates = analysis.segments
                .filter {
                    $0.firstSeen >= clip.span.lowerBound
                        && $0.lastSeen <= clip.span.upperBound
                        && $0.detectionCount >= clip.minimumDetections
                }
                .map(\.id)
            let athlete = SubjectPickModel(
                segments: analysis.segments, selected: candidates
            ).selectedInTimeOrder

            XCTAssertGreaterThanOrEqual(
                athlete.count, 2, "\(clip.path): expected several segments for the athlete"
            )
            XCTAssertLessThan(
                athlete.count, candidates.count + 1,
                "\(clip.path): the overlap rule must not add segments"
            )
            // No two picked segments may overlap — that is the invariant the
            // whole pick rests on, and it is what makes the union one person.
            let picked = analysis.segments.filter { athlete.contains($0.id) }
            for (index, one) in picked.enumerated() {
                for other in picked.dropFirst(index + 1) {
                    XCTAssertFalse(
                        one.overlaps(other),
                        "\(clip.path): picked segments \(one.id) and \(other.id) overlap"
                    )
                }
            }

            let confirmStart = Date()
            let outcome = try await SubjectAnalyzer.runStart(
                clip: url, analysis: analysis, segmentIDs: athlete
            )
            let runStartSeconds = -confirmStart.timeIntervalSinceNow

            let stored: StoredRunStart
            switch outcome {
            case let .started(start):
                XCTAssertEqual(
                    start.time, clip.truth, accuracy: 1.0,
                    "\(clip.path): detected \(start.time)s against truth \(clip.truth)s"
                )
                stored = .started(
                    time: start.time, baseline: start.baseline, threshold: start.threshold
                )
            case let .alreadyRunning(firstSeen):
                stored = .alreadyRunning(firstSeen: firstSeen)
            default:
                return XCTFail("\(clip.path): unusable outcome \(outcome)")
            }

            try session.confirm(segmentIDs: athlete, runStart: stored, for: url)

            // The second visit: a fresh session, nothing in memory.
            let secondVisit = Date()
            let reopened = SubjectSessionModel()
            let restored = reopened.loadStored(for: url)
            let reloadSeconds = -secondVisit.timeIntervalSinceNow

            let subject = try XCTUnwrap(restored?.subject, "\(clip.path): sidecar lost the pick")
            XCTAssertEqual(subject.segmentIDs, athlete)
            XCTAssertEqual(subject.runStart.syncTime, stored.syncTime, accuracy: 1e-9)
            let reopenedIsStale = reopened.isStale
            XCTAssertFalse(reopenedIsStale, "\(clip.path): fresh analysis read as stale")

            // The point of the sidecar. Analysis is tens of seconds; a reload
            // that is not near-instant means the feature has not achieved what
            // it exists for.
            XCTAssertLessThan(
                reloadSeconds, 0.5,
                "\(clip.path): reopening took \(reloadSeconds)s — it re-analysed"
            )

            print(String(
                format: "E2E %@: analyse %.1fs · runStart %.1fs · reload %.3fs · "
                    + "%d segments, athlete %@ · sync at %.2fs (truth %.1fs)",
                clip.path, analyseSeconds, runStartSeconds, reloadSeconds,
                analysis.segments.count, athlete.map(String.init).joined(separator: "+"),
                stored.syncTime, clip.truth
            ))
        }
    }
}
