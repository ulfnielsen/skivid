import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import SkiVideoCore
@testable import SkiVideoViewer

/// Proves the subject picking sheet's controls actually reach their model,
/// rather than merely compiling against it.
///
/// `SubjectPickModelTests` drives `toggle` and `selectedInTimeOrder` directly
/// and never renders anything, so nothing there notices a card wired to the
/// wrong id, a confirm button that hands back the tap order instead of the
/// time order, or a Cancel that does nothing. This clicks the real controls.
///
/// **The technique is not `performClick`, and that was measured, not assumed.**
/// `SharedControlsWiringTests` finds `NSButton`s in the hosted tree because
/// `TransportControls` styles its buttons `.borderless`, which AppKit backs
/// with a real `NSButton`. Neither control here does: dumping the hosted tree
/// for `SubjectPickList` shows a `.plain` card and a `.borderedProminent`
/// confirm button both rendering as `_FocusRingView` — SwiftUI-drawn, with no
/// `NSButton`, no `NSControl`, and so no `performClick`/`isEnabled` to read.
/// What does reach them is the synthetic-mouse-event technique
/// `ViewerControlsWiringTests` uses for `ViewerPane`'s tap gesture: real
/// `NSEvent`s through a real (off-screen, `.prohibited`-policy) `NSWindow`.
/// `view.mouseDown(with:)` on the hosted view does not work — SwiftUI's hit
/// testing lives in the window's event-dispatch path.
///
/// A consequence of having no `NSControl`: "disabled" cannot be asserted as a
/// property here the way `ViewerControlsWiringTests` asserts
/// `NSButton.isEnabled`. It is asserted as behaviour instead — a click at the
/// button's own frame produces nothing — which is the stronger of the two
/// anyway, and is what actually kills the mutation of deleting `.disabled`.
///
/// One measured gotcha, or the tests below silently pass for the wrong reason:
/// **after any state change, spin the run loop and re-lay out before locating
/// or clicking the next control.** Confirmed by getting it wrong first —
/// clicking a card and then immediately clicking the confirm button at its
/// pre-click frame did nothing at all, because SwiftUI had not yet rebuilt the
/// footer that the click was meant to land in.
@MainActor
final class SubjectPickWiringTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Matches `SharedControlsWiringTests`: `NSHostingView` needs the shared
        // application to exist before it lays anything out, and `.prohibited`
        // keeps it out of the Dock and off the screen.
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    // MARK: - The card's own tap gate

    /// Kills the mutation of deleting `.disabled(!isSelectable)` from
    /// `SegmentCard`, which is the card-level form of "call `toggle`
    /// unconditionally, ignoring `isSelectable`".
    ///
    /// **This has to be tested here, on the card, and that is the whole reason
    /// `SegmentCard` takes a closure instead of the model.** Measured:
    /// `SubjectPickModel.toggle` already refuses a segment that
    /// `isSelectable` rejects, so a sheet-level version of this test — click
    /// the excluded card, assert the selection did not change — passes whether
    /// or not the card gates the tap at all. It cannot see the mutation. With
    /// the gate held on the card and the closure spied on, the mutant fires
    /// `onTap` and this fails.
    func testAnExcludedCardDoesNotInvokeItsTap() throws {
        var taps = 0
        let card = SegmentCard(
            segment: segment(id: 2, from: 5, to: 9, samples: 40),
            isSelected: false,
            exclusionReason: "Overlaps segment 1 in time, so they cannot be the same person",
            strip: nil
        ) { taps += 1 }

        let scene = show(card, width: 300, height: 200)
        click(try XCTUnwrap(controls(in: scene.host).first), in: scene.window)

        XCTAssertEqual(taps, 0, "a card showing an exclusion reason must not invoke its tap")
    }

    /// The other half of the test above, and not implied by it: a card that
    /// never fires `onTap` at all would pass that one. Same card, nothing
    /// excluding it.
    func testASelectableCardInvokesItsTap() throws {
        var taps = 0
        let card = SegmentCard(
            segment: segment(id: 2, from: 5, to: 9, samples: 40),
            isSelected: false,
            exclusionReason: nil,
            strip: nil
        ) { taps += 1 }

        let scene = show(card, width: 300, height: 200)
        click(try XCTUnwrap(controls(in: scene.host).first), in: scene.window)

        XCTAssertEqual(taps, 1, "a selectable card must invoke its tap exactly once per click")
    }

    // MARK: - The list wired to the pick model

    /// Kills the mutation of stubbing `SubjectPickList`'s
    /// `{ pick.toggle(segment.id) }` — the second of the two links, which the
    /// card's own tests above cannot see. Two cards, not one: with a single
    /// card, `toggle` called with a hardcoded id would look identical to
    /// `toggle` called with the card's own.
    func testTappingACardTogglesThatSegmentInTheModel() throws {
        let pick = SubjectPickModel(segments: pairInReverseTimeOrder())
        let scene = show(list(pick), width: 520, height: 620)

        var cards = controls(in: scene.host)
        XCTAssertEqual(cards.count, 3, "precondition: two cards plus the confirm button")
        click(cards[1], in: scene.window)
        XCTAssertEqual(pick.selected, [2], "tapping the second card must toggle the second segment on")

        settle(scene)
        cards = controls(in: scene.host)
        click(cards[1], in: scene.window)
        XCTAssertEqual(pick.selected, [], "tapping it again must toggle it back off")
    }

    /// The list-level companion to `testAnExcludedCardDoesNotInvokeItsTap`.
    ///
    /// **It cannot kill that mutation and is not claimed to** — see that test
    /// for the measurement. What it does prove is that the list hands each
    /// card the exclusion reason for *its own* segment: mutating
    /// `exclusionReason: pick.exclusionReason(for: segment)` to a constant
    /// `nil` leaves the excluded card live, and its tap then reaches a
    /// `toggle` that refuses — the selection is unchanged either way, so this
    /// test asserts the reason is on the card instead, through the
    /// accessibility label the operator's screen reader reads.
    func testAnOverlappingSegmentIsShownAsExcludedOnceItsClashIsPicked() throws {
        let pick = SubjectPickModel(segments: [
            segment(id: 1, from: 1, to: 8, samples: 100),
            segment(id: 2, from: 5, to: 9, samples: 40),
        ])
        XCTAssertNil(pick.exclusionReason(for: pick.segments[1]), "precondition: nothing excludes it yet")

        let scene = show(list(pick), width: 520, height: 620)
        click(controls(in: scene.host)[0], in: scene.window)
        XCTAssertEqual(pick.selected, [1], "precondition: the first segment is picked")

        settle(scene)
        let reason = try XCTUnwrap(
            pick.exclusionReason(for: pick.segments[1]),
            "precondition: an overlapping segment must now be excluded"
        )
        XCTAssertTrue(
            reason.contains("Overlaps segment 1"),
            "the operator is owed the reason, not just a dead control: \(reason)"
        )

        click(controls(in: scene.host)[1], in: scene.window)
        XCTAssertEqual(pick.selected, [1], "an excluded segment must not join the selection")
    }

    // MARK: - Use as subject

    /// Kills the mutation of deleting `.disabled(pick.selected.isEmpty)` from
    /// `SubjectPickList.confirmButton`. With nothing selected, a click at the
    /// button's own frame must produce nothing; the mutant calls `onConfirm`
    /// with an empty id list, which the caller would then compute a run start
    /// from — a sync point derived from no samples at all.
    ///
    /// Asserted as behaviour rather than as `isEnabled` because SwiftUI draws
    /// this button itself; there is no `NSControl` in the tree to ask. See the
    /// type comment.
    func testUseAsSubjectDoesNothingWithAnEmptySelection() {
        let pick = SubjectPickModel(segments: pairInReverseTimeOrder())
        var confirmed: [[Int]] = []
        let scene = show(list(pick) { confirmed.append($0) }, width: 520, height: 620)

        let all = controls(in: scene.host)
        XCTAssertEqual(all.count, 3, "precondition: two cards plus the confirm button")
        XCTAssertTrue(pick.selected.isEmpty, "precondition: nothing is selected")
        click(all[2], in: scene.window)

        XCTAssertTrue(
            confirmed.isEmpty,
            "Use as subject must be inert with an empty selection, not confirm an empty pick"
        )
    }

    /// The other half: the same button, after one tap on a card, must confirm
    /// — otherwise a button disabled unconditionally would pass the test
    /// above.
    ///
    /// It must also hand back **time order, not tap order**, which is why the
    /// two segments are declared with the later one first and tapped in that
    /// declaration order: `selected` is `[1, 2]` at this point and
    /// `selectedInTimeOrder` is `[2, 1]`, so passing `pick.selected` by
    /// mistake is a mutation this can see.
    func testUseAsSubjectConfirmsTheSelectedIDsInTimeOrder() throws {
        let pick = SubjectPickModel(segments: pairInReverseTimeOrder())
        var confirmed: [[Int]] = []
        let scene = show(list(pick) { confirmed.append($0) }, width: 520, height: 620)

        click(controls(in: scene.host)[0], in: scene.window)
        settle(scene)
        click(controls(in: scene.host)[1], in: scene.window)
        XCTAssertEqual(pick.selected, [1, 2], "precondition: picked in declaration order, which is reverse time order")

        settle(scene)
        click(controls(in: scene.host)[2], in: scene.window)

        XCTAssertEqual(
            confirmed, [[2, 1]],
            "Use as subject must confirm the picked ids once, in time order rather than tap order"
        )
    }

    // MARK: - Cancel

    /// Kills the mutation of stubbing `SubjectPickSheet`'s
    /// `{ session.cancel() }`.
    ///
    /// `cancel()` has no observable effect with nothing in flight — it cancels
    /// a task and clears a reference — so this runs a real analysis to have
    /// something to cancel, which is also the only way to reach the
    /// `.analysing` state at all: `SubjectSessionModel.state` is
    /// `private(set)`, so no test can put it there directly.
    ///
    /// The fixture has to be a real, decodable clip. An empty file was tried
    /// first and cannot work: `SubjectAnalyzer` throws `noFrames` before it
    /// reaches the `Task.checkCancellation()` in its frame loop, so the
    /// session lands on `.failed` whether or not Cancel did anything, and the
    /// test could not tell the two apart. With real frames, a cancelled run
    /// throws `CancellationError` and `SubjectSessionModel` returns to
    /// `.idle`; the mutant runs to completion and lands on `.failed` (no
    /// people in a clip of flat grey), which is a different state and fails
    /// the assertion rather than hanging.
    func testCancelDuringAnalysisReturnsTheSessionToIdle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let clip = try makeRealVideoFile(in: root, name: "clip.mov", seconds: 4)

        let session = SubjectSessionModel()
        let scene = show(
            SubjectPickSheet(session: session, clip: clip, onConfirm: { _ in }),
            width: 520, height: 480
        )

        let running = Task { await session.analyse(clip: clip) }
        addTeardownBlock { running.cancel() }
        let started = Date().addingTimeInterval(10)
        while !isAnalysing(session.state), Date() < started {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(isAnalysing(session.state), "precondition: the analysis must actually be running")

        settle(scene)
        let buttons = controls(in: scene.host)
        XCTAssertEqual(buttons.count, 1, "precondition: the analysing state offers exactly one control, Cancel")
        click(buttons[0], in: scene.window)

        let finished = Date().addingTimeInterval(30)
        while isAnalysing(session.state), Date() < finished {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(
            session.state, .idle,
            "Cancel must reach session.cancel(): a cancelled run returns to idle, an uncancelled one fails"
        )
    }

    /// `SubjectSessionModel.State` is `Equatable` but `.analysing` carries a
    /// progress value, so matching it needs a pattern rather than `==`.
    private func isAnalysing(_ state: SubjectSessionModel.State) -> Bool {
        if case .analysing = state { return true }
        return false
    }

    // MARK: - The failed state's wording

    /// Finding nobody is an ordinary outcome, and the sheet says so in the
    /// operator's words rather than echoing `AnalysisError`'s log-shaped
    /// description with the filename in it.
    func testNoPeopleFoundReadsAsAnOutcomeRatherThanAnError() {
        XCTAssertEqual(
            SubjectPickSheet.readable(SubjectAnalyzer.AnalysisError.noPeopleFound("C0082.MP4").description),
            "No people were detected in this clip."
        )
        XCTAssertEqual(
            SubjectPickSheet.readable("something nobody anticipated"),
            "something nobody anticipated",
            "an unrecognised failure is shown as it arrived, not swallowed"
        )
    }

    // MARK: - Fixtures

    /// Two segments that do not overlap, declared later-first. The ordering is
    /// load-bearing in the confirm test: `ForEach` renders them in declaration
    /// order, so tapping card 0 then card 1 produces a tap order that differs
    /// from time order.
    private func pairInReverseTimeOrder() -> [AnalysedSegment] {
        [
            segment(id: 1, from: 30, to: 46, samples: 408),
            segment(id: 2, from: 4, to: 9, samples: 61),
        ]
    }

    /// No previews: `SegmentThumbnails.strip` returns nil for an empty preview
    /// list without touching the clip, so no test here needs a decodable file
    /// just to draw a card.
    private func segment(id: Int, from: TimeInterval, to: TimeInterval, samples: Int) -> AnalysedSegment {
        AnalysedSegment(
            id: id, firstSeen: from, lastSeen: to,
            detectionCount: samples, peakHeightFraction: 0.4, previews: []
        )
    }

    private func list(
        _ pick: SubjectPickModel,
        onConfirm: @escaping ([Int]) -> Void = { _ in }
    ) -> SubjectPickList {
        SubjectPickList(pick: pick, clip: URL(fileURLWithPath: "/dev/null"), onConfirm: onConfirm)
    }

    // MARK: - Hosting and clicking

    private struct Scene {
        let host: NSHostingView<AnyView>
        let window: NSWindow
    }

    /// Hosts a view in a real, off-screen `NSWindow`. The window is what makes
    /// the synthetic clicks below land; see the type comment.
    private func show(_ view: some View, width: CGFloat, height: CGFloat) -> Scene {
        let host = NSHostingView(rootView: AnyView(view.frame(width: width, height: height)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        // `.orderFront`, not `.makeKeyAndOrderFront`: the clicks only need the
        // window in the window server, not key — matching `ViewerControlsWiringTests`.
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        return Scene(host: host, window: window)
    }

    /// Lets SwiftUI rebuild and re-lay out after a state change, before the
    /// next control is located or clicked. Skipping this is the measured
    /// failure mode described in the type comment.
    private func settle(_ scene: Scene) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        scene.host.layoutSubtreeIfNeeded()
    }

    private func click(_ view: NSView, in window: NSWindow) {
        let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        window.sendEvent(mouseEvent(.leftMouseDown, at: point, windowNumber: window.windowNumber))
        window.sendEvent(mouseEvent(.leftMouseUp, at: point, windowNumber: window.windowNumber))
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, windowNumber: Int) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    /// Every SwiftUI-drawn button in the hosted tree, in tree order — which is
    /// declaration order: the cards as `ForEach` renders them, then the
    /// confirm button in the footer. Matched by class name for the same reason
    /// `SharedControlsWiringTests.scrubberSlider` does: `_FocusRingView` is
    /// not public API. Confirmed by dumping the tree before writing these
    /// tests, and every test that indexes into this asserts the count first,
    /// so a layout change that adds a control fails loudly instead of
    /// silently clicking the wrong thing.
    private func controls(in view: NSView) -> [NSView] {
        var found: [NSView] = []
        if String(describing: type(of: view)) == "_FocusRingView" { found.append(view) }
        for sub in view.subviews { found.append(contentsOf: controls(in: sub)) }
        return found
    }

    // MARK: - A real clip

    /// A real H.264 clip of a known length. Duplicated from
    /// `SharedControlsWiringTests`, which duplicated it from
    /// `SkiVideoCoreTests/RealVideoFixture.swift` — both are `private` to
    /// their own `XCTestCase`, so neither is reachable from here. Only the
    /// Cancel test needs it, and only because a cancellable analysis needs
    /// frames to be between.
    private func makeRealVideoFile(
        in directory: URL,
        name: String,
        seconds: Double,
        fps: Int32 = 10
    ) throws -> URL {
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
