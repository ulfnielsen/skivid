import CoreGraphics
import XCTest
@testable import SkiVideoCore

final class AlignmentAnalyzerTests: XCTestCase {
    // Ground truth from the run-start detector, recorded in
    // docs/superpowers/specs/2026-08-02-phase-c-alignment-findings.md.
    private static let footage =
        "/Users/ulfnielsen/Ski/Neuss2026/organized/2026-07-19_Neuss"
    private static let left = URL(fileURLWithPath: "\(footage)/Idun Nielsen/C0094.MP4")
    private static let right = URL(fileURLWithPath: "\(footage)/Fabien Wiest/C0092.MP4")
    private static let leftStart: TimeInterval = 18.56
    private static let rightStart: TimeInterval = 4.40

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func requireFootage() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.left.path)
                && FileManager.default.fileExists(atPath: Self.right.path),
            "ground-truth footage not present on this machine"
        )
    }

    /// A pair of tiny generated clips. Featureless grey gives registration
    /// nothing to lock onto, which is the point: the pass must still produce
    /// one sample per pair.
    private func syntheticPair(seconds: Double = 4) throws -> (left: URL, right: URL) {
        (
            try makeRealVideoFile(in: directory, name: "left.mov", seconds: seconds),
            try makeRealVideoFile(in: directory, name: "right.mov", seconds: seconds)
        )
    }

    private static let syntheticParameters = AlignmentParameters(
        sampleRate: 5, workingWidth: 160, durationSeconds: 2
    )

    // MARK: - The invariants, on generated clips

    /// The timeline must not shorten. A pair whose registration fails still
    /// owes a sample, or every later sample is attributed to the wrong moment.
    func testEveryPairContributesASampleEvenWhenRegistrationCannotSucceed() async throws {
        let pair = try syntheticPair()
        let track = try await AlignmentAnalyzer.analyse(
            left: pair.left, right: pair.right,
            leftStart: 1.0, rightStart: 0.5,
            parameters: Self.syntheticParameters
        )

        // One sample per readable pair — stated against the reader itself
        // rather than a hard-coded count, because the invariant is "none went
        // missing", not "there were exactly n".
        let expected = try ClipFrameReader.frames(
            from: pair.left,
            fps: Self.syntheticParameters.sampleRate,
            targetWidth: Self.syntheticParameters.workingWidth,
            from: 1.0,
            to: 1.0 + Self.syntheticParameters.durationSeconds
        ).count
        XCTAssertGreaterThan(expected, 5)
        XCTAssertEqual(track.samples.count, expected)
        XCTAssertEqual(track.samples.map(\.time), track.samples.map(\.time).sorted())
        XCTAssertEqual(track.samples.first?.time ?? -1, 0, accuracy: 0.05)
        // Whatever registration made of featureless grey, nothing is missing
        // and nothing is NaN.
        XCTAssertTrue(track.samples.allSatisfy { $0.overlap >= 0 && $0.overlap <= 1 })
        XCTAssertTrue(track.samples.allSatisfy {
            $0.translation.dx.isFinite && $0.translation.dy.isFinite
        })
    }

    func testTheTrackRecordsWhatItWasComputedFrom() async throws {
        let pair = try syntheticPair()
        let track = try await AlignmentAnalyzer.analyse(
            left: pair.left, right: pair.right,
            leftStart: 1.0, rightStart: 0.5,
            parameters: Self.syntheticParameters
        )

        XCTAssertEqual(track.leftClip, "left.mov")
        XCTAssertEqual(track.rightClip, "right.mov")
        XCTAssertEqual(track.leftStart, 1.0, accuracy: 1e-9)
        XCTAssertEqual(track.rightStart, 0.5, accuracy: 1e-9)
        XCTAssertEqual(track.parameters, Self.syntheticParameters)
        XCTAssertFalse(track.isStale(leftStart: 1.0, rightStart: 0.5))
    }

    func testProgressRunsFromAboveZeroToOne() async throws {
        let pair = try syntheticPair()
        actor Recorder {
            var values: [Double] = []
            func record(_ value: Double) { values.append(value) }
        }
        let recorder = Recorder()
        _ = try await AlignmentAnalyzer.analyse(
            left: pair.left, right: pair.right,
            leftStart: 1.0, rightStart: 0.5,
            parameters: Self.syntheticParameters
        ) { value in Task { await recorder.record(value) } }
        let values = await recorder.values

        XCTAssertGreaterThanOrEqual(values.count, 11)
        XCTAssertEqual(values.last ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertTrue(values.allSatisfy { $0 > 0 && $0 <= 1.0 })
    }

    func testCancellationStopsThePass() async throws {
        let pair = try syntheticPair()
        let task = Task {
            try await AlignmentAnalyzer.analyse(
                left: pair.left, right: pair.right,
                leftStart: 1.0, rightStart: 0.5,
                parameters: Self.syntheticParameters
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
    }

    func testAnEmptyReadIsAnError() async throws {
        let pair = try syntheticPair()
        do {
            _ = try await AlignmentAnalyzer.analyse(
                left: pair.left, right: pair.right,
                // Past the end of a 4 s clip: nothing to read.
                leftStart: 20, rightStart: 20,
                parameters: Self.syntheticParameters
            )
            XCTFail("expected an error")
        } catch let error as AlignmentAnalyzer.AnalysisError {
            XCTAssertTrue("\(error)".contains("left.mov"))
        }
    }

    // MARK: - The measurement, on the ground-truth pair

    /// The one that matters. These numbers come from the sweep in
    /// `docs/superpowers/specs/2026-08-02-phase-c-alignment-findings.md`, which
    /// this whole phase's design was derived from. They are a check that the
    /// pass reproduces the lab, so a failure here is a finding — either the
    /// pass differs from the sweep or the sweep was noisier than it looked.
    /// **Do not move a threshold to make this pass.**
    func testTheMeasuredWindowsReproduceTheSweep() async throws {
        try requireFootage()

        let began = Date()
        let track = try await AlignmentAnalyzer.analyse(
            left: Self.left, right: Self.right,
            leftStart: Self.leftStart, rightStart: Self.rightStart
        )
        print("alignment pass: \(track.samples.count) pairs in "
              + String(format: "%.1f", Date().timeIntervalSince(began)) + "s")

        XCTAssertGreaterThan(track.samples.count, 400)
        XCTAssertEqual(track.samples.last?.time ?? 0, 17.0, accuracy: 0.5)

        // Sample times land on the sample grid, so a nearest-sample lookup is
        // exact enough to name an instant.
        func sample(at time: TimeInterval) throws -> AlignmentSample {
            try XCTUnwrap(track.samples.min { abs($0.time - time) < abs($1.time - time) })
        }
        func engaged(at time: TimeInterval) -> Bool {
            AlignmentGate.translation(in: track, at: time) != nil
        }

        // t = 2.0 sits in the first good window (measured overlap 0.82,
        // beating identity by 7).
        XCTAssertTrue(engaged(at: 2.0), "t = 2.0 was measured as a good window")
        let good = try sample(at: 2.0)
        XCTAssertLessThan(
            good.residual, good.identityResidual,
            "registration must earn its place where the sweep says it does"
        )

        // t = 6.0 sits in the bad stretch, where the cameras are looking at
        // different parts of the hill.
        XCTAssertFalse(engaged(at: 6.0), "t = 6.0 was measured as a bad window")

        let engagedSamples = track.samples.filter { engaged(at: $0.time) }
        let fraction = Double(engagedSamples.count) / Double(track.samples.count)
        XCTAssertGreaterThan(fraction, 0.5, "engaged fraction was \(fraction)")
        XCTAssertLessThan(fraction, 0.8, "engaged fraction was \(fraction)")

        // Translations are stored normalised, so they stay small however wide
        // the frames were when they were measured.
        XCTAssertTrue(track.samples.allSatisfy { abs($0.translation.dx) < 1 })
        XCTAssertTrue(track.samples.allSatisfy { abs($0.translation.dy) < 1 })

        // And the whole thing survives the sidecar. Written to a temporary
        // directory rather than beside the footage so the suite leaves the
        // operator's folders alone.
        let left = directory.appendingPathComponent("C0094.MP4")
        let right = directory.appendingPathComponent("C0092.MP4")
        try AlignmentTrackStore.save(track, left: left, right: right)
        let reloaded = try XCTUnwrap(AlignmentTrackStore.load(left: left, right: right))

        XCTAssertEqual(reloaded.samples.count, track.samples.count)
        XCTAssertEqual(reloaded.parameters, track.parameters)
        XCTAssertFalse(reloaded.isStale(leftStart: Self.leftStart, rightStart: Self.rightStart))
        XCTAssertEqual(
            AlignmentGate.translation(in: reloaded, at: 2.0)?.dx,
            AlignmentGate.translation(in: track, at: 2.0)?.dx
        )
    }
}
