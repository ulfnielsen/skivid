import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import SkiVideoCore
@testable import SkiVideoViewer

/// Proves the overlay's alignment controls are wired to `AlignmentSessionModel`
/// and that the renderer moves the clip it is supposed to — not merely that
/// everything compiles against everything else.
///
/// Mirrors `SharedControlsWiringTests`, including its technique and its
/// warnings. Two things were confirmed by probe before any assertion here was
/// written, both of which decided how the shipped views are built:
///
/// - `OverlayBlendBar` renders exactly two `NSButton`s — Align, then Compute —
///   with `target`/`action` nil, so `performClick(nil)` reaches the SwiftUI
///   closure and `sendAction(_:to:)` does not. A first version of the bar used
///   `Toggle(...).toggleStyle(.button)` for Align; that renders **no**
///   `NSControl` at all, and a synthetic click could not reach it. It is a
///   `Button` now, matching `ComparisonControlBar.anchorControl`.
/// - `.help(...)` does not reach `NSView.toolTip` in a hosted tree (measured:
///   nil on both buttons), so the *text* of the disabled explanation is
///   asserted where it is produced, in `AlignmentSessionModelTests`; what is
///   asserted here is that the control is actually disabled.
///
/// Nothing here claims a control is *visible*. This project has measured three
/// separate ways that offscreen rendering cannot answer that question — a
/// view-tree search finds no `NSControl` for a button that plainly renders,
/// `ImageRenderer` will not draw a `Menu`, and `fittingSize` reports a healthy
/// size for a control that paints nothing. Visibility is Task 5's, in the
/// running app.
@MainActor
final class OverlayAlignmentWiringTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        // NSHostingView lays nothing out until the shared application exists.
        // `.prohibited` keeps it out of the Dock and off the screen; nothing is
        // presented.
        NSApplication.shared.setActivationPolicy(.prohibited)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { [directory] in try? FileManager.default.removeItem(at: directory!) }
    }

    // MARK: - The controls

    /// Kills the mutation of replacing the Align button's
    /// `alignment.isAligned.toggle()` with `{}`. Nothing else in the suite
    /// drives that control: the core tests set `isAligned` on the model
    /// directly, bypassing the view entirely.
    func testClickingAlignReachesTheModel() throws {
        let alignment = try readyAlignment()
        let host = try host(bar(alignment: alignment))
        let buttons = try alignmentButtons(in: host)

        XCTAssertTrue(alignment.isAligned, "precondition: a computed track is drawn aligned")
        buttons.align.performClick(nil)
        XCTAssertFalse(alignment.isAligned, "clicking Align must reach the model")

        buttons.align.performClick(nil)
        XCTAssertTrue(alignment.isAligned, "Align must switch back, not latch off")
    }

    /// The other half of disabling, and not implied by the test above: a
    /// control that reads as disabled must not act on a click that reaches it
    /// anyway.
    func testAlignIsDisabledWithNoTrack() throws {
        let alignment = AlignmentSessionModel()
        let host = try host(bar(alignment: alignment))
        let buttons = try alignmentButtons(in: host)

        XCTAssertFalse(
            buttons.align.isEnabled,
            "Align must be disabled with nothing to align by; see alignmentUnavailableReason"
        )
        buttons.align.performClick(nil)
        XCTAssertTrue(
            alignment.isAligned,
            "a disabled Align must not change the model when clicked"
        )
        XCTAssertNil(
            alignment.translation(at: 0.4),
            "and with no track there is nothing to apply in any case"
        )
    }

    /// A track measured against different run starts describes a different
    /// comparison, so the control that would apply it is off — and says so.
    /// The string is asserted in `AlignmentSessionModelTests`; what this pins
    /// is that the bar actually consults it.
    func testAStaleTrackDisablesAlign() throws {
        let alignment = try readyAlignment(leftStartWhenLoading: 18.76)
        XCTAssertTrue(alignment.isStale, "precondition: the fixture must actually be stale")

        let host = try host(bar(alignment: alignment))
        let buttons = try alignmentButtons(in: host)

        XCTAssertFalse(buttons.align.isEnabled, "a stale track must not be applied from the bar")
        XCTAssertNotNil(
            alignment.alignmentUnavailableReason,
            "a disabled control with no reason attached is the thing this redesign removes"
        )
    }

    /// Kills the mutation of replacing `onComputeAlignment()` with `{}` in the
    /// bar. `ComparisonView` builds that closure; this proves the bar calls
    /// whatever it is handed, which is the first of the two links.
    func testClickingComputeAlignmentStartsThePass() throws {
        var started = 0
        let host = try host(
            bar(alignment: AlignmentSessionModel(), canCompute: true, onCompute: { started += 1 })
        )
        let buttons = try alignmentButtons(in: host)

        XCTAssertTrue(buttons.compute.isEnabled)
        buttons.compute.performClick(nil)

        XCTAssertEqual(started, 1, "Compute alignment must invoke the closure it was given")
    }

    /// The pass needs a local file and a run start on each side, so the bar
    /// refuses when `ComparisonView` says those are missing rather than
    /// offering work that would be declined.
    func testComputeIsDisabledUntilBothRunStartsAreKnown() throws {
        var started = 0
        let host = try host(
            bar(alignment: AlignmentSessionModel(), canCompute: false, onCompute: { started += 1 })
        )
        let buttons = try alignmentButtons(in: host)

        XCTAssertFalse(buttons.compute.isEnabled)
        buttons.compute.performClick(nil)
        XCTAssertEqual(started, 0, "a disabled Compute must not start the pass")
    }

    /// A Cancel that is drawn but does nothing is worse than none: the operator
    /// presses it and waits out the remaining fifteen seconds anyway. This runs
    /// a real pass, clicks the real control, and waits for the model to come
    /// back to idle.
    func testWhileComputingTheBarOffersAWorkingCancel() async throws {
        let alignment = AlignmentSessionModel(compute: { _, _, _, _, _ in
            while true {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        })
        let running = Task {
            await alignment.compute(
                left: left, right: right, leftStart: 18.56, rightStart: 4.40
            )
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        guard case .computing = alignment.state else {
            return XCTFail("precondition: the pass must be running; got \(alignment.state)")
        }

        let host = try host(bar(alignment: alignment))
        let buttons = buttons(in: host)
        XCTAssertEqual(
            buttons.count, 1,
            "while computing the bar shows the progress bar and a Cancel, and nothing else"
        )
        buttons[0].performClick(nil)
        await running.value

        guard case .idle = alignment.state else {
            return XCTFail("Cancel must stop the pass; got \(alignment.state)")
        }
    }

    /// A misspelt `systemName` renders an empty frame, silently: no error, no
    /// failed layout, just a control that is there, hittable and invisible.
    /// Neither renderer this project has measured would notice.
    func testTheAlignmentControlsSymbolsAreRealSFSymbols() {
        for name in [
            OverlayBlendBar.alignOnSymbol,
            OverlayBlendBar.alignOffSymbol,
            OverlayBlendBar.computeSymbol,
        ] {
            XCTAssertNotNil(
                NSImage(systemSymbolName: name, accessibilityDescription: nil),
                "\(name) is not a system symbol; the control would draw nothing"
            )
        }
    }

    // MARK: - The band the controls sit in

    /// Step 5 of the brief, for `OverlayBlendBar` rather than for the control
    /// bar: the two share the chrome band under the video, and
    /// `ComparisonControlBarLayoutTests` pins the other one.
    ///
    /// This bar is a plain `HStack` with no `ViewThatFits`, so it does not wrap
    /// — it compresses the slider instead. Measured at all three widths: 60pt,
    /// unchanged across them. It was **40pt** before the alignment controls
    /// joined it; the 20pt is the two 44pt hit targets, which is the rule this
    /// project keeps for controls it builds, and it is a row of video, not a
    /// second row of chrome.
    func testTheOverlayBandIsOneConstantHeightRowAtEveryIPadWidth() {
        let alignment = AlignmentSessionModel()
        let heights = [941.0, 834.0, 744.0].map { width in
            barHeight(alignment: alignment, width: CGFloat(width))
        }

        for (width, height) in zip([941.0, 834.0, 744.0], heights) {
            XCTAssertEqual(
                height, heights[0], accuracy: 0.5,
                "the overlay band is \(height)pt at \(width)pt against \(heights[0])pt at 941pt; it has wrapped"
            )
        }
        XCTAssertEqual(
            heights[0], 60, accuracy: 0.5,
            "the overlay band measured \(heights[0])pt; it was 60pt when this was written"
        )
    }

    /// The lesson `ComparisonControlBar.targetPicker` records, applied before it
    /// can bite: a group of controls that changed width when its state changed
    /// reflowed the whole bar. Here the state changes *by itself*, fifteen
    /// seconds after a click, so a variable width would slide the blend picker
    /// out from under the operator's pointer mid-gesture.
    ///
    /// Measured through the slider, which is the one greedy control in the row:
    /// anything the alignment group gains or loses comes out of its width.
    func testTheBarDoesNotReflowWhenThePassStarts() async throws {
        let idle = AlignmentSessionModel()
        let idleWidth = try sliderWidth(alignment: idle)

        let computing = AlignmentSessionModel(compute: { _, _, _, _, _ in
            while true {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        })
        let running = Task {
            await computing.compute(left: left, right: right, leftStart: 0, rightStart: 0)
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        guard case .computing = computing.state else {
            return XCTFail("precondition: the pass must be running; got \(computing.state)")
        }
        let computingWidth = try sliderWidth(alignment: computing)
        computing.cancel()
        await running.value

        XCTAssertEqual(
            idleWidth, computingWidth, accuracy: 0.5,
            "the bar reflows when the pass starts: the blend slider is \(idleWidth)pt idle "
                + "and \(computingWidth)pt while computing"
        )
    }

    // MARK: - Which clip moves

    /// **The whole of the alignment behaviour, and the mutation the brief calls
    /// for: apply the translation to the bottom player instead of the top.**
    ///
    /// The two stacked player views are identical black rects, so pixels cannot
    /// tell them apart — and neither renderer this project uses draws an
    /// `AVPlayerLayer` at all. What can tell them apart is the hosted AppKit
    /// tree: `SinglePlayerView` is an `NSViewRepresentable`, so each becomes a
    /// real `PlayerLayerHostView` holding its own `AVPlayer`, and SwiftUI's
    /// `.offset` moves the hosted view's frame — confirmed by probe before this
    /// test was written, and it is why `attachedPlayer` is readable.
    func testOnlyTheTopClipMoves() throws {
        let model = try loadedModel()
        defer { model.close() }
        let container = CGSize(width: 800, height: 400)

        let frames = try playerFrames(
            model: model,
            translation: CGVector(dx: 0.2, dy: 0.1),
            container: container
        )

        // The left clip is the reference: the pass does not warp it, and it
        // must not drift around the window either.
        XCTAssertEqual(frames.left.minX, 0, accuracy: 0.5, "the bottom (left) clip moved")
        XCTAssertEqual(frames.left.minY, 0, accuracy: 0.5, "the bottom (left) clip moved")

        // The right clip is the floating one, moved by the normalised
        // translation times the rendered width — both components by the
        // *width*, which is how the pass normalised them.
        XCTAssertEqual(
            frames.right.minX, 0.2 * container.width, accuracy: 0.5,
            "the top (right) clip is not offset by dx × width"
        )
        XCTAssertEqual(
            frames.right.minY, 0.1 * container.width, accuracy: 0.5,
            "the top (right) clip is not offset by dy × width — dy must scale by width too"
        )
    }

    /// The state the overlay is in whenever the gate says identity, which is
    /// most of a run: both clips exactly where they were before alignment
    /// existed.
    func testAnIdentityTranslationLeavesBothClipsAlone() throws {
        let model = try loadedModel()
        defer { model.close() }

        let frames = try playerFrames(
            model: model, translation: .zero, container: CGSize(width: 800, height: 400)
        )

        XCTAssertEqual(frames.left.origin.x, 0, accuracy: 0.5)
        XCTAssertEqual(frames.left.origin.y, 0, accuracy: 0.5)
        XCTAssertEqual(frames.right.origin.x, 0, accuracy: 0.5)
        XCTAssertEqual(frames.right.origin.y, 0, accuracy: 0.5)
    }

    /// A normalised translation is a fraction of the *video's* width, and the
    /// video is aspect-fit — so in a video area wider than the clip, the clip
    /// is pillarboxed and the container's width is the wrong ruler.
    ///
    /// A 16:9 clip in the 2:1 area the Compare window gives it draws 889pt wide
    /// inside 1000pt: scaling by the container would overshoot every offset by
    /// 12.5%, in a screen whose entire job is alignment.
    func testTheOffsetScalesByTheRenderedVideoWidthNotTheContainer() {
        let container = CGSize(width: 1000, height: 500)
        let sixteenByNine = CGSize(width: 1920, height: 1080)

        let offset = OverlayPlayerStack.offset(
            for: CGVector(dx: 0.1, dy: 0), in: container, videoSize: sixteenByNine
        )

        XCTAssertEqual(
            OverlayPlayerStack.renderedVideoWidth(container: container, videoSize: sixteenByNine),
            888.888, accuracy: 0.01
        )
        XCTAssertEqual(offset.width, 88.888, accuracy: 0.01)
        XCTAssertNotEqual(
            offset.width, 100, accuracy: 1,
            "the offset was scaled by the container width, which the pillarboxed video does not fill"
        )
    }

    /// A letterboxed clip — taller than its area — is the mirror case, and the
    /// height is what binds there.
    func testALetterboxedClipScalesByItsOwnWidthToo() {
        let width = OverlayPlayerStack.renderedVideoWidth(
            container: CGSize(width: 1000, height: 400),
            videoSize: CGSize(width: 1080, height: 1920)
        )
        XCTAssertEqual(width, 225, accuracy: 0.01)
    }

    /// Before its item loads, a player reports no presentation size at all.
    /// There is nothing better to say than the container then, and a zero
    /// divisor would be worse than either.
    func testAnUnknownPresentationSizeFallsBackToTheContainer() {
        XCTAssertEqual(
            OverlayPlayerStack.renderedVideoWidth(
                container: CGSize(width: 800, height: 400), videoSize: .zero
            ),
            800
        )
        XCTAssertEqual(
            OverlayPlayerStack.renderedVideoWidth(container: .zero, videoSize: .zero),
            0
        )
    }

    // MARK: - The region the two clips share

    /// Unaligned, nothing is cropped. This is most of a run, and it is what the
    /// overlay drew before alignment existed, so it must be exactly unchanged.
    func testAnIdentityTranslationCropsNothing() {
        let container = CGSize(width: 1000, height: 500)

        XCTAssertEqual(
            OverlayPlayerStack.sharedRect(
                for: .zero, in: container, videoSize: CGSize(width: 1920, height: 1080)
            ),
            CGRect(origin: .zero, size: container)
        )
        // ...including before the item reports a presentation size.
        XCTAssertEqual(
            OverlayPlayerStack.sharedRect(for: .zero, in: container, videoSize: .zero),
            CGRect(origin: .zero, size: container)
        )
    }

    /// **The geometry the crop is, asserted as arithmetic rather than as
    /// pixels.** `sharedRect` is a pure function of `(translation, container,
    /// videoSize)` for exactly this reason: the y-axis sign bug reached the
    /// operator because the only assertion about the offset was that a hosted
    /// view's *frame* moved, and a frame moving is not a picture moving. Every
    /// offscreen check this project has tried has been measured to lie in some
    /// direction — a view-tree search finds no `NSControl` for a button that
    /// plainly renders, `ImageRenderer` will not draw a `Menu`, `cacheDisplay`
    /// renders one as empty, `fittingSize` reports a healthy size for a control
    /// that paints nothing — so what is pinned here is the number the view
    /// computes, not a rendering of it.
    ///
    /// `dx 0.08` and `dy -0.13` are deliberately unequal and oppositely signed:
    /// a transposed axis, a mirrored edge, or a `dy` scaled by the rendered
    /// *height* instead of the width all give a different answer, and the last
    /// three assertions say so out loud.
    func testAPositiveDXAndANegativeDYCropFromTheLeftAndTheBottom() {
        let container = CGSize(width: 1000, height: 500)
        let video = CGSize(width: 1920, height: 1080)
        let renderedWidth = OverlayPlayerStack.renderedVideoWidth(container: container, videoSize: video)
        let renderedHeight = OverlayPlayerStack.renderedVideoHeight(container: container, videoSize: video)
        let full = OverlayPlayerStack.videoRect(container: container, videoSize: video)

        let shared = OverlayPlayerStack.sharedRect(
            for: CGVector(dx: 0.08, dy: -0.13), in: container, videoSize: video
        )

        // The top clip moves right, so what it moves away from is the left edge.
        XCTAssertEqual(
            shared.minX, full.minX + 0.08 * renderedWidth, accuracy: 1,
            "the crop is not taken from the left edge the shift moves away from"
        )
        XCTAssertEqual(shared.maxX, full.maxX, accuracy: 1, "the right edge was cropped as well")
        // ...and up — y grows downward here — so the bottom edge is the other one.
        XCTAssertEqual(shared.minY, full.minY, accuracy: 1, "the top edge was cropped instead")
        XCTAssertEqual(
            shared.maxY, full.maxY - 0.13 * renderedWidth, accuracy: 1,
            "the crop is not taken from the bottom edge"
        )

        XCTAssertEqual(shared.width, renderedWidth * (1 - 0.08), accuracy: 1)
        XCTAssertEqual(shared.height, renderedHeight - 0.13 * renderedWidth, accuracy: 1)

        XCTAssertNotEqual(
            shared.width, renderedWidth * (1 - 0.13), accuracy: 1,
            "the two axes are transposed: the width was inset by dy"
        )
        XCTAssertNotEqual(
            shared.height, renderedHeight * (1 - 0.13), accuracy: 1,
            "dy was scaled by the rendered height; both components scale by the width"
        )
        XCTAssertNotEqual(
            shared.height, renderedHeight - 0.08 * renderedWidth, accuracy: 1,
            "the two axes are transposed: the height was inset by dx"
        )
    }

    /// Masking only the offset clip would leave the stationary one showing
    /// through the strip where the other has no picture at all, which is the
    /// artefact the crop exists to remove.
    ///
    /// **What this measures.** Probed before it was written: SwiftUI's `.mask`
    /// on an `NSViewRepresentable` becomes a real clipping `NSView` wrapped
    /// around each hosted player, and its frame in host coordinates is exactly
    /// the rect `sharedRect` computes — (160, 0, 640, 320) here, against a
    /// container of 800 × 400. With a mask removed from one player, that
    /// player's nearest clipping ancestor is the stack's own `.clipped()`, at
    /// the full container, and these two assertions disagree.
    ///
    /// **What it does not prove.** That the video pixels outside the rect are
    /// actually not drawn. Neither renderer this project has measured draws an
    /// `AVPlayerLayer` at all, so no offscreen image can answer that; the
    /// operator judging the running app is what closes it. This says the two
    /// clips are clipped, to the same rect, and to the computed one.
    func testBothPlayersAreMaskedToTheSameSharedRegion() throws {
        let model = try loadedModel()
        defer { model.close() }
        let container = CGSize(width: 800, height: 400)
        let translation = CGVector(dx: 0.2, dy: -0.1)

        let clips = try playerClipRects(
            model: model, translation: translation, container: container
        )

        // The fixture's items never report a presentation size, so the video
        // rect is the whole container — which is what makes the expected
        // numbers plain: 800 × 400 inset by 0.2 × 800 and 0.1 × 800.
        let expected = OverlayPlayerStack.sharedRect(
            for: translation, in: container, videoSize: .zero
        )
        XCTAssertEqual(expected, CGRect(x: 160, y: 0, width: 640, height: 320))

        assertRect(clips.left, equals: expected, "the bottom (left) clip is not masked to the shared region")
        assertRect(clips.right, equals: expected, "the top (right) clip is not masked to the shared region")
    }

    // MARK: - Saying so

    /// The chip has to be able to carry the note without silently dropping it,
    /// and without losing the constant width that keeps it out of the left
    /// pane — `ComparisonStatusChipTests` measures that width against the
    /// longest status the model can produce.
    func testTheStatusChipMakesRoomForTheAlignmentNote() {
        let status = "Synced from detected starts · L 00:18.56 · R 00:04.40"
        let plain = chipSize(status: status, note: nil)
        let noted = chipSize(status: status, note: "Not aligned here — the cameras share too little of the view.")

        // `fittingSize` reports the *ideal* width — 281pt plain, 304.5pt with
        // the note — where the shipped chip lays out at a constant 340pt,
        // because `frame(maxWidth: 320)` is greedy inside a real container.
        // `ComparisonStatusChipTests` measures the 340pt; what matters here is
        // that the note cannot push past the 320pt text cap it is drawn inside,
        // which is the thing keeping the pill off the left pane.
        XCTAssertLessThanOrEqual(
            noted.width, 340,
            "the note widened the chip to \(noted.width)pt, past the 320 + 2×10 cap"
        )
        XCTAssertGreaterThan(
            noted.width, plain.width - 0.5,
            "precondition: the note is longer than the status, so it is what sets the ideal width"
        )
        XCTAssertGreaterThan(
            noted.height, plain.height,
            "the note is not drawn at all: the chip is the same height with and without it"
        )
    }

    // MARK: - Fixtures

    private var left: URL { directory.appendingPathComponent("C0094.MP4") }
    private var right: URL { directory.appendingPathComponent("C0092.MP4") }

    /// A session with a healthy 25 Hz track loaded, through the real store —
    /// so `loadStored`, the sidecar naming and the staleness check are all the
    /// shipped ones.
    private func readyAlignment(
        leftStartWhenLoading: TimeInterval = 18.56
    ) throws -> AlignmentSessionModel {
        let stored = AlignmentTrack(
            version: AlignmentTrack.currentVersion, computedAt: Date(timeIntervalSince1970: 1_754_140_000),
            leftClip: left.lastPathComponent, rightClip: right.lastPathComponent,
            leftStart: 18.56, rightStart: 4.40, parameters: .current,
            samples: (0..<60).map { index in
                AlignmentSample(
                    time: Double(index) * 0.04,
                    translation: CGVector(dx: 0.02, dy: -0.01),
                    overlap: 0.85, residual: 5, identityResidual: 9
                )
            }
        )
        try AlignmentTrackStore.save(stored, left: left, right: right)
        let session = AlignmentSessionModel()
        session.loadStored(
            left: left, right: right,
            leftStart: leftStartWhenLoading, rightStart: 4.40
        )
        return session
    }

    private func bar(
        alignment: AlignmentSessionModel,
        canCompute: Bool = true,
        onCompute: @escaping () -> Void = {}
    ) -> OverlayBlendBar {
        OverlayBlendBar(
            model: ComparisonModel(),
            alignment: alignment,
            canComputeAlignment: canCompute,
            onComputeAlignment: onCompute
        )
    }

    /// `AVPlayerItem` accepts any URL and reports failure asynchronously, so an
    /// empty file is enough to give each player a `currentItem` — which is all
    /// the overlay renderer reads, and what `ComparisonModelTests` and
    /// `ClipChooserTests` already use. No frames are decoded here; the offsets
    /// measured are layout, not video.
    private func loadedModel() throws -> ComparisonModel {
        let model = ComparisonModel()
        for (url, side) in [(left, ComparisonSide.left), (right, .right)] {
            FileManager.default.createFile(atPath: url.path, contents: Data())
            model.load(url, side: side)
        }
        return model
    }

    // MARK: - View-tree walking

    private func host(_ view: OverlayBlendBar, width: CGFloat = 941) throws -> NSHostingView<some View> {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// Both buttons the bar renders, in the order it declares them.
    ///
    /// The count is a precondition rather than an assumption: if a third
    /// control joins the bar, this must be re-measured rather than silently
    /// clicking the wrong one — the same discipline
    /// `SharedControlsWiringTests` applies to the control bar's eight.
    private func alignmentButtons(
        in host: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (align: NSButton, compute: NSButton) {
        let buttons = buttons(in: host)
        XCTAssertEqual(
            buttons.count, 2,
            "the bar must render exactly Align and Compute alignment", file: file, line: line
        )
        guard buttons.count == 2 else { throw XCTSkip("no controls to drive") }
        return (buttons[0], buttons[1])
    }

    private func buttons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        if let button = view as? NSButton { found.append(button) }
        for sub in view.subviews { found.append(contentsOf: buttons(in: sub)) }
        return found
    }

    private func barHeight(alignment: AlignmentSessionModel, width: CGFloat) -> CGFloat {
        let host = NSHostingView(
            rootView: bar(alignment: alignment).frame(width: width)
        )
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// The blend slider's laid-out width, which absorbs every point the rest of
    /// the row does or does not take.
    private func sliderWidth(alignment: AlignmentSessionModel) throws -> CGFloat {
        let host = NSHostingView(rootView: bar(alignment: alignment).frame(width: 941))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 941, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return try XCTUnwrap(slider(in: host), "expected to find the blend slider").frame.width
    }

    private func slider(in view: NSView) -> NSSlider? {
        if let slider = view as? NSSlider { return slider }
        for sub in view.subviews {
            if let found = slider(in: sub) { return found }
        }
        return nil
    }

    /// Where each clip's player view actually lands inside the stack.
    private func playerFrames(
        model: ComparisonModel,
        translation: CGVector,
        container: CGSize
    ) throws -> (left: CGRect, right: CGRect) {
        let host = NSHostingView(
            rootView: OverlayPlayerStack(
                bottomPlayer: model.leftPlayer,
                topPlayer: model.rightPlayer,
                topOpacity: model.topLayerOpacity,
                blend: model.blend,
                translation: translation
            )
            .frame(width: container.width, height: container.height)
        )
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: container),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        var views: [PlayerLayerHostView] = []
        func walk(_ view: NSView) {
            if let player = view as? PlayerLayerHostView { views.append(player) }
            view.subviews.forEach(walk)
        }
        walk(host)
        XCTAssertEqual(views.count, 2, "the overlay must host exactly two player views")

        let leftView = try XCTUnwrap(
            views.first { $0.attachedPlayer === model.leftPlayer },
            "no hosted view is drawing the left clip"
        )
        let rightView = try XCTUnwrap(
            views.first { $0.attachedPlayer === model.rightPlayer },
            "no hosted view is drawing the right clip"
        )
        return (leftView.convert(leftView.bounds, to: host), rightView.convert(rightView.bounds, to: host))
    }

    /// The rect each clip is clipped to, in the stack's own coordinates.
    ///
    /// The nearest clipping ancestor of each hosted player: SwiftUI's `.mask`
    /// wraps the representable in one, and with the mask gone the nearest one
    /// is the stack's `.clipped()` at the full container instead.
    private func playerClipRects(
        model: ComparisonModel,
        translation: CGVector,
        container: CGSize
    ) throws -> (left: CGRect, right: CGRect) {
        let host = NSHostingView(
            rootView: OverlayPlayerStack(
                bottomPlayer: model.leftPlayer,
                topPlayer: model.rightPlayer,
                topOpacity: model.topLayerOpacity,
                blend: model.blend,
                translation: translation
            )
            .frame(width: container.width, height: container.height)
        )
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: container),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        var views: [PlayerLayerHostView] = []
        func walk(_ view: NSView) {
            if let player = view as? PlayerLayerHostView { views.append(player) }
            view.subviews.forEach(walk)
        }
        walk(host)
        XCTAssertEqual(views.count, 2, "the overlay must host exactly two player views")

        func clipRect(of view: NSView) throws -> CGRect {
            var ancestor = view.superview
            while let current = ancestor {
                if current.clipsToBounds { return current.convert(current.bounds, to: host) }
                ancestor = current.superview
            }
            throw XCTSkip("no clipping ancestor at all — the probe this rests on has changed")
        }

        let leftView = try XCTUnwrap(views.first { $0.attachedPlayer === model.leftPlayer })
        let rightView = try XCTUnwrap(views.first { $0.attachedPlayer === model.rightPlayer })
        return (try clipRect(of: leftView), try clipRect(of: rightView))
    }

    private func assertRect(
        _ rect: CGRect,
        equals expected: CGRect,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(rect.minX, expected.minX, accuracy: 0.5, "\(message) (x)", file: file, line: line)
        XCTAssertEqual(rect.minY, expected.minY, accuracy: 0.5, "\(message) (y)", file: file, line: line)
        XCTAssertEqual(rect.width, expected.width, accuracy: 0.5, "\(message) (width)", file: file, line: line)
        XCTAssertEqual(rect.height, expected.height, accuracy: 0.5, "\(message) (height)", file: file, line: line)
    }

    /// The pill's laid-out size, measured the way `ComparisonStatusChipTests`
    /// measures it — inside a window, so SwiftUI actually runs a layout pass.
    private func chipSize(status: String, note: String?) -> CGSize {
        let host = NSHostingView(rootView: ComparisonStatusChip(status: status, alignmentNote: note))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return host.fittingSize
    }
}
