import AppKit
import AVFoundation
import XCTest
@testable import SkiVideoCore
@testable import SkiVideoViewer

/// Drives a real `AppKitInputSource` into a real `ViewerModel`. This file owns
/// **only** the assertions that need both halves at once; everything provable
/// about the model alone lives in `SkiVideoCoreTests/ViewerModelIntentTests`
/// and everything provable about the key mapping alone lives in
/// `AppKitInputSourceTests`. Task 6 moved `ViewerModel` into `SkiVideoCore`,
/// so the tap/double-tap/clip-index coverage that used to be duplicated here
/// was removed in favour of the platform-agnostic copies.
///
/// What survives is what needs both halves at once: the enable flag, the
/// ⌘+Arrow hold, and the bare arrow's auto-repeat suppression. The last two are
/// the seam's real content — the source decides which `NSEvent`s become intents
/// and the model decides what an intent does, and a defect that lives in the
/// *pairing* is invisible to either file's own tests. One did: dropping the
/// arrow-repeat guard made a held bare arrow alternate +1s/+5s at the key-repeat
/// rate, about 31s of media per 1.3s held, because `performArrowTap`'s 0.38s
/// double-tap detector cannot tell an auto-repeat from a second press.
///
/// `makeStack()` passes a real `AppKitFolderPicker` only to satisfy the
/// initializer; nothing here calls `chooseDirectory()`, so `runModal()` is
/// never invoked.
@MainActor
final class AppKitInputToModelTests: XCTestCase {
    private var temporaryDirectory: URL?

    override func tearDown() async throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    /// `VideoLibrary.scan` only inspects file extensions, so empty files are
    /// enough to give the model a `currentVideo`. No playable media is needed:
    /// `seek` records the requested offset before it touches the player.
    private func makeLibrary() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let athlete = root.appendingPathComponent("Idun", isDirectory: true)
        try FileManager.default.createDirectory(at: athlete, withIntermediateDirectories: true)
        for name in ["a.mp4", "b.mp4"] {
            FileManager.default.createFile(
                atPath: athlete.appendingPathComponent(name).path,
                contents: Data()
            )
        }
        temporaryDirectory = root
        return root
    }

    private func makeStack() throws -> (ViewerModel, AppKitInputSource) {
        let source = AppKitInputSource()
        let model = ViewerModel(
            input: source,
            folderPicker: AppKitFolderPicker(),
            oauthPresenter: StubOAuthPresenter(),
            // Frozen: no test here spans the 0.38s double-tap window, and a
            // fixed date keeps that true however slowly the host runs.
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        model.openDirectory(try makeLibrary())
        return (model, source)
    }

    /// Mirrors `AppKitInputSourceTests`' builder. `windowNumber: 0` leaves
    /// `NSEvent.window` nil, so the source's field-editor check can never fire —
    /// that check has its own coverage there and is not what this file is about.
    private func key(
        _ code: UInt16,
        type: NSEvent.EventType = .keyDown,
        modifiers: NSEvent.ModifierFlags = [],
        isARepeat: Bool = false
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: isARepeat,
            keyCode: code
        )!
    }

    private func tapRightArrow(_ source: AppKitInputSource) {
        _ = source.handle(key(124))
        _ = source.handle(key(124, type: .keyUp))
    }

    /// `ViewerModelIntentTests` proves the model forwards the flag to whatever
    /// source it holds; this proves the *real* source honours it end to end.
    func testDisablingKeyboardControlsStopsTheSource() throws {
        let (model, source) = try makeStack()

        model.setKeyboardControlsEnabled(false)
        tapRightArrow(source)

        XCTAssertNil(model.lastSeekOffset, "a disabled source must not reach the model")
    }

    // MARK: - ⌘+Arrow, end to end

    /// The chord's two halves against the real source and the real model: the
    /// key-down has to survive `isSlowMotionArrow`'s modifier test, the
    /// `heldDirection` bookkeeping and the model's `currentVideo` precondition
    /// to become slow playback, and the key-up — which deliberately carries **no**
    /// modifier, because the operator may lift Command first — has to be matched
    /// on the keyCode alone to end it.
    ///
    /// `lastSeekOffset` is asserted because the failure mode this pairing risks
    /// is not "nothing happens": a chord that fell through to the bare-arrow case
    /// would jump the clip a second instead of holding it, and the rate assertion
    /// alone reads the same either way once the hold is over.
    func testCommandArrowRunsAndThenStopsSlowPlayback() throws {
        let (model, source) = try makeRealStack(seconds: 4)

        XCTAssertTrue(source.handle(key(124, modifiers: .command)), "the chord must be consumed")
        XCTAssertEqual(model.player.rate, 0.35, accuracy: 0.001, "⌘→ must run the clip slowly")
        XCTAssertEqual(model.status, "Slow forward")

        XCTAssertTrue(source.handle(key(124, type: .keyUp)), "the release must be consumed")

        XCTAssertEqual(model.player.rate, 0, "the release must stop the clip")
        XCTAssertEqual(model.status, "Paused")
        XCTAssertNil(model.lastSeekOffset, "a hold must not seek — it is not a tap")
    }

    /// The runaway's end-to-end guard, and the reason this file exists.
    ///
    /// Neither half can catch it alone. `AppKitInputSourceTests` proves the
    /// repeat emits no intent, and `ViewerModelIntentTests` proves what one
    /// `.seek` does; what made 31s of media move per 1.3s held was the two put
    /// together — `arrowsRepeat` off is the *only* thing standing between
    /// macOS's ~90ms repeats and a double-tap detector that reads every one of
    /// them as a deliberate second press.
    ///
    /// The pumps between events are not padding. A real repeat arrives 90ms
    /// later, by which time the previous seek has landed and the next one is
    /// computed from the moved playhead; fire them back to back and every seek
    /// reads the same `currentTime()` and lands on the same target, which would
    /// hide the runaway rather than test it.
    ///
    /// Real media, so `AVPlayerItem.duration` is a number: `seek(seconds:)`
    /// clamps to it, and against a zero-byte fixture's NaN duration that clamp
    /// never runs and the playhead assertion means nothing.
    func testAHeldBareArrowMovesThePlayheadOnceNotOncePerRepeat() throws {
        let (model, source) = try makeRealStack(seconds: 20)
        let duration = try XCTUnwrap(model.player.currentItem?.duration.seconds)
        XCTAssertTrue(duration.isFinite, "premise: the clamp needs a real duration")
        XCTAssertGreaterThan(duration, 13, "premise: the clip must be long enough to run away in")

        _ = source.handle(key(124))
        pump()
        for _ in 0..<4 {
            _ = source.handle(key(124, isARepeat: true))
            pump()
        }
        _ = source.handle(key(124, type: .keyUp))
        pump()

        XCTAssertEqual(model.player.currentTime().seconds, 1, accuracy: 0.1,
                       "one physical press must move the clip one second, however long it is held")
    }

    /// Long enough for a seek to land, and roughly the interval macOS delivers
    /// key repeats at.
    private func pump(_ seconds: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// `makeStack`'s empty files are enough for anything that only needs a
    /// `currentVideo`; this is for the assertions that need the clip to really
    /// play and really seek.
    private func makeRealStack(seconds: Double) throws -> (ViewerModel, AppKitInputSource) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        temporaryDirectory = root
        let athlete = root.appendingPathComponent("Idun", isDirectory: true)
        _ = try makeRealVideoFile(in: athlete, name: "run1.mov", seconds: seconds)

        let source = AppKitInputSource()
        let model = ViewerModel(
            input: source,
            folderPicker: AppKitFolderPicker(),
            oauthPresenter: StubOAuthPresenter(),
            // Frozen, exactly as `makeStack` freezes it — and here it is the
            // point rather than a convenience: a fixed clock puts every
            // auto-repeat inside the 0.38s double-tap window, which is where a
            // real 90ms repeat lands too.
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        model.openDirectory(root)
        XCTAssertNotNil(model.currentPlaybackURL, "precondition: a clip must be loaded")

        let deadline = Date().addingTimeInterval(20)
        while model.player.currentItem?.status != .readyToPlay, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(model.player.currentItem?.status, .readyToPlay,
                       "precondition: the item must be ready, or nothing below is measuring playback")
        return (model, source)
    }

    /// A real H.264 clip of a known length, generated rather than checked in.
    /// Duplicated from `SkiVideoCoreTests/RealVideoFixture.swift` for the same
    /// cross-target reason `ViewerControlsWiringTests` duplicates it: that
    /// helper is an `XCTestCase` extension scoped to `SkiVideoCoreTests`, which
    /// this target does not depend on.
    private func makeRealVideoFile(
        in directory: URL,
        name: String,
        seconds: Double,
        fps: Int32 = 10
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)

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
