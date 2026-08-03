import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import SkiVideoCore
@testable import SkiVideoViewer

/// When a moved anchor is written to a sidecar, and what it writes.
///
/// The rule lives in `ComparisonView.correction(for:anchoredAt:)` — static and
/// internal precisely so it can be driven from here. `ComparisonView` builds
/// its own `ComparisonModel` inside `init`, so a rendered one cannot be handed
/// a corrected pair, and this project has measured four separate ways an
/// offscreen render lies about what a control does. What *is* checkable without
/// a window is the decision itself, and it is the decision that decides whether
/// twenty seconds of the operator's work reaches the disk or a good sidecar is
/// rewritten with rounding noise.
///
/// The remaining links — the debounce and the `onChange` that starts it — are
/// verified in the running app; see the task report.
final class CorrectedStartWiringTests: XCTestCase {
    private let measured = StoredRunStart.started(time: 18.64, baseline: 1.89, threshold: 3.39)

    private func pick(corrected: TimeInterval? = nil) -> SubjectPick {
        SubjectPick(segmentIDs: [3, 1], runStart: measured, correctedRunStart: corrected)
    }

    /// Syncing from a stored start anchors the pair *on* that start. If that
    /// counted as a correction, opening a pair would rewrite both sidecars
    /// before the operator touched anything.
    func testAnchoringOnTheDetectedStartWritesNothing() {
        XCTAssertEqual(
            ComparisonView.correction(for: pick(), anchoredAt: 18.64), .unchanged
        )
    }

    /// And reopening a pair that already carries a correction must not rewrite
    /// it either.
    func testAnchoringOnAnExistingCorrectionWritesNothing() {
        XCTAssertEqual(
            ComparisonView.correction(for: pick(corrected: 16.84), anchoredAt: 16.84), .unchanged
        )
    }

    /// The reported case: the detector was 1.8s late on C0082 and the operator
    /// drags the start back.
    func testMovingTheAnchorRecordsTheCorrection() {
        XCTAssertEqual(
            ComparisonView.correction(for: pick(), anchoredAt: 16.84), .write(16.84)
        )
    }

    /// Dragging back onto the detected start clears the correction rather than
    /// storing the same number twice — the size of the correction is evidence
    /// about the detector, and a stored zero-sized one is a false positive.
    func testDraggingBackToTheDetectedStartClearsTheCorrection() {
        XCTAssertEqual(
            ComparisonView.correction(for: pick(corrected: 16.84), anchoredAt: 18.64), .write(nil)
        )
    }

    /// The threshold is what keeps re-applied starts from being written back as
    /// corrections: `applySync` round-trips its times through
    /// `CMTime(seconds:preferredTimescale: 600)`, which can move a start by up
    /// to 1/600s ≈ 1.7ms.
    func testTimescaleRoundingIsNotACorrection() {
        XCTAssertEqual(
            ComparisonView.correction(for: pick(), anchoredAt: 18.64 + 1.0 / 600), .unchanged
        )
    }

    /// And it must still be finer than the adjustment the operator is actually
    /// making. One frame at 50fps is 20ms, and this whole task exists because a
    /// run start needs frame-level correction.
    func testOneFrameIsACorrection() {
        XCTAssertEqual(
            ComparisonView.correction(for: pick(), anchoredAt: 18.62), .write(18.62)
        )
    }

    /// A correction to the first frame is a correction. `alreadyRunning` starts
    /// are the ones most likely to be dragged to zero, and a rule that treated
    /// 0 as "nothing to write" would silently drop exactly those.
    func testACorrectionToZeroIsWritten() {
        XCTAssertEqual(
            ComparisonView.correction(for: pick(corrected: 4.2), anchoredAt: 0), .write(0)
        )
    }
}

/// The correction as far as a test can drive it: a real `NSSlider` in the real
/// `ComparisonScrubber`, a real synced pair on real decodable media, and the
/// real sidecars on disk.
///
/// **This is not the same as the running-app check** and does not replace it —
/// an offscreen render answers "does this reach the model", not "is this
/// usable", and this project has measured four separate ways it lies about the
/// second. What it does answer is the question the brief's step 1 asks of the
/// code: with a side targeted, does dragging the bar leave the other clip
/// alone, all the way from the control the operator touches.
///
/// The technique is `SharedControlsWiringTests`'s, including its measured
/// gotchas: the slider's `doubleValue` is normalised 0…1, a seek on decodable
/// media is genuinely asynchronous so playheads are polled rather than read
/// immediately, and the fixture must be real media or the slider is disabled.
@MainActor
final class CorrectedStartEndToEndTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The reported problem, at the control that reports it: sync the pair,
    /// target Left, drag the bar. The right clip must not move.
    func testDraggingTheBarWithLeftTargetedDoesNotMoveTheRightClip() throws {
        let model = try syncedPair(leftStart: 8, rightStart: 5)
        model.target = .left

        let host = NSHostingView(rootView: ComparisonScrubber(model: model).frame(width: 600, height: 60))
        host.layoutSubtreeIfNeeded()
        let slider = try XCTUnwrap(nsSlider(in: host), "expected the scrubber's NSSlider")
        XCTAssertTrue(slider.isEnabled, "precondition: a real duration must enable the bar")

        let target = 6.4
        slider.doubleValue = target / model.leftDuration
        _ = slider.sendAction(slider.action, to: slider.target)
        settle(model)

        XCTAssertEqual(model.leftPlayer.currentTime().seconds, target, accuracy: 0.3,
                       "the targeted clip must follow the thumb")
        XCTAssertEqual(model.rightPlayer.currentTime().seconds, 5, accuracy: 0.1,
                       "the right clip moved; there is still no way to adjust one start against the other")
        XCTAssertEqual(model.leftSyncPoint.seconds, target, accuracy: 0.3,
                       "the correction must carry the sync point, or it is lost on the next return")
    }

    /// And with Both targeted the same drag still moves the pair — the
    /// behaviour that already existed, driven through the same control.
    func testDraggingTheBarWithBothTargetedStillMovesThePair() throws {
        let model = try syncedPair(leftStart: 8, rightStart: 5)
        model.target = .both

        let host = NSHostingView(rootView: ComparisonScrubber(model: model).frame(width: 600, height: 60))
        host.layoutSubtreeIfNeeded()
        let slider = try XCTUnwrap(nsSlider(in: host), "expected the scrubber's NSSlider")

        slider.doubleValue = 6.4 / model.leftDuration
        _ = slider.sendAction(slider.action, to: slider.target)
        settle(model)

        XCTAssertEqual(model.leftPlayer.currentTime().seconds, 6.4, accuracy: 0.3)
        XCTAssertEqual(model.rightPlayer.currentTime().seconds, 3.4, accuracy: 0.3,
                       "the pair must stay locked at its −3s offset")
    }

    /// The whole chain the operator actually walks: two clips with stored
    /// picks, sync from those starts, correct one by dragging, write it, and
    /// reopen. The corrected start must be the one that applies, without
    /// re-analysis — and the measured one must still be in the file.
    func testACorrectionSurvivesReopeningThePair() throws {
        let left = try makeRealVideoFile(name: "C0094.mov", seconds: 25)
        let right = try makeRealVideoFile(name: "C0092.mov", seconds: 25)
        // The two real run starts from the operator's own sidecars.
        try store(runStart: .started(time: 19.0, baseline: 0.457, threshold: 0.823), for: left)
        try store(runStart: .started(time: 4.4, baseline: 1.119, threshold: 2.015), for: right)

        let sessions = (left: SubjectSessionModel(), right: SubjectSessionModel())
        sessions.left.loadStored(for: left)
        sessions.right.loadStored(for: right)
        let model = try loadedPair(left: left, right: right)
        let starts = (
            left: try XCTUnwrap(sessions.left.pickedSubject).syncTime,
            right: try XCTUnwrap(sessions.right.pickedSubject).syncTime
        )
        model.applySync(left: starts.left, right: starts.right)
        settle(model)
        XCTAssertTrue(model.status.contains("detected starts"),
                      "precondition: the pair starts out synced from the detector, got \(model.status)")

        // The correction: the detector was late, so drag the left start back.
        model.target = .left
        model.scrub(.left, to: 17.2)
        settle(model)

        // What `ComparisonView` does on settle, with its own rule.
        let points = try XCTUnwrap(model.syncPoints)
        for (side, session, clip) in [
            (points.left, sessions.left, left), (points.right, sessions.right, right),
        ] as [(TimeInterval, SubjectSessionModel, URL)] {
            let pick = try XCTUnwrap(session.pickedSubject)
            guard case let .write(corrected) = ComparisonView.correction(for: pick, anchoredAt: side) else { continue }
            try session.confirm(
                segmentIDs: pick.segmentIDs, runStart: pick.runStart,
                correctedRunStart: corrected, for: clip
            )
        }

        // Reopened: fresh sessions, fresh model, nothing but the files.
        let reopened = SubjectSessionModel()
        let stored = try XCTUnwrap(reopened.loadStored(for: left)?.subject, "the sidecar must still hold a pick")
        XCTAssertEqual(stored.correctedRunStart ?? .nan, 17.2, accuracy: 0.3,
                       "the correction did not survive; it would have to be made again on every open")
        XCTAssertEqual(stored.runStart.syncTime, 19.0, accuracy: 1e-9,
                       "the measurement must still be there beside it — it is the evidence about the detector")
        XCTAssertEqual(stored.syncTime, stored.correctedRunStart ?? .nan, accuracy: 1e-9,
                       "the correction is what applies")

        let rightStored = try XCTUnwrap(reopened.loadStored(for: right)?.subject)
        XCTAssertNil(rightStored.correctedRunStart,
                     "the untouched side's sidecar must not be rewritten with a correction it never got")

        let second = try loadedPair(left: left, right: right)
        second.applySync(left: stored.syncTime, right: rightStored.syncTime, corrected: true)
        settle(second)
        XCTAssertEqual(second.leftSyncPoint.seconds, 17.2, accuracy: 0.3,
                       "the reopened pair must anchor on the corrected start")
        XCTAssertTrue(second.status.contains("corrected"),
                      "the chip must not credit the detector for a start the operator moved, got \(second.status)")
    }

    // MARK: - Fixtures

    private func store(runStart: StoredRunStart, for clip: URL) throws {
        try ClipAnalysisStore.save(
            ClipAnalysis(
                version: 1, analysedAt: Date(timeIntervalSince1970: 1_754_121_660),
                parameters: .current,
                segments: [
                    AnalysedSegment(id: 1, firstSeen: 1, lastSeen: 20, detectionCount: 300,
                                    peakHeightFraction: 0.5, previews: []),
                ],
                subject: SubjectPick(segmentIDs: [1], runStart: runStart)
            ),
            for: clip
        )
    }

    private func loadedPair(left: URL, right: URL) throws -> ComparisonModel {
        let model = ComparisonModel()
        addTeardownBlock { @MainActor in model.close() }
        model.load(left, side: .left)
        model.load(right, side: .right)
        let deadline = Date().addingTimeInterval(20)
        while (model.leftDuration <= 0 || model.rightDuration <= 0), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertGreaterThan(model.leftDuration, 0, "precondition: the fixture's duration must be known")
        XCTAssertGreaterThan(model.rightDuration, 0)
        return model
    }

    private func syncedPair(leftStart: Double, rightStart: Double) throws -> ComparisonModel {
        let model = try loadedPair(
            left: try makeRealVideoFile(name: "left.mov", seconds: 20),
            right: try makeRealVideoFile(name: "right.mov", seconds: 20)
        )
        model.applySync(left: leftStart, right: rightStart)
        settle(model)
        XCTAssertTrue(model.isSynced, "precondition: the pair must be locked")
        XCTAssertEqual(model.rightPlayer.currentTime().seconds, rightStart, accuracy: 0.1,
                       "precondition: the right clip must start where the sync put it")
        XCTAssertEqual(model.leftSyncPoint.seconds, leftStart, accuracy: 0.1,
                       "precondition: the anchor must be where the sync asked for")
        XCTAssertEqual(model.rightSyncPoint.seconds, rightStart, accuracy: 0.1,
                       "precondition: the anchor must be where the sync asked for")
        return model
    }

    /// Seeks on decodable media complete asynchronously, so every measurement
    /// waits for both playheads to stop moving. Stability, not an expected
    /// value: waiting for the value under test would pass by construction.
    ///
    /// Three consecutive equal reads *and* a minimum elapsed time, rather than
    /// the first repeat. A seek that has not begun yet also reads as two equal
    /// samples — measured, as a spurious pass and later a spurious failure of
    /// the paired-drag case — and returning there would time the assertions
    /// against the position the clips were in *before* the drag.
    private func settle(_ model: ComparisonModel, timeout: TimeInterval = 5) {
        let start = Date()
        var previous = (Double.nan, Double.nan)
        var stable = 0
        while Date().timeIntervalSince(start) < timeout {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let now = (model.leftPlayer.currentTime().seconds, model.rightPlayer.currentTime().seconds)
            stable = now == previous ? stable + 1 : 0
            previous = now
            if stable >= 3, Date().timeIntervalSince(start) > 0.5 { return }
        }
    }

    /// Typed as `NSSlider` rather than matched by class name, as
    /// `SharedControlsWiringTests` documents: dragging needs `doubleValue` and
    /// `sendAction(_:to:)`.
    private func nsSlider(in view: NSView) -> NSSlider? {
        if let slider = view as? NSSlider { return slider }
        for sub in view.subviews {
            if let found = nsSlider(in: sub) { return found }
        }
        return nil
    }

    /// A real H.264 clip of known length. Duplicated from
    /// `SkiVideoCoreTests/RealVideoFixture.swift` for the same cross-target
    /// reason `SharedControlsWiringTests` duplicates it: a zero-byte fixture
    /// reports a NaN duration, which leaves the slider disabled and every
    /// bound inside the model infinite.
    private func makeRealVideoFile(name: String, seconds: Double, fps: Int32 = 10) throws -> URL {
        let url = root.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 90,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: 160,
                kCVPixelBufferHeightKey as String: 90,
            ]
        )
        XCTAssertTrue(writer.startWriting(), "could not start writing the fixture: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)

        let frames = Int(seconds * Double(fps))
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
            let pool = try XCTUnwrap(adaptor.pixelBufferPool, "the writer gave no pixel buffer pool")
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer), kCVReturnSuccess)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            if let base = CVPixelBufferGetBaseAddress(pixels) {
                memset(base, Int32(frame % 251), CVPixelBufferGetBytesPerRow(pixels) * CVPixelBufferGetHeight(pixels))
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: fps))

        let written = expectation(description: "fixture written")
        writer.finishWriting { written.fulfill() }
        wait(for: [written], timeout: 60)
        XCTAssertEqual(writer.status, .completed, "fixture encode failed: \(String(describing: writer.error))")
        return url
    }
}
