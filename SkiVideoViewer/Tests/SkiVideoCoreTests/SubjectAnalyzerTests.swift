import XCTest
@testable import SkiVideoCore

final class SubjectAnalyzerTests: XCTestCase {
    /// Ground truth supplied by the project owner: the athlete's run in this
    /// clip starts at 19.0s.
    private static let clip = URL(fileURLWithPath:
        "/Users/ulfnielsen/Ski/Neuss2026/organized/2026-07-19_Neuss/Idun Nielsen/C0094.MP4")

    private func requireClip() throws -> URL {
        try requireSlowTestsEnabled()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.clip.path),
            "ground-truth footage not present on this machine"
        )
        return Self.clip
    }

    func testFindsSegmentsCoveringTheAthletesRun() async throws {
        let analysis = try await SubjectAnalyzer.analyse(clip: try requireClip())

        XCTAssertFalse(analysis.segments.isEmpty)
        XCTAssertNil(analysis.subject)
        XCTAssertTrue(analysis.segments.allSatisfy { $0.detectionCount >= 8 })
        XCTAssertTrue(analysis.segments.allSatisfy { $0.previews.count <= 5 })
        // The athlete's run is 19.0-46.3s; some segment must reach the end.
        XCTAssertTrue(
            analysis.segments.contains { $0.lastSeen > 45.0 },
            "expected a segment running to the end of the clip"
        )
    }

    func testProgressRunsFromAboveZeroToOne() async throws {
        let clip = try requireClip()
        actor Recorder {
            var values: [Double] = []
            func record(_ value: Double) { values.append(value) }
        }
        let recorder = Recorder()
        _ = try await SubjectAnalyzer.analyse(clip: clip) { value in
            Task { await recorder.record(value) }
        }
        let values = await recorder.values

        XCTAssertGreaterThan(values.count, 100)
        XCTAssertEqual(values.last ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertTrue(values.allSatisfy { $0 > 0 && $0 <= 1.0 })
    }

    func testCancellationStopsTheAnalysis() async throws {
        let clip = try requireClip()
        let task = Task { try await SubjectAnalyzer.analyse(clip: clip) }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
    }

    func testRunStartOnThePickedSegmentsMatchesGroundTruth() async throws {
        let clip = try requireClip()
        let analysis = try await SubjectAnalyzer.analyse(clip: clip)
        // The athlete's segments, by the ranges established during
        // verification: 13.8-20.1, 20.1-24.5, 25.0-29.9, 29.9-46.3.
        let athlete = analysis.segments
            .filter { $0.firstSeen >= 13.0 && $0.lastSeen <= 46.5 && $0.detectionCount > 100 }
            .map(\.id)
        XCTAssertGreaterThanOrEqual(athlete.count, 3)

        let outcome = try await SubjectAnalyzer.runStart(
            clip: clip, analysis: analysis, segmentIDs: athlete
        )
        guard case let .started(start) = outcome else {
            return XCTFail("expected a measured start, got \(outcome)")
        }
        XCTAssertEqual(start.time, 19.0, accuracy: 1.0)
    }
}
