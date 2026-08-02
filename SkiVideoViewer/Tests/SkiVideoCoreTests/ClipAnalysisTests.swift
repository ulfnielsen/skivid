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

    // MARK: - The operator's correction, kept beside the measurement

    /// Both fields survive a round trip, and they are **different values** on
    /// purpose.
    ///
    /// That is what lets this see a write path where the correction replaces
    /// `runStart`: with the two equal, or with only one of them asserted, such
    /// a change round-trips perfectly and the test passes while the measurement
    /// it claims to preserve is gone. The baseline and threshold are checked
    /// too — they are the detector's own evidence about that measurement, and
    /// they cannot be reconstructed from a corrected time.
    func testRoundTripsACorrectionWithoutLosingTheMeasurement() throws {
        let original = ClipAnalysis(
            version: 1,
            analysedAt: Date(timeIntervalSince1970: 1_754_121_660),
            parameters: parameters(),
            segments: [],
            subject: SubjectPick(
                segmentIDs: [3, 1],
                runStart: .started(time: 18.64, baseline: 1.89, threshold: 3.39),
                correctedRunStart: 16.84
            )
        )

        let decoded = try JSONDecoder().decode(
            ClipAnalysis.self, from: JSONEncoder().encode(original)
        )

        let subject = try XCTUnwrap(decoded.subject)
        XCTAssertEqual(subject.correctedRunStart ?? .nan, 16.84, accuracy: 1e-9,
                       "the operator's correction must survive the round trip")
        guard case let .started(time, baseline, threshold) = subject.runStart else {
            return XCTFail("expected the measured start to still be `started`, got \(subject.runStart)")
        }
        XCTAssertEqual(time, 18.64, accuracy: 1e-9,
                       "the correction overwrote the measurement; a re-analysis can no longer update it")
        XCTAssertEqual(baseline, 1.89, accuracy: 1e-9, "the detector's baseline is evidence and must survive")
        XCTAssertEqual(threshold, 3.39, accuracy: 1e-9, "the detector's threshold is evidence and must survive")
    }

    /// **A sidecar written before this field existed must still decode.** Six
    /// of them sit in the operator's footage folder, each holding twenty
    /// seconds of analysis and a judgement no algorithm can make, and
    /// `ClipAnalysisStore.load` reports an undecodable sidecar as *absent* — so
    /// a required field here would have thrown all six away in silence.
    ///
    /// The JSON is written out by hand, in the shape those files actually have
    /// (taken from `Idun Nielsen/C0094.skianalysis.json`, trimmed to one
    /// segment), and read back through the store so that the real date strategy
    /// and the real swallow-on-failure are both in the path. Encoding a current
    /// `ClipAnalysis` and decoding it again would pass whether or not the field
    /// is optional, and would prove nothing about the files on disk.
    func testASidecarWrittenBeforeTheCorrectionFieldStillDecodes() throws {
        let json = """
        {
          "analysedAt" : "2026-08-02T14:41:51Z",
          "parameters" : {
            "cutOnAmbiguity" : true,
            "detectionWidth" : 320,
            "fps" : 25,
            "initialJump" : 0.06,
            "maxHeightRatio" : 1.1499999999999999,
            "maxMisses" : 10,
            "minSamples" : 8,
            "speedMultiplier" : 4
          },
          "segments" : [
            {
              "detectionCount" : 408,
              "firstSeen" : 29.92,
              "id" : 1,
              "lastSeen" : 46.280000000000001,
              "peakHeightFraction" : 0.53330212831497192,
              "previews" : [
                {
                  "box" : [
                    [ 0.46439027786254883, 0.22586053609848022 ],
                    [ 0.060066878795623779, 0.27435100078582764 ]
                  ],
                  "time" : 29.920000000000002
                }
              ]
            }
          ],
          "subject" : {
            "runStart" : {
              "baseline" : 0.45751633986928103,
              "kind" : "started",
              "threshold" : 0.82352941176470584,
              "time" : 0.64000000000000001
            },
            "segmentIDs" : [ 15, 8, 6, 3, 4, 5, 1 ]
          },
          "version" : 1
        }
        """

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let clip = root.appendingPathComponent("C0094.MP4")
        try Data(json.utf8).write(to: ClipAnalysisStore.sidecarURL(for: clip))

        let loaded = try XCTUnwrap(
            ClipAnalysisStore.load(for: clip),
            "an existing sidecar stopped decoding; every stored pick in the footage folder would be lost"
        )

        let subject = try XCTUnwrap(loaded.subject, "the stored pick must survive")
        XCTAssertEqual(subject.segmentIDs, [15, 8, 6, 3, 4, 5, 1])
        XCTAssertNil(subject.correctedRunStart, "a file with no correction in it must read as uncorrected")
        XCTAssertEqual(subject.runStart.syncTime, 0.64, accuracy: 1e-9)
        XCTAssertEqual(loaded.segments.count, 1)
        XCTAssertEqual(loaded.segments.first?.previews.first?.box.width ?? 0, 0.060_066_878_795_623_779, accuracy: 1e-9)
    }

    /// The precedence rule, in the one place it is stated: the correction wins
    /// when there is one, the measurement answers when there is not.
    func testTheEffectiveStartIsTheCorrectionWhenThereIsOne() {
        let measured = StoredRunStart.started(time: 18.64, baseline: 1.89, threshold: 3.39)

        XCTAssertEqual(
            SubjectPick(segmentIDs: [1], runStart: measured).syncTime, 18.64, accuracy: 1e-9,
            "with no correction the measured start is what applies"
        )
        XCTAssertEqual(
            SubjectPick(segmentIDs: [1], runStart: measured, correctedRunStart: 16.84).syncTime,
            16.84, accuracy: 1e-9,
            "the operator's correction must win over the detector's measurement"
        )
        // `alreadyRunning` is what the detector reports when the subject was
        // never demonstrably still — the case most likely to need correcting.
        XCTAssertEqual(
            SubjectPick(
                segmentIDs: [1], runStart: .alreadyRunning(firstSeen: 2.44), correctedRunStart: 3.6
            ).syncTime,
            3.6, accuracy: 1e-9
        )
    }

    /// A correction of zero is a correction — the run began at the first frame
    /// — and must not read back as "no correction".
    func testACorrectionOfZeroIsStillACorrection() throws {
        let pick = SubjectPick(
            segmentIDs: [1], runStart: .started(time: 4.4, baseline: 1.1, threshold: 2.0),
            correctedRunStart: 0
        )
        let decoded = try JSONDecoder().decode(SubjectPick.self, from: JSONEncoder().encode(pick))

        XCTAssertEqual(decoded.correctedRunStart, 0)
        XCTAssertEqual(decoded.syncTime, 0, accuracy: 1e-9)
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
