import XCTest
@testable import SkiVideoCore

@MainActor
final class SubjectSessionModelTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func analysis(subject: SubjectPick?) -> ClipAnalysis {
        ClipAnalysis(
            version: 1, analysedAt: Date(timeIntervalSince1970: 1_754_121_660),
            parameters: .current,
            segments: [
                AnalysedSegment(id: 1, firstSeen: 3.1, lastSeen: 9.7, detectionCount: 214,
                                peakHeightFraction: 0.41, previews: []),
                AnalysedSegment(id: 2, firstSeen: 11.4, lastSeen: 18.2, detectionCount: 137,
                                peakHeightFraction: 0.29, previews: []),
            ],
            subject: subject
        )
    }

    private func clip(_ name: String = "C0094.MP4") -> URL {
        directory.appendingPathComponent(name)
    }

    func testAStoredAnalysisIsReusedWithoutAnalysingAgain() throws {
        try ClipAnalysisStore.save(analysis(subject: nil), for: clip())
        let session = SubjectSessionModel()

        let reused = session.loadStored(for: clip())

        XCTAssertNotNil(reused)
        XCTAssertEqual(reused?.segments.count, 2)
        guard case .ready = session.state else {
            return XCTFail("expected ready, got \(session.state)")
        }
    }

    func testNoSidecarLeavesTheSessionIdle() {
        let session = SubjectSessionModel()

        XCTAssertNil(session.loadStored(for: clip()))
        guard case .idle = session.state else {
            return XCTFail("expected idle, got \(session.state)")
        }
    }

    func testConfirmingAPickWritesItToTheSidecar() throws {
        try ClipAnalysisStore.save(analysis(subject: nil), for: clip())
        let session = SubjectSessionModel()
        _ = session.loadStored(for: clip())

        try session.confirm(
            segmentIDs: [2, 1],
            runStart: .started(time: 4.42, baseline: 1.12, threshold: 2.02),
            for: clip()
        )

        let reloaded = ClipAnalysisStore.load(for: clip())
        XCTAssertEqual(reloaded?.subject?.segmentIDs, [2, 1])
        XCTAssertEqual(reloaded?.subject?.runStart.syncTime ?? 0, 4.42, accuracy: 1e-9)
    }

    func testAnUnwritableFolderStillLeavesThePickUsableInMemory() throws {
        try ClipAnalysisStore.save(analysis(subject: nil), for: clip())
        let session = SubjectSessionModel()
        _ = session.loadStored(for: clip())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: directory.path
            )
        }

        // Persistence failing is not analysis failing: the operator has just
        // done the expensive part and must not lose it because the footage sits
        // on a read-only volume.
        XCTAssertThrowsError(
            try session.confirm(
                segmentIDs: [1],
                runStart: .alreadyRunning(firstSeen: 0.12),
                for: clip()
            )
        )
        XCTAssertEqual(session.pickedSubject?.segmentIDs, [1])
    }

    func testStalenessIsSurfacedWithoutDiscardingThePick() throws {
        var older = AnalysisParameters.current
        older = AnalysisParameters(
            fps: 30, detectionWidth: older.detectionWidth, initialJump: older.initialJump,
            speedMultiplier: older.speedMultiplier, maxHeightRatio: older.maxHeightRatio,
            maxMisses: older.maxMisses, cutOnAmbiguity: older.cutOnAmbiguity,
            minSamples: older.minSamples
        )
        let stale = ClipAnalysis(
            version: 1, analysedAt: Date(timeIntervalSince1970: 1_754_121_660),
            parameters: older, segments: analysis(subject: nil).segments,
            subject: SubjectPick(
                segmentIDs: [1],
                runStart: .started(time: 4.42, baseline: 1.12, threshold: 2.02)
            )
        )
        try ClipAnalysisStore.save(stale, for: clip())
        let session = SubjectSessionModel()

        let loaded = session.loadStored(for: clip())

        XCTAssertTrue(session.isStale)
        XCTAssertEqual(loaded?.subject?.segmentIDs, [1], "a stale pick is kept, not dropped")
    }
}
