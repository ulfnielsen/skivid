import XCTest
@testable import SkiVideoCore

final class ClipAnalysisTests: XCTestCase {
    private func parameters(fps: Double = 25) -> AnalysisParameters {
        AnalysisParameters(
            fps: fps, detectionWidth: 320, initialJump: 0.06, speedMultiplier: 4.0,
            maxHeightRatio: 1.15, maxMisses: 10, cutOnAmbiguity: true, minSamples: 8
        )
    }

    private func analysis(runStart: StoredRunStart?) -> ClipAnalysis {
        ClipAnalysis(
            version: 1,
            analysedAt: Date(timeIntervalSince1970: 1_754_121_660),
            parameters: parameters(),
            segments: [
                AnalysedSegment(
                    id: 1, firstSeen: 29.92, lastSeen: 46.32,
                    detectionCount: 408, peakHeightFraction: 0.53,
                    previews: [
                        SegmentPreview(time: 29.92, box: CGRect(x: 0.55, y: 0.15, width: 0.07, height: 0.17)),
                        SegmentPreview(time: 39.41, box: CGRect(x: 0.61, y: 0.13, width: 0.11, height: 0.29)),
                    ]
                ),
            ],
            subject: runStart.map { SubjectPick(segmentIDs: [3, 4, 5, 1], runStart: $0) }
        )
    }

    func testRoundTripsAStartedRunStart() throws {
        let original = analysis(runStart: .started(time: 18.64, baseline: 1.89, threshold: 3.39))
        let decoded = try JSONDecoder().decode(
            ClipAnalysis.self, from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded.segments.first?.previews.last?.box.height ?? 0, 0.29, accuracy: 1e-9)
        XCTAssertEqual(decoded.subject?.segmentIDs, [3, 4, 5, 1])
        guard case let .started(time, baseline, threshold) = decoded.subject?.runStart else {
            return XCTFail("expected started, got \(String(describing: decoded.subject?.runStart))")
        }
        XCTAssertEqual(time, 18.64, accuracy: 1e-9)
        XCTAssertEqual(baseline, 1.89, accuracy: 1e-9)
        XCTAssertEqual(threshold, 3.39, accuracy: 1e-9)
    }

    func testRoundTripsAnAlreadyRunningRunStart() throws {
        let original = analysis(runStart: .alreadyRunning(firstSeen: 0.12))
        let decoded = try JSONDecoder().decode(
            ClipAnalysis.self, from: JSONEncoder().encode(original)
        )

        guard case let .alreadyRunning(firstSeen) = decoded.subject?.runStart else {
            return XCTFail("expected alreadyRunning")
        }
        XCTAssertEqual(firstSeen, 0.12, accuracy: 1e-9)
    }

    func testRoundTripsWithNoSubjectPicked() throws {
        let decoded = try JSONDecoder().decode(
            ClipAnalysis.self, from: JSONEncoder().encode(analysis(runStart: nil))
        )
        XCTAssertNil(decoded.subject)
        XCTAssertEqual(decoded.segments.count, 1)
    }

    func testAnUnknownRunStartKindFailsToDecode() throws {
        // A later version may add a kind. Decoding must fail loudly rather
        // than silently becoming `started` at time zero, which would apply a
        // wrong sync point with no indication anything went wrong.
        var json = String(
            data: try JSONEncoder().encode(
                analysis(runStart: .started(time: 18.64, baseline: 1.89, threshold: 3.39))
            ),
            encoding: .utf8
        )!
        json = json.replacingOccurrences(of: "\"started\"", with: "\"teleported\"")

        XCTAssertThrowsError(
            try JSONDecoder().decode(ClipAnalysis.self, from: Data(json.utf8))
        )
    }

    func testParametersMatchingIsExactAndOrderIndependent() {
        XCTAssertTrue(parameters().matches(parameters()))
        XCTAssertFalse(parameters(fps: 30).matches(parameters(fps: 25)))
    }

    func testStalenessIsReportedWithoutMutatingTheAnalysis() {
        let stored = analysis(runStart: .started(time: 18.64, baseline: 1.89, threshold: 3.39))
        let current = parameters(fps: 30)

        XCTAssertTrue(stored.isStale(against: current))
        // The pick and the time survive: a run start is a time and a time does
        // not expire, and the pick is expensive human input.
        XCTAssertEqual(stored.subject?.segmentIDs, [3, 4, 5, 1])
        XCTAssertFalse(stored.isStale(against: parameters()))
    }
}
