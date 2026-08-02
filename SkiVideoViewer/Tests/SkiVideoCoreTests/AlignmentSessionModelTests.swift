import CoreGraphics
import XCTest
@testable import SkiVideoCore

/// A struct unrelated to `AlignmentAnalyzer.AnalysisError`, standing in for the
/// error case most likely to fall through an incomplete `catch` — one the
/// model's own error type does not already special-case.
private struct FakeUnrelatedError: Error {}

/// Serializes call counting across the concurrent `compute` calls in
/// `testComputingTwiceCancelsTheFirstRun`, since the fake's closure is
/// `@Sendable` and both calls run on the same model instance.
private actor CallCounter {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

@MainActor
final class AlignmentSessionModelTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: directory.path
        )
        try? FileManager.default.removeItem(at: directory)
    }

    private var left: URL { directory.appendingPathComponent("C0094.MP4") }
    private var right: URL { directory.appendingPathComponent("C0092.MP4") }

    /// A track at the pass's real 25 Hz, with a translation that grows so the
    /// sample a lookup landed on is identifiable from its value alone.
    private func track(
        overlaps: [Double],
        leftStart: TimeInterval = 18.56,
        rightStart: TimeInterval = 4.40
    ) -> AlignmentTrack {
        AlignmentTrack(
            version: 1, computedAt: Date(timeIntervalSince1970: 1_754_140_000),
            leftClip: left.lastPathComponent, rightClip: right.lastPathComponent,
            leftStart: leftStart, rightStart: rightStart, parameters: .current,
            samples: overlaps.enumerated().map { index, overlap in
                AlignmentSample(
                    time: Double(index) * 0.04,
                    translation: CGVector(
                        dx: 0.02 + Double(index) * 0.004,
                        dy: -0.01 - Double(index) * 0.003
                    ),
                    overlap: overlap, residual: 5.0, identityResidual: 9.0
                )
            }
        )
    }

    /// The measured shape of the real pair, compressed: a healthy opening, the
    /// low-overlap stretch the gate exists to catch, and the recovery that
    /// disproved the lab exporter's latch.
    private func realisticTrack() -> AlignmentTrack {
        track(overlaps:
            [Double](repeating: 0.85, count: 25)
                + [Double](repeating: 0.22, count: 100)
                + [Double](repeating: 0.81, count: 50)
        )
    }

    private func healthyTrack() -> AlignmentTrack {
        track(overlaps: [Double](repeating: 0.85, count: 60))
    }

    private func ready(_ stored: AlignmentTrack) throws -> AlignmentSessionModel {
        try AlignmentTrackStore.save(stored, left: left, right: right)
        let session = AlignmentSessionModel()
        session.loadStored(
            left: left, right: right,
            leftStart: stored.leftStart, rightStart: stored.rightStart
        )
        return session
    }

    // MARK: - Loading

    func testAStoredTrackIsReusedWithoutComputingAgain() throws {
        let session = try ready(healthyTrack())

        guard case let .ready(loaded) = session.state else {
            return XCTFail("expected ready, got \(session.state)")
        }
        XCTAssertEqual(loaded.samples.count, 60)
        XCTAssertTrue(session.canAlign)
        XCTAssertNil(session.alignmentUnavailableReason)
    }

    func testNoSidecarLeavesTheSessionIdleAndSaysWhyAlignmentIsUnavailable() {
        let session = AlignmentSessionModel()

        XCTAssertNil(session.loadStored(left: left, right: right, leftStart: 18.56, rightStart: 4.40))
        guard case .idle = session.state else {
            return XCTFail("expected idle, got \(session.state)")
        }
        XCTAssertFalse(session.canAlign)
        // The operator reads this string off a disabled control; it has to name
        // the action that would fix it.
        let reason = session.alignmentUnavailableReason ?? ""
        XCTAssertTrue(
            reason.lowercased().contains("compute"),
            "the disabled Align control must say what to do about it: \(reason)"
        )
    }

    /// A track computed against different run starts describes a *different*
    /// comparison. Unlike a stale subject pick — which is kept and used, because
    /// a human made it — this one must not be applied: it would move the wrong
    /// clip by the wrong amount at the wrong instant.
    func testATrackComputedForDifferentRunStartsIsStaleAndDisablesAlignment() throws {
        let stored = healthyTrack()
        try AlignmentTrackStore.save(stored, left: left, right: right)
        let session = AlignmentSessionModel()

        // 0.20s out, well past the 0.01s tolerance `isStale` allows for JSON
        // round-tripping and a two-decimal detector.
        let loaded = session.loadStored(
            left: left, right: right, leftStart: 18.76, rightStart: 4.40
        )

        XCTAssertNotNil(loaded, "a stale track is still loaded, not dropped")
        XCTAssertTrue(session.isStale)
        XCTAssertFalse(session.canAlign)
        XCTAssertNil(
            session.translation(at: 0.4),
            "a stale track must not be applied, however healthy its overlap"
        )
        let reason = session.alignmentUnavailableReason ?? ""
        XCTAssertTrue(
            reason.lowercased().contains("run start"),
            "the reason must name the run starts, which is the thing that changed: \(reason)"
        )
    }

    func testATrackWithinTheStalenessToleranceIsUsable() throws {
        let stored = healthyTrack()
        try AlignmentTrackStore.save(stored, left: left, right: right)
        let session = AlignmentSessionModel()

        session.loadStored(left: left, right: right, leftStart: 18.565, rightStart: 4.404)

        XCTAssertFalse(session.isStale)
        XCTAssertTrue(session.canAlign)
    }

    func testResetForgetsTheTrack() throws {
        let session = try ready(healthyTrack())
        XCTAssertNotNil(session.translation(at: 0.4))

        session.reset()

        guard case .idle = session.state else {
            return XCTFail("expected idle, got \(session.state)")
        }
        XCTAssertNil(
            session.translation(at: 0.4),
            "a track kept past a change of pair would answer for a comparison it does not describe"
        )
    }

    // MARK: - The gate is honoured

    /// **The mutation this exists for: applying the raw sample instead of
    /// asking the gate.** The middle of this track is the measured low-overlap
    /// stretch, where the registration is not wrong but the cameras are looking
    /// at different parts of the hill — the samples there carry large
    /// translations that would put one clip in the corner of the frame.
    func testALowOverlapStretchIsDrawnUnaligned() throws {
        let session = try ready(realisticTrack())

        // Sample 60 of 175, deep inside the bad stretch and clear of the ease
        // that follows the disengage at sample 25.
        XCTAssertNil(
            session.translation(at: 2.4),
            "the raw sample was applied through a stretch the gate disengaged on"
        )
        // ...while the healthy stretches on either side are aligned, so the
        // assertion above is not passing because nothing is ever aligned.
        XCTAssertNotNil(session.translation(at: 0.6), "the healthy opening was not aligned")
        XCTAssertNotNil(session.translation(at: 5.6), "the recovery was not aligned")
    }

    /// The cache is only legitimate if it *is* the gate. Built by asking the
    /// real gate at every sample, so this is a tautology today — and it is
    /// exactly what stops it becoming a hand-rolled second implementation
    /// tomorrow.
    func testTheResolvedTrackAgreesWithTheGateAtEverySample() throws {
        let stored = realisticTrack()
        let session = try ready(stored)

        for sample in stored.samples {
            assertAgreesWithGate(session, stored, at: sample.time)
        }
    }

    /// Between samples, and against the gate rather than against a formula, so
    /// the interpolation cannot quietly become a staircase. The two ends of the
    /// track's engaged runs are excluded — see `ResolvedAlignment` for the one
    /// documented approximation, at the far end of the ease.
    func testLookupsBetweenSamplesFollowTheGate() throws {
        let stored = healthyTrack()
        let session = try ready(stored)

        for step in stride(from: 0.01, through: 2.3, by: 0.017) {
            assertAgreesWithGate(session, stored, at: step)
        }
    }

    /// The one place the cache is allowed to differ from the gate — bounded and
    /// measured rather than asserted away.
    ///
    /// A track with a disengage, an ease and a re-engage, swept every
    /// millisecond. The disagreement is confined to the single 40 ms gap the
    /// ease's zero-crossing falls inside, because the cache's ease reaches zero
    /// at the far end of that gap instead of part way through it: measured,
    /// they part company for 0.040 s and by at most 0.0035 normalised widths —
    /// about 2.8pt on an 800pt video area.
    ///
    /// Both bounds are asserted as arithmetic worst cases rather than as the
    /// measured figures, so a change of fixture does not have to move them: the
    /// magnitude is one sample of a 0.25 s ease (16%) of the disengaging
    /// translation, 0.116 here, and the duration is two sample intervals.
    func testTheCacheDiffersFromTheGateOnlyAcrossTheEndOfAnEase() throws {
        let stored = realisticTrack()
        let session = try ready(stored)

        let step = 0.001
        var largest = 0.0
        var disagreeing = 0
        var time = 0.0
        while time <= stored.samples[stored.samples.count - 1].time {
            let gate = AlignmentGate.translation(in: stored, at: time) ?? .zero
            let cached = session.translation(at: time) ?? .zero
            let delta = max(abs(gate.dx - cached.dx), abs(gate.dy - cached.dy))
            if delta > 1e-9 {
                disagreeing += 1
                largest = max(largest, delta)
            }
            time += step
        }

        XCTAssertLessThanOrEqual(
            largest, 0.116 * 0.16,
            "the cache and the gate part company by \(largest) normalised widths, "
                + "which is more than the tail of one ease"
        )
        XCTAssertLessThanOrEqual(
            Double(disagreeing) * step, 0.08,
            "the cache and the gate disagree for \(Double(disagreeing) * step)s, "
                + "which is more than the one inter-sample gap an ease can end inside"
        )
    }

    /// Nil-ness first, values only when both are there: comparing `?? .nan`
    /// against `?? .nan` reports a failure for two identical identity answers,
    /// since NaN is equal to nothing including itself.
    private func assertAgreesWithGate(
        _ session: AlignmentSessionModel,
        _ stored: AlignmentTrack,
        at time: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = AlignmentGate.translation(in: stored, at: time)
        let actual = session.translation(at: time)
        XCTAssertEqual(
            actual == nil, expected == nil,
            "aligned/unaligned disagrees with the gate at t=\(time)",
            file: file, line: line
        )
        guard let expected, let actual else { return }
        XCTAssertEqual(
            actual.dx, expected.dx, accuracy: 1e-12,
            "dx disagrees with the gate at t=\(time)", file: file, line: line
        )
        XCTAssertEqual(
            actual.dy, expected.dy, accuracy: 1e-12,
            "dy disagrees with the gate at t=\(time)", file: file, line: line
        )
    }

    func testOutsideTheMeasuredSpanNothingIsAlignedAndNothingIsClaimed() throws {
        let session = try ready(healthyTrack())

        // The pass covers a fixed window from the run start; past its end
        // holding the last translation is the stale-warp failure the gate
        // refuses, and before the start nothing was measured at all.
        XCTAssertNil(session.translation(at: -1))
        XCTAssertNil(session.translation(at: 30))
        XCTAssertFalse(session.covers(-1))
        XCTAssertFalse(session.covers(30))
        XCTAssertTrue(session.covers(1.0))
    }

    /// The status chip's condition. "Nothing was measured out here" and "this
    /// was measured and judged unalignable" both draw the clips unaligned and
    /// mean opposite things to an operator, so they must not collapse into one
    /// answer.
    func testDisengagedIsDistinguishedFromOutsideTheTrack() throws {
        let session = try ready(realisticTrack())

        XCTAssertTrue(session.isDisengaged(at: 2.4), "a measured, gated-off stretch must say so")
        XCTAssertFalse(session.isDisengaged(at: 0.6), "an aligned stretch is not disengaged")
        XCTAssertFalse(session.isDisengaged(at: 30), "past the track there is nothing to explain")
    }

    func testTurningAlignmentOffDrawsThePairUnaligned() throws {
        let session = try ready(healthyTrack())
        XCTAssertNotNil(session.translation(at: 0.6))

        session.isAligned = false

        XCTAssertNil(session.translation(at: 0.6))
        XCTAssertFalse(
            session.isDisengaged(at: 0.6),
            "the operator switching alignment off is not the gate disengaging, and must not be explained as it"
        )
        XCTAssertTrue(session.canAlign, "the track is still there; only the switch moved")
    }

    /// The renderer asks this ten times a second against a 425-sample track, so
    /// the lookup has to be a lookup. Calling `AlignmentGate.translation`
    /// directly is O(samples) — it walks the whole overlap history, because
    /// that is what a hysteretic gate means — and 4,000 such calls on a track
    /// this size took 4.5 s when measured, against 0.006 s through the cache.
    /// The bound below is ~30× the measured figure, so it fails on a
    /// reintroduced linear scan and not on a slow machine.
    func testLookupsDoNotRewalkTheTrack() throws {
        let stored = track(overlaps: (0..<425).map { $0 % 50 < 30 ? 0.85 : 0.22 })
        let session = try ready(stored)

        let started = Date()
        var aligned = 0
        for step in 0..<4_000 {
            if session.translation(at: Double(step) * 0.004) != nil { aligned += 1 }
        }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertGreaterThan(aligned, 0, "the sweep must actually be hitting engaged stretches")
        XCTAssertLessThan(
            elapsed, 0.2,
            "4,000 lookups took \(elapsed)s; the gate is being re-walked per query"
        )
    }

    // MARK: - compute transitions

    func testASuccessfulPassEndsReadyAndPublishesProgressToOne() async throws {
        let expected = healthyTrack()
        let session = AlignmentSessionModel(compute: { _, _, _, _, progress in
            progress(0.28)
            progress(0.71)
            progress(1.0)
            return expected
        })

        var observedProgress: [Double] = []
        let subscription = session.$state.sink { state in
            if case let .computing(progress) = state { observedProgress.append(progress) }
        }
        defer { subscription.cancel() }

        await session.compute(left: left, right: right, leftStart: 18.56, rightStart: 4.40)

        guard case let .ready(result) = session.state else {
            return XCTFail("expected ready, got \(session.state)")
        }
        XCTAssertEqual(result, expected)
        XCTAssertEqual(
            observedProgress.last, 1.0,
            "progress must reach 1.0 before the pass reports ready"
        )
        XCTAssertNotNil(
            session.translation(at: 0.6),
            "a freshly computed track must be usable without a reload"
        )
    }

    func testASuccessfulPassWritesTheSidecar() async throws {
        let expected = healthyTrack()
        let session = AlignmentSessionModel(compute: { _, _, _, _, _ in expected })

        await session.compute(left: left, right: right, leftStart: 18.56, rightStart: 4.40)

        XCTAssertEqual(AlignmentTrackStore.load(left: left, right: right), expected)
        XCTAssertNil(session.saveWarning)
    }

    /// The `SubjectSessionModel` rule, applied to a pass that costs the operator
    /// fifteen seconds: in-memory state is updated *before* persistence is
    /// attempted, so a read-only footage volume costs them the file and not the
    /// result.
    func testAnUnwritableFolderStillLeavesTheTrackUsableInMemory() async throws {
        let expected = healthyTrack()
        let session = AlignmentSessionModel(compute: { _, _, _, _, _ in expected })
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: directory.path
        )

        await session.compute(left: left, right: right, leftStart: 18.56, rightStart: 4.40)

        guard case .ready = session.state else {
            return XCTFail("a failed write must not fail the pass; got \(session.state)")
        }
        XCTAssertNotNil(session.translation(at: 0.6))
        XCTAssertNotNil(session.saveWarning, "the operator has to be told the file was not written")
    }

    func testCancellationReturnsToIdleNotFailed() async {
        let session = AlignmentSessionModel(compute: { _, _, _, _, _ in
            throw CancellationError()
        })

        await session.compute(left: left, right: right, leftStart: 18.56, rightStart: 4.40)

        guard case .idle = session.state else {
            return XCTFail("a cancelled pass must return to idle, not failed; got \(session.state)")
        }
    }

    func testCancelStopsARunInFlight() async {
        let session = AlignmentSessionModel(compute: { _, _, _, _, _ in
            while true {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        })

        let running = Task { await session.compute(left: left, right: right, leftStart: 0, rightStart: 0) }
        try? await Task.sleep(nanoseconds: 30_000_000)
        guard case .computing = session.state else {
            return XCTFail("precondition: the pass must actually be running; got \(session.state)")
        }

        session.cancel()
        await running.value

        guard case .idle = session.state else {
            return XCTFail("Cancel must return the session to idle; got \(session.state)")
        }
    }

    func testAKnownAnalysisFailureEndsFailedWithItsDescription() async {
        let underlying = AlignmentAnalyzer.AnalysisError.noFrames("C0094.MP4")
        let session = AlignmentSessionModel(compute: { _, _, _, _, _ in throw underlying })

        await session.compute(left: left, right: right, leftStart: 18.56, rightStart: 4.40)

        guard case let .failed(message) = session.state else {
            return XCTFail("expected failed, got \(session.state)")
        }
        XCTAssertEqual(message, underlying.description)
        XCTAssertEqual(
            message, "no frames could be read from C0094.MP4",
            "the operator sees this string verbatim, not a Swift enum dump"
        )
    }

    func testAnUnexpectedErrorNeverLeavesStateComputing() async {
        let session = AlignmentSessionModel(compute: { _, _, _, _, _ in throw FakeUnrelatedError() })

        await session.compute(left: left, right: right, leftStart: 18.56, rightStart: 4.40)

        if case .computing = session.state {
            XCTFail("state must never be left on .computing after the pass throws")
        }
        guard case .failed = session.state else {
            return XCTFail("expected failed, got \(session.state)")
        }
    }

    func testComputingTwiceCancelsTheFirstRun() async {
        let second = track(overlaps: [Double](repeating: 0.9, count: 12))
        let counter = CallCounter()
        let session = AlignmentSessionModel(compute: { _, _, _, _, _ in
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

        let firstRun = Task { await session.compute(left: left, right: right, leftStart: 0, rightStart: 0) }
        try? await Task.sleep(nanoseconds: 30_000_000)

        await session.compute(left: left, right: right, leftStart: 18.56, rightStart: 4.40)
        // Let the first run's cancellation finish unwinding before asserting,
        // so a bug that lets it clobber state afterward is caught here rather
        // than racing the assertion below.
        _ = await firstRun.value

        guard case let .ready(result) = session.state else {
            return XCTFail(
                "expected the second run's result, got \(session.state) "
                    + "(a superseded first run must not overwrite state once cancelled)"
            )
        }
        XCTAssertEqual(result, second)
    }
}
