import AppKit
import AVFoundation
import SwiftUI
import XCTest
// `@testable` for `load(_ url:side:)`, which is internal — building a fake
// library entry is a longer way round to the same call, exactly as
// `ComparisonLayoutMeasurementTests` reasons.
@testable import SkiVideoCore
@testable import SkiVideoViewer

/// Whether the control that loads or swaps a clip can be *found*, in each of
/// the three places it is offered.
///
/// **These tests rasterise. They do not search the AppKit view tree, and a
/// rewrite that does is a regression.** A view-tree search for `NSControl`s in
/// a pane that visibly renders a large blue button returns zero: SwiftUI's
/// `.borderedProminent` draws through a `_FocusRingView`, not an `NSButton`, so
/// the search finds nothing and proves nothing. That has now been measured
/// three times in this suite, twice by agents who then "fixed" something that
/// already worked. The question here is what an operator sees, so the
/// measurement is pixels, the same way `ComparisonLayoutMeasurementTests`
/// measures frames.
///
/// Every measurement is a **difference between two renders** — the shipped view
/// against the same view with the control taken out — never an absolute pixel
/// count. That is what the brief asked for, and it is also what makes the
/// numbers survive the renderer's own quirks: whatever both renders share
/// cancels, so only the control is left. See `differingFraction`.
///
/// **The pixels come from `ImageRenderer`, not from
/// `bitmapImageRepForCachingDisplay` / `cacheDisplay`. Measured, because that
/// pair has the same failure mode as the view-tree search:** a hosting view
/// containing exactly the pane's `.borderedProminent` "Choose Clip" button
/// caches out as an entirely black bitmap — the button is drawn by SwiftUI's
/// own display list and `cacheDisplay` walks `_FocusRingView`'s empty backing
/// layer instead — while `ImageRenderer` renders the same view with the button
/// there, blue and centred. A "simplification" back to `cacheDisplay` would
/// make the empty-pane regression guard measure a black rectangle and fail for
/// a reason that has nothing to do with the pane.
///
/// Neither renderer sees everything, which is why the probe writes both. What
/// `ImageRenderer` cannot draw is `NSViewRepresentable` content: it fills
/// `SinglePlayerView`'s rect with SwiftUI's yellow "unrenderable" placeholder
/// instead of the video. That changes no measurement here — the placeholder is
/// identical in a render and its baseline, so it cancels — but it does mean the
/// `…-imagerenderer.png` probe images show a yellow field where the app shows
/// the clip, and the `…-appkit.png` companions (black video, real chip, no
/// prominent button) are the other half of the picture.
///
/// Set `CHOOSER_PROBE_DIR` to have every render written out both ways:
///
///     CHOOSER_PROBE_DIR=/tmp/chooser-probe swift test --filter ClipChooserTests
@MainActor
final class ClipChooserTests: XCTestCase {
    /// Wide enough that the side-by-side panes are a realistic shape, and the
    /// same rect for every render so regions are comparable across them.
    private let videoArea = CGSize(width: 800, height: 320)

    override func setUp() {
        super.setUp()
        // NSHostingView lays nothing out until the shared application exists.
        // `.prohibited` keeps it out of the Dock and off the screen; nothing is
        // presented and no window is ordered in.
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    // MARK: - 1. The state that already works

    /// The regression guard, not the fix. An empty pane's prominent blue
    /// "Choose Clip" is the one placement of this control that an operator
    /// already finds, and it has to survive the other two being repaired — so
    /// it is pinned here, in the same terms the other tests use.
    ///
    /// Both panes, and asserted separately: a chooser that appeared in only one
    /// of them would pass a combined count, and with no clips loaded the two
    /// panes are otherwise identical.
    func testAnEmptyPaneStillShowsItsProminentChooser() throws {
        let model = ComparisonModel()
        defer { model.close() }

        let panes = try render(ComparisonVideos(model: model), named: "empty-pair")
        let video = try render(videoOnlyPair(model), named: "empty-pair-without-choosers")

        for side in [ComparisonSide.left, .right] {
            let drawn = differingFraction(panes, video, in: paneRect(side))
            // The button is a few thousand pixels in a 400×320 pane. 1% is far
            // below what it measures and far above the zero an empty pane would
            // give, which is the distinction being drawn.
            XCTAssertGreaterThan(
                drawn,
                0.01,
                """
                the empty \(ClipSourceMenu.sideName(side).lowercased()) pane draws \
                \(percent(drawn)) more than the bare video does; its centred \
                Choose Clip button is gone
                """
            )
        }
    }

    // MARK: - 2. The loaded pane

    /// The defect: a loaded pane's only chooser was an 8pt caption over black
    /// video, and it read as a label. It is now a material capsule with a
    /// chevron and a 44pt tap height, in the same bottom-leading spot — no row
    /// added, no layout height spent.
    ///
    /// Measured against the *empty* pane beside it in the same pair, whose
    /// chooser is centred and so leaves this band empty. Both fractions are
    /// differences from the same bare-video baseline, so the assertion compares
    /// like with like: how much of its band a pane with a chip marks, against
    /// how much a pane without one marks.
    ///
    /// The 20-point margin is the only absolute number in the file, and it
    /// separates two measured states quoted in the task report: the capsule
    /// covers most of the band it sits in, while bare text on black — what this
    /// looked like before, and what deleting the `.thinMaterial` capsule
    /// returns it to — marks only its own glyphs, a low single-figure
    /// percentage.
    func testALoadedPanesChipIsVisiblyAControl() throws {
        let model = try loadedModel(left: true, right: false)
        defer { model.close() }

        let panes = try render(ComparisonVideos(model: model), named: "left-loaded-pair")
        let video = try render(videoOnlyPair(model), named: "left-loaded-pair-without-choosers")

        let withChip = differingFraction(panes, video, in: chipBand(of: .left))
        let withoutChip = differingFraction(panes, video, in: chipBand(of: .right))

        XCTAssertGreaterThan(
            withChip,
            withoutChip + 0.20,
            """
            the loaded pane's chooser barely marks the band it sits in: \
            \(percent(withChip)) against \(percent(withoutChip)) for the same \
            band of the pane that has no chip in it. It reads as a caption, not \
            as a control.
            """
        )
    }

    // MARK: - 3. The overlay layout

    /// The other half of the defect: the overlay layout had no chooser at all.
    /// Switching to it with a side empty left no way to load that side, and no
    /// way to swap either clip.
    ///
    /// Two comparisons, because "something is drawn there" would pass with a
    /// single chip — and a single chip is exactly what the overlay cannot have,
    /// since both clips are drawn into one rect and either may need swapping.
    /// The second measures how far along the band the drawn pixels reach,
    /// against the same layout carrying one chip instead of two.
    func testTheOverlayLayoutOffersAChooserForEachSide() throws {
        let model = try loadedModel(left: true, right: false)
        model.layout = .overlay
        defer { model.close() }

        let withChips = try render(ComparisonVideos(model: model), named: "overlay-left-loaded")
        // The `.overlay` branch without the chips: the pure renderer on its
        // own, which is literally what that branch used to be.
        let bare = try render(overlayStack(model), named: "overlay-without-choosers")
        // The same branch carrying only the left chip.
        let oneChip = try render(
            overlayStack(model).overlay(alignment: .bottomLeading) {
                ClipSourceMenu(
                    model: model,
                    side: .left,
                    appearance: .overlayChip,
                    title: ClipSourceMenu.sidedTitle(model, .left)
                )
                .padding(8)
            },
            named: "overlay-with-one-chooser"
        )

        let band = CGRect(x: 0, y: 0, width: videoArea.width, height: 68)
        let drawn = differingFraction(withChips, bare, in: band)
        XCTAssertGreaterThan(
            drawn,
            0.02,
            """
            the overlay layout draws no clip chooser: its bottom band is \
            \(percent(drawn)) different from the bare player stack's. Switching \
            to Overlay with a side empty leaves no way to load it.
            """
        )

        let pairReach = try XCTUnwrap(
            differingBounds(withChips, bare, in: band),
            "nothing at all is drawn in the overlay's bottom band"
        ).maxX
        let singleReach = try XCTUnwrap(
            differingBounds(oneChip, bare, in: band),
            "the single-chip reference drew nothing; the comparison below would be meaningless"
        ).maxX
        XCTAssertGreaterThan(
            pairReach,
            singleReach + 20,
            """
            the overlay's bottom band reaches only \(pairReach)pt, against \
            \(singleReach)pt for a single chip — there is one chooser there, not \
            one per side, so one of the two clips cannot be swapped.
            """
        )
    }

    // MARK: - 4. Which side is which

    /// Both overlay chips sit in one rect with nothing around them to say which
    /// clip they swap, so each has to name its side — to VoiceOver, and to this
    /// test.
    ///
    /// **Asserted as a prefix, not as "the two labels differ".** Difference
    /// alone does not discriminate: build both chips with `side: .left` and the
    /// labels still differ, because the visible titles still differ. The side
    /// spoken first comes from `side` and from nothing else, so the prefix is
    /// what a mis-wired chip gets wrong. Both assertions are kept — the
    /// difference is what the operator needs, the prefix is what lets the test
    /// see it.
    ///
    /// The labels are read off the chips the shipped view builds rather than
    /// off chips the test builds; see `clipSourceMenus(in:)`.
    func testEachOverlayChipNamesItsSide() throws {
        let model = try loadedModel(left: true, right: false)
        model.layout = .overlay
        defer { model.close() }

        let labels = clipSourceMenus(in: ComparisonVideos(model: model)).map(\.spokenLabel)

        XCTAssertEqual(
            labels.count,
            2,
            "the overlay layout must offer one chooser per side; found \(labels)"
        )
        let left = try XCTUnwrap(
            labels.first { $0.hasPrefix("Left clip:") },
            "no chooser announces itself as the left clip's: \(labels)"
        )
        let right = try XCTUnwrap(
            labels.first { $0.hasPrefix("Right clip:") },
            "no chooser announces itself as the right clip's: \(labels)"
        )
        XCTAssertNotEqual(
            left,
            right,
            "the two choosers are indistinguishable to VoiceOver: \(labels)"
        )
        // Each names its own clip as well as its side, so the two are told
        // apart by what they do and not only by where they sit.
        XCTAssertTrue(left.contains("left.mov"), "the left chooser does not name the left clip: \(left)")
        XCTAssertTrue(
            right.contains(ClipSourceMenu.chooseTitle),
            "the empty right side's chooser must invite a choice: \(right)"
        )
    }

    // MARK: - The views, with the chooser taken out

    /// `ComparisonPane` minus its chooser: the `ZStack` its `body` opens with,
    /// and nothing else. The baseline every pane measurement differs against.
    private func videoOnlyPane(_ player: AVPlayer) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            SinglePlayerView(player: player)
        }
    }

    /// `ComparisonVideos`' side-by-side branch minus both choosers, laid out
    /// identically — same spacing, same 1pt divider — so the panes land in the
    /// same pixels as the real pair and the difference is the choosers alone.
    private func videoOnlyPair(_ model: ComparisonModel) -> some View {
        HStack(spacing: 1) {
            videoOnlyPane(model.leftPlayer)
            Divider().frame(width: 1)
            videoOnlyPane(model.rightPlayer)
        }
    }

    /// `ComparisonVideos`' overlay branch minus the choosers, which is exactly
    /// what that branch was before this task: the pure renderer on its own.
    private func overlayStack(_ model: ComparisonModel) -> some View {
        OverlayPlayerStack(
            bottomPlayer: model.leftPlayer,
            topPlayer: model.rightPlayer,
            topOpacity: model.topLayerOpacity,
            blend: model.blend
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Model

    /// A model with a clip in the sides asked for.
    ///
    /// `AVPlayerItem` accepts any URL and reports failure asynchronously, so an
    /// empty file is enough to give a player a `currentItem` — which is the
    /// whole of the "is this side loaded" signal these views read, and what
    /// `ComparisonModelTests` and `ComparisonLayoutMeasurementTests` already
    /// use.
    ///
    /// `Tests/SkiVideoCoreTests/RealVideoFixture.swift` is **not** reachable
    /// from this target — it is an `XCTestCase` extension compiled into
    /// `SkiVideoCoreTests`, a different test module — so a real clip here would
    /// mean copying its encoder. Nothing in this file wants one: no duration,
    /// no seek bound and no scrubber is measured, which is what that fixture
    /// exists for, and the renderer does not draw video frames in any case.
    private func loadedModel(left: Bool, right: Bool) throws -> ComparisonModel {
        let model = ComparisonModel()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        for (name, side, wanted) in [("left.mov", ComparisonSide.left, left), ("right.mov", .right, right)]
        where wanted {
            let url = root.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            model.load(url, side: side)
        }
        XCTAssertEqual(ClipSourceMenu.isLoaded(model, .left), left, "the left side is not in the state asked for")
        XCTAssertEqual(ClipSourceMenu.isLoaded(model, .right), right, "the right side is not in the state asked for")
        return model
    }

    // MARK: - Rasterising

    /// The rendered pixels of a view, laid out at the video area's size. See
    /// the type comment for why this is `ImageRenderer` and not `cacheDisplay`,
    /// and why the probe writes the `cacheDisplay` render as well.
    private func render(_ view: some View, named name: String) throws -> NSBitmapImageRep {
        let sized = view.frame(width: videoArea.width, height: videoArea.height)
        let renderer = ImageRenderer(content: sized)
        // Retina, so glyph antialiasing does not dominate the coverage of a
        // small control. Every measurement converts back to points.
        renderer.scale = 2
        let image = try XCTUnwrap(
            renderer.cgImage,
            "the view rendered no image; nothing below would be measuring anything"
        )
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = videoArea
        write(rep, named: "\(name)-imagerenderer")
        writeAppKitRender(of: sized, named: "\(name)-appkit")
        return rep
    }

    /// Every `ClipSourceMenu` the given view builds, in the order it builds
    /// them, read out of the SwiftUI value tree.
    ///
    /// **This is not the AppKit view-tree search the type comment warns off**,
    /// and it does not replace rasterising — the three tests that ask "can this
    /// be seen" all measure pixels. It answers the one question pixels cannot:
    /// which *side* each chip is wired to. The two overlay chips are
    /// distinguishable on screen only by their titles, and the titles are
    /// precisely what must not be trusted here, since a chip can carry the
    /// right title over the wrong side.
    ///
    /// The obvious way to ask would be the accessibility tree, and it does not
    /// exist in this process: measured, an offscreen `NSHostingView` wrapping
    /// two labelled buttons reports `accessibilityChildren() == []` and no
    /// label of its own, whether or not its window is ordered in. On iPad the
    /// same labels are read through a real accessibility tree by
    /// `CompareOnIPadUITests`, which is what covers "the label reaches the
    /// control"; this covers "the label names the right side", which no UI test
    /// can reach for the overlay layout.
    private func clipSourceMenus(in view: some View) -> [ClipSourceMenu] {
        var found: [ClipSourceMenu] = []
        var depth = 0
        func walk(_ value: Any) {
            // SwiftUI modifier chains nest deeply; the bound stops an
            // unexpected cycle turning a failure into a hang.
            guard depth < 32 else { return }
            if let menu = value as? ClipSourceMenu { found.append(menu) }
            depth += 1
            for child in Mirror(reflecting: value).children { walk(child.value) }
            depth -= 1
        }
        walk(view.body)
        return found
    }

    // MARK: - Measuring

    /// The fraction of pixels in `rect` that differ between two renders.
    ///
    /// `rect` is in points, in the rendered view's own coordinates — origin
    /// bottom-left, as `NSView` uses and as the `.bottomLeading` alignments
    /// under test are expressed in. The flip to the bitmap's top-left rows
    /// happens here, once.
    ///
    /// The 16/255 threshold ignores antialiasing seams while catching anything
    /// actually drawn: a material capsule, white text, a blue button and a
    /// chevron are all far beyond it.
    private func differingFraction(
        _ a: NSBitmapImageRep,
        _ b: NSBitmapImageRep,
        in rect: CGRect
    ) -> Double {
        let pixels = pixelRect(rect, in: a)
        guard pixels.width > 0, pixels.height > 0 else { return 0 }
        var changed = 0
        forEachDifference(a, b, in: pixels) { _, _ in changed += 1 }
        return Double(changed) / Double(pixels.width * pixels.height)
    }

    /// The bounding box, in view points, of the pixels that differ inside
    /// `rect` — or nil if none do. `maxX` is how far along a band something is
    /// drawn, which is what distinguishes two chips from one.
    private func differingBounds(
        _ a: NSBitmapImageRep,
        _ b: NSBitmapImageRep,
        in rect: CGRect
    ) -> CGRect? {
        let pixels = pixelRect(rect, in: a)
        guard pixels.width > 0, pixels.height > 0 else { return nil }
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        forEachDifference(a, b, in: pixels) { x, y in
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
        guard minX <= maxX else { return nil }
        let scale = self.scale(of: a)
        return CGRect(
            x: Double(minX) / scale,
            y: Double(minY) / scale,
            width: Double(maxX - minX + 1) / scale,
            height: Double(maxY - minY + 1) / scale
        )
    }

    private struct PixelRect {
        var x: Int, y: Int, width: Int, height: Int
    }

    private func scale(of rep: NSBitmapImageRep) -> Double {
        Double(rep.pixelsWide) / max(rep.size.width, 1)
    }

    private func pixelRect(_ rect: CGRect, in rep: NSBitmapImageRep) -> PixelRect {
        let scale = self.scale(of: rep)
        return PixelRect(
            x: max(0, Int((rect.minX * scale).rounded())),
            // Points measure up from the bottom; bitmap rows count down from
            // the top.
            y: max(0, Int(((rep.size.height - rect.maxY) * scale).rounded())),
            width: min(rep.pixelsWide, Int((rect.width * scale).rounded())),
            height: min(rep.pixelsHigh, Int((rect.height * scale).rounded()))
        )
    }

    /// Reads both bitmaps directly rather than through `colorAt(x:y:)`, which
    /// allocates an `NSColor` per pixel and takes minutes over an area this
    /// size.
    private func forEachDifference(
        _ a: NSBitmapImageRep,
        _ b: NSBitmapImageRep,
        in pixels: PixelRect,
        body: (Int, Int) -> Void
    ) {
        guard let left = a.bitmapData, let right = b.bitmapData else {
            XCTFail("a render gave no bitmap data; the comparison would silently see no difference")
            return
        }
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh,
              a.bitsPerPixel == b.bitsPerPixel, a.bytesPerRow == b.bytesPerRow
        else {
            XCTFail("the two renders are not the same shape, so they cannot be differenced")
            return
        }
        let stride = a.bytesPerRow
        let bytesPerPixel = a.bitsPerPixel / 8
        // The alpha channel says nothing about what was drawn — both renders
        // are opaque — so only the colour samples are read, whichever three of
        // the four they are. `NSBitmapImageRep(cgImage:)` is meshed
        // (non-planar), so one pixel's samples are adjacent.
        let firstColour = a.bitmapFormat.contains(.alphaFirst) ? 1 : 0
        for row in pixels.y..<min(pixels.y + pixels.height, a.pixelsHigh) {
            for column in pixels.x..<min(pixels.x + pixels.width, a.pixelsWide) {
                let offset = row * stride + column * bytesPerPixel
                var delta = 0
                for sample in firstColour..<(firstColour + 3) {
                    delta = max(delta, abs(Int(left[offset + sample]) - Int(right[offset + sample])))
                }
                if delta > 16 { body(column, row) }
            }
        }
    }

    // MARK: - Regions

    /// One pane of the side-by-side pair. The `HStack` spends 1pt on the
    /// divider, so the panes are not exactly half the area each; the divider
    /// itself is excluded from both.
    private func paneRect(_ side: ComparisonSide) -> CGRect {
        let width = (videoArea.width - 1) / 2
        return CGRect(
            x: side == .left ? 0 : width + 1,
            y: 0,
            width: width,
            height: videoArea.height
        )
    }

    /// The band a pane's bottom-leading chip occupies: the 44pt control plus
    /// the pane's 8pt inset, and 200pt across — comfortably wider than the chip
    /// itself, so what is measured is coverage rather than a filename's length.
    private func chipBand(of side: ComparisonSide) -> CGRect {
        CGRect(x: paneRect(side).minX, y: 0, width: 200, height: 60)
    }

    private func percent(_ fraction: Double) -> String {
        String(format: "%.1f%%", fraction * 100)
    }

    // MARK: - Probe output

    /// Writes a render out when `CHOOSER_PROBE_DIR` is set, so the images a
    /// human looks at are the images the tests measured — a probe rendering its
    /// own separate views could show a control the suite never measured, or
    /// measure one the reviewer never saw.
    private func write(_ rep: NSBitmapImageRep, named name: String) {
        guard let directory = ProcessInfo.processInfo.environment["CHOOSER_PROBE_DIR"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        guard let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("could not encode \(name) as PNG")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try png.write(to: url)
        } catch {
            XCTFail("could not write \(url.path): \(error)")
        }
    }

    /// The same view through AppKit's own capture path, for the probe only —
    /// never measured. It draws the letterbox and the material chip as the app
    /// does, and drops `.borderedProminent` buttons entirely, so it is the
    /// complement of the `ImageRenderer` image rather than a substitute for it.
    /// Both are written so a reviewer can see the whole window between them.
    private func writeAppKitRender(of view: some View, named name: String) {
        guard ProcessInfo.processInfo.environment["CHOOSER_PROBE_DIR"] != nil else { return }
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: videoArea)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        // `NSVisualEffectView` (which backs `.thinMaterial`) settles a beat
        // after layout; capturing before it does gives a chipless image.
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        window.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        write(rep, named: name)
    }
}
