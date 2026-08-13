import Combine
import XCTest
@testable import SkiVideoCore

/// A struct unrelated to `SubjectAnalyzer.AnalysisError`, standing in for the
/// error case most likely to fall through an incomplete `catch` — one the
/// model's own error type doesn't already special-case.
private struct FakeUnrelatedError: Error {}

/// Serializes call counting across the concurrent `analyse(clip:)` calls in
/// `testAnalysingTwiceCancelsTheFirstRun`, since the fake's closure is
/// `@Sendable` and both calls run on the same `SubjectSessionModel` instance.
private actor CallCounter {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

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

    /// The write path for a corrected start: the correction lands in the
    /// sidecar and the measurement it corrects is still there beside it.
    ///
    /// Both are asserted, with different values, for the same reason the
    /// round-trip test asserts both — a `confirm` that let the correction
    /// overwrite `runStart` would satisfy an assertion on either one alone.
    func testCorrectingAStartKeepsTheMeasuredOneBesideIt() throws {
        try ClipAnalysisStore.save(analysis(subject: nil), for: clip())
        let session = SubjectSessionModel()
        _ = session.loadStored(for: clip())
        let measured = StoredRunStart.started(time: 4.42, baseline: 1.12, threshold: 2.02)
        try session.confirm(segmentIDs: [2, 1], runStart: measured, for: clip())
        XCTAssertNil(session.pickedSubject?.correctedRunStart, "precondition: a fresh pick has no correction")

        try session.confirm(
            segmentIDs: [2, 1], runStart: measured, correctedRunStart: 2.62, for: clip()
        )

        let reloaded = ClipAnalysisStore.load(for: clip())
        XCTAssertEqual(reloaded?.subject?.correctedRunStart ?? .nan, 2.62, accuracy: 1e-9)
        XCTAssertEqual(reloaded?.subject?.runStart.syncTime ?? .nan, 4.42, accuracy: 1e-9,
                       "the detected start must survive the correction, or the detector's error becomes invisible")
        XCTAssertEqual(reloaded?.subject?.syncTime ?? .nan, 2.62, accuracy: 1e-9,
                       "the correction is what applies")
        XCTAssertEqual(session.pickedSubject?.correctedRunStart ?? .nan, 2.62, accuracy: 1e-9,
                       "and it must be in memory too, not only on disk")
    }

    /// A correction is made to a particular measurement, so confirming a *new*
    /// pick — a second run of the sheet, with a freshly detected start — must
    /// not carry the old correction onto it.
    func testConfirmingAFreshPickDropsAnEarlierCorrection() throws {
        try ClipAnalysisStore.save(analysis(subject: nil), for: clip())
        let session = SubjectSessionModel()
        _ = session.loadStored(for: clip())
        try session.confirm(
            segmentIDs: [1], runStart: .started(time: 4.42, baseline: 1.12, threshold: 2.02),
            correctedRunStart: 2.62, for: clip()
        )

        try session.confirm(
            segmentIDs: [2], runStart: .started(time: 11.9, baseline: 1.4, threshold: 2.5),
            for: clip()
        )

        XCTAssertNil(ClipAnalysisStore.load(for: clip())?.subject?.correctedRunStart)
        XCTAssertEqual(session.pickedSubject?.syncTime ?? .nan, 11.9, accuracy: 1e-9)
    }

    /// The rule that makes a failed write survivable applies to a correction
    /// too: it is in memory before the disk is touched.
    func testAnUnwritableFolderStillLeavesACorrectionUsableInMemory() throws {
        try ClipAnalysisStore.save(analysis(subject: nil), for: clip())
        let session = SubjectSessionModel()
        _ = session.loadStored(for: clip())
        let measured = StoredRunStart.started(time: 4.42, baseline: 1.12, threshold: 2.02)
        try session.confirm(segmentIDs: [1], runStart: measured, for: clip())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: directory.path
            )
        }

        XCTAssertThrowsError(
            try session.confirm(
                segmentIDs: [1], runStart: measured, correctedRunStart: 2.62, for: clip()
            )
        )
        XCTAssertEqual(session.pickedSubject?.syncTime ?? .nan, 2.62, accuracy: 1e-9,
                       "an unwritable folder must not cost the operator the adjustment they just made")
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

    // MARK: - analyse(clip:) transitions

    func testASuccessfulRunEndsReadyAndPublishesProgressToOne() async {
        let expected = analysis(subject: nil)
        let session = SubjectSessionModel(analyse: { _, progress in
            progress(0.28)
            progress(0.71)
            progress(1.0)
            return expected
        })

        var observedProgress: [Double] = []
        let subscription = session.$state.sink { state in
            if case let .analysing(progress) = state {
                observedProgress.append(progress)
            }
        }
        defer { subscription.cancel() }

        await session.analyse(clip: clip())

        guard case let .ready(result) = session.state else {
            return XCTFail("expected ready, got \(session.state)")
        }
        XCTAssertEqual(result, expected)
        XCTAssertEqual(observedProgress.last, 1.0, "progress must reach 1.0 before the run reports ready")
    }

    func testCancellationReturnsToIdleNotFailed() async {
        let session = SubjectSessionModel(analyse: { _, _ in
            throw CancellationError()
        })

        await session.analyse(clip: clip())

        guard case .idle = session.state else {
            return XCTFail("a cancelled run must return to idle, not failed; got \(session.state)")
        }
    }

    func testAKnownAnalysisFailureEndsFailedWithItsDescription() async {
        let underlying = SubjectAnalyzer.AnalysisError.noPeopleFound("C0094.MP4")
        let session = SubjectSessionModel(analyse: { _, _ in
            throw underlying
        })

        await session.analyse(clip: clip())

        guard case let .failed(message) = session.state else {
            return XCTFail("expected failed, got \(session.state)")
        }
        XCTAssertEqual(message, underlying.description)
        XCTAssertEqual(message, "no people were detected in C0094.MP4",
                        "the operator sees this string verbatim, not a Swift enum dump")
    }

    func testAnUnexpectedErrorNeverLeavesStateAnalysing() async {
        let session = SubjectSessionModel(analyse: { _, _ in
            throw FakeUnrelatedError()
        })

        await session.analyse(clip: clip())

        if case .analysing = session.state {
            XCTFail("state must never be left on .analysing after the analysis function throws")
        }
        guard case .failed = session.state else {
            return XCTFail("expected failed, got \(session.state)")
        }
    }

    func testCancelWhileIdleIsHarmless() {
        let session = SubjectSessionModel()

        session.cancel()

        guard case .idle = session.state else {
            return XCTFail("expected idle, got \(session.state)")
        }
    }

    func testAnalysingTwiceCancelsTheFirstRun() async {
        let second = analysis(subject: SubjectPick(
            segmentIDs: [2], runStart: .alreadyRunning(firstSeen: 0.63)
        ))
        let counter = CallCounter()
        let session = SubjectSessionModel(analyse: { _, _ in
            let callNumber = await counter.next()
            if callNumber == 1 {
                // Never completes on its own; only cancellation ends it.
                while true {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
            }
            return second
        })

        let firstRun = Task { await session.analyse(clip: self.clip("first.MP4")) }
        // Give the first run time to start its loop before superseding it.
        try? await Task.sleep(nanoseconds: 30_000_000)

        await session.analyse(clip: clip("second.MP4"))
        // Let the first run's cancellation finish unwinding before asserting,
        // so a bug that lets it clobber state afterward would be caught here
        // rather than racing the assertion below.
        _ = await firstRun.value

        guard case let .ready(result) = session.state else {
            return XCTFail(
                "expected the second run's result, got \(session.state) " +
                "(a superseded first run must not overwrite state once cancelled)"
            )
        }
        XCTAssertEqual(result, second)
    }

    /// A *local* clip's analysis must never route to the keyed store, and the
    /// model must keep reaching the stores through an identity.
    ///
    /// Drives both call sites this task changes — `loadStored` reads,
    /// `confirm` writes — with the keyed store pointed at a directory that
    /// does not exist, so a stray write there shows up as that directory
    /// appearing. Asserting on `ClipAnalysisStore` directly would prove
    /// nothing about the model: it is the model's two calls that are being
    /// switched over, so the model is what the test has to drive.
    ///
    /// This is the assertion the pre-existing round-trip tests cannot make.
    /// `testAStoredAnalysisIsReusedWithoutAnalysingAgain` and
    /// `testConfirmingAPickWritesItToTheSidecar` would both still pass if the
    /// model *also* wrote a copy into the keyed store.
    func testTheModelNeverTouchesTheKeyedStoreForALocalClip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let previous = ClipIdentity.keyedStoreRoot
        ClipIdentity.keyedStoreRoot = root
        defer {
            ClipIdentity.keyedStoreRoot = previous
            try? FileManager.default.removeItem(at: root)
        }

        try ClipAnalysisStore.save(analysis(subject: nil), for: clip())
        let session = SubjectSessionModel()

        XCTAssertNotNil(session.loadStored(for: clip()))
        try session.confirm(
            segmentIDs: [1],
            runStart: .started(time: 4.42, baseline: 1.12, threshold: 2.02),
            for: clip()
        )

        XCTAssertEqual(ClipAnalysisStore.load(for: clip())?.subject?.segmentIDs, [1])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.path),
            "a local clip's analysis must stay beside the footage"
        )
    }
}
