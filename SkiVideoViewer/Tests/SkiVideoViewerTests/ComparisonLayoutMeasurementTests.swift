import AppKit
import SwiftUI
import XCTest
// `@testable` for the loader that takes a URL: `ComparisonVideoChoice`'s
// memberwise init is internal, and building a fake library entry is a longer
// way round to the same call.
@testable import SkiVideoCore
@testable import SkiVideoViewer

/// Headless layout measurement for the two comparison views whose *geometry*
/// is the thing that can regress silently.
///
/// The iPad UI tests can assert that a control exists, is hittable and is
/// inside the window. They cannot assert how tall the bar is, whether it
/// changed height, or how wide the chip laid out for a sentence the test
/// cannot make the model produce. Those need a real layout pass, which is what
/// `NSHostingView` gives without launching anything: no app is started, no
/// window is ordered on screen, nothing is pointed at the user's library.
///
/// macOS metrics are not iPadOS metrics — a segmented picker is 24pt here and
/// 32pt there — so these tests pin *invariants* (equal, constant, clear of the
/// midline), plus the two constants that are hard-coded in the views
/// themselves and are therefore platform-independent.
@MainActor
final class ComparisonControlBarLayoutTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // NSHostingView needs the shared application to exist before it will
        // lay anything out. `.prohibited` keeps it out of the Dock and off the
        // screen; nothing is presented.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
    }

    /// **The invariant this whole file exists for.** The target picker carries
    /// a constant 160pt width precisely so the bar's ideal width — and so the
    /// width at which it wraps — cannot depend on `isSynced`. With the
    /// variable 110/160 width the brief originally specified, the two ideal
    /// widths were 830.5pt and 880.5pt, which *straddle* 834pt: tapping the
    /// anchor on an 11-inch iPad in portrait reflowed the bar from one row to
    /// two and resized the video above it mid-alignment.
    ///
    /// Nothing else in the repo would notice that coming back. The iPad UI
    /// tests cannot reach the synced state at all — `setSyncPoints()` requires
    /// two loaded clips and no UI test can load one.
    func testTheBarIsTheSameHeightSyncedAsAligning() throws {
        let aligning = ComparisonModel()
        let synced = try makeSyncedModel()

        XCTAssertEqual(aligning.availableTargets.count, 2, "aligning must not offer Both")
        XCTAssertEqual(synced.availableTargets.count, 3, "synced must offer Both")

        for width in [834.0, 744.0] as [CGFloat] {
            let aligningHeight = barHeight(model: aligning, width: width)
            let syncedHeight = barHeight(model: synced, width: width)
            XCTAssertEqual(
                aligningHeight,
                syncedHeight,
                accuracy: 0.5,
                """
                the bar changes height when the anchor is tapped at \(width)pt \
                (\(aligningHeight) aligning vs \(syncedHeight) synced), which \
                resizes the video mid-alignment
                """
            )
        }
    }

    /// The wrap itself, at the measured threshold. 880.5pt is the bar's ideal
    /// width, so 881pt fits on one row and 880pt does not — and every iPad
    /// portrait width is below it, which is why the screenshots at 834pt and
    /// 744pt show a two-row bar and three rows of chrome rather than two.
    ///
    /// Asserted as "one row is shorter than two, and the change happens
    /// between 880 and 881" rather than as absolute point values, because the
    /// row heights are macOS metrics (60pt/112pt here) and would not
    /// transfer.
    func testTheBarWrapsBetween880And881Points() throws {
        let model = ComparisonModel()
        let oneRow = barHeight(model: model, width: 881)
        let twoRows = barHeight(model: model, width: 880)

        XCTAssertGreaterThan(
            twoRows,
            oneRow,
            "880pt must wrap to a taller layout than 881pt; measured \(twoRows) vs \(oneRow)"
        )
        for width in [834.0, 744.0] as [CGFloat] {
            XCTAssertEqual(
                barHeight(model: model, width: width),
                twoRows,
                accuracy: 0.5,
                "\(width)pt is below the threshold and must use the wrapped layout"
            )
        }
    }

    /// Two clips loaded and synced, reached exactly as `ComparisonModelTests`
    /// does it: `AVPlayerItem` accepts any URL and reports failure
    /// asynchronously, so an empty file is enough to give a player a
    /// `currentItem`, which is all `hasTwoVideos` — and therefore
    /// `setSyncPoints()` — requires. No decodable media, and nothing anywhere
    /// near the user's footage.
    private func makeSyncedModel() throws -> ComparisonModel {
        let model = ComparisonModel()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        for (name, side) in [("left.mov", ComparisonSide.left), ("right.mov", .right)] {
            let url = root.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            model.load(url, side: side)
        }
        model.setSyncPoints()
        XCTAssertTrue(model.isSynced, "the harness must actually reach the synced state")
        return model
    }

    private func barHeight(model: ComparisonModel, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: ComparisonControlBar(model: model).frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
}

/// The status chip's width is the only thing keeping it out of the left pane,
/// and it is a *constant* by construction rather than by luck.
///
/// Task 3 asserted the cap from the UI test and reasoned that the longest
/// status was unreachable "because every status writer needs two clips". That
/// is false: `ComparisonModel.removeSync()` has no `hasTwoVideos` or
/// `isSynced` guard, so a bare model with zero clips loaded writes exactly the
/// longest sentence the model can produce. These tests drive that real string
/// into the real view and measure what it lays out to, rather than inferring
/// safety from the constant alone.
@MainActor
final class ComparisonStatusChipTests: XCTestCase {
    override func setUp() {
        super.setUp()
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    /// The premise, pinned. If a later change adds a guard to `removeSync()`
    /// the two tests below would quietly fall back to measuring the initial
    /// 46-character status — which fits comfortably and proves nothing — so
    /// the reachability of the long string is asserted separately and by name.
    func testTheLongestStatusIsReachableWithNoClipsLoaded() {
        let model = ComparisonModel()
        let initial = model.status
        model.removeSync()

        XCTAssertGreaterThan(
            model.status.count,
            initial.count,
            "removeSync must still be reachable with no clips; it is the only route to the long status"
        )
        XCTAssertGreaterThanOrEqual(
            model.status.count,
            83,
            "the longest status was 83 characters; measured \(model.status.count): \(model.status)"
        )
    }

    /// Measured, not derived: the chip is laid out inside a container of each
    /// iPad portrait width with the same top-trailing alignment
    /// `ComparisonView` uses, and its rendered frame is read back through a
    /// `GeometryReader`.
    ///
    /// The failure this reproduces is the one the review caught: with the
    /// width cap removed the *initial* 46-character status lays out at 301pt
    /// and clears the divider, so the common case looks fine, while the
    /// 83-character one overruns into the left pane and covers the filename.
    /// Both strings are measured here, and the assertion that they are equal
    /// is the one that fails when the cap goes.
    func testTheChipIsTheSameWidthForTheShortestAndLongestStatus() {
        let model = ComparisonModel()
        let shortest = model.status
        model.removeSync()
        let longest = model.status

        for width in [834.0, 744.0] as [CGFloat] {
            let short = chipFrame(status: shortest, containerWidth: width)
            let long = chipFrame(status: longest, containerWidth: width)
            XCTAssertEqual(
                short.width,
                long.width,
                accuracy: 0.5,
                """
                the chip sizes to its text at \(width)pt: \(short.width) for the \
                initial status vs \(long.width) for the longest one
                """
            )
            XCTAssertEqual(
                long.width,
                340,
                accuracy: 0.5,
                "the chip must be a constant 340pt wide; measured \(long) at \(width)pt"
            )
        }
    }

    /// Where it actually lands, with the sentence that used to break it. The
    /// panes split the window evenly, so "entirely inside the right half" is
    /// the same bound as "does not reach the left pane's filename" — and the
    /// filenames only exist once clips are loaded, which is why this is the
    /// bound asserted rather than an intersection test.
    ///
    /// The expected values are Task 3's measurements at the two widths:
    /// (486, 340) against a midpoint of 417, and (396, 340) against 372.
    func testTheChipStaysInTheRightHalfWithTheLongestStatus() {
        let model = ComparisonModel()
        model.removeSync()

        for width in [834.0, 744.0] as [CGFloat] {
            let frame = chipFrame(status: model.status, containerWidth: width)
            XCTAssertGreaterThanOrEqual(
                frame.minX,
                width / 2,
                "the chip reaches into the left pane at \(width)pt: \(frame)"
            )
            XCTAssertLessThanOrEqual(
                frame.maxX,
                width,
                "the chip is clipped at \(width)pt: \(frame)"
            )
        }
    }

    /// The detected-sync sentence is a new candidate for longest status, and
    /// the chip is a constant 340pt clipped to two lines. If it does not fit,
    /// it is silently truncated — the failure mode the chip's width cap exists
    /// to prevent.
    ///
    /// **Not measured through `chipFrame`/`ComparisonStatusChip`.** That view
    /// applies `.lineLimit(2)`, which caps the laid-out height at two lines'
    /// worth for *any* text that needs two lines or more — a sentence that
    /// needs exactly two and one that needs five report the identical height,
    /// because both are truncated down to the same two-line box. A first
    /// version of this test compared `chipFrame` heights and passed even after
    /// the status was deliberately tripled in length (mutation-checked per the
    /// task brief), which is exactly the "harness measures nothing" failure
    /// the brief warned about. So this measures the *unclipped* text instead —
    /// same font, same 320pt max width, same centered multiline layout as
    /// `ComparisonStatusChip.body`, just without the `.lineLimit(2)` that
    /// hides an overflow from view.
    func testTheDetectedSyncStatusFitsTheChip() throws {
        let model = ComparisonModel()
        defer { model.close() }
        let leftFile = try makeVideoFile("left.mov")
        let rightFile = try makeVideoFile("right.mov")
        model.load(leftFile, side: .left)
        model.load(rightFile, side: .right)
        model.applySync(left: 18.64, right: 4.42)

        let actual = naturalTextHeight(model.status)
        // An explicit newline, not a wrap: two short segments forced onto two
        // lines give the same per-line height a wrapped two-line paragraph
        // would, without depending on where any particular sentence happens
        // to wrap.
        let twoLines = naturalTextHeight("line one\nline two")

        XCTAssertLessThanOrEqual(
            actual, twoLines + 1,
            "the detected-sync status needs more than two lines (\(actual)pt vs \(twoLines)pt for two): \(model.status)"
        )
    }

    /// The unclipped counterpart to `chipFrame`: renders `Text` styled exactly
    /// as `ComparisonStatusChip.body` does — `.caption` font, centered,
    /// `maxWidth: 320` — but without `.lineLimit(2)`, so a sentence that wraps
    /// past two lines shows up as a taller measured frame instead of being
    /// silently cropped to the same two-line box.
    private func naturalTextHeight(_ text: String) -> CGFloat {
        let box = FrameBox()
        let host = NSHostingView(rootView: TextHeightProbe(text: text, report: { box.frame = $0 }))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 340, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let deadline = Date().addingTimeInterval(5)
        while box.frame == .zero, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotEqual(
            box.frame,
            .zero,
            "the geometry probe never reported; the measurement below would be meaningless"
        )
        return box.frame.height
    }

    private struct TextHeightProbe: View {
        let text: String
        let report: (CGRect) -> Void

        var body: some View {
            Text(text)
                .font(.caption)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ChipFrameKey.self, value: proxy.frame(in: .local))
                    }
                )
                .onPreferenceChange(ChipFrameKey.self) { report($0) }
        }
    }

    /// `AVPlayerItem` accepts any URL and reports failure asynchronously, so
    /// an empty file is enough to give a player a `currentItem` — which is all
    /// `hasTwoVideos`, and therefore `applySync`'s `setSyncPoints()` call,
    /// require. Mirrors the fixture helper `ComparisonModelTests` uses.
    private func makeVideoFile(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    /// The rendered frame of the pill inside a container laid out exactly as
    /// `ComparisonView` lays it out: top-trailing over the video, with the 8pt
    /// inset that view applies. Fails the test rather than returning `.zero`
    /// if the layout never reported, so a probe that silently stopped
    /// measuring cannot read as a pass.
    private func chipFrame(status: String, containerWidth: CGFloat) -> CGRect {
        let box = FrameBox()
        let host = NSHostingView(
            rootView: ChipProbe(
                status: status,
                width: containerWidth,
                height: 600,
                report: { box.frame = $0 }
            )
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: containerWidth, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let deadline = Date().addingTimeInterval(5)
        while box.frame == .zero, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotEqual(
            box.frame,
            .zero,
            "the geometry probe never reported; the measurement below would be meaningless"
        )
        return box.frame
    }

    private final class FrameBox {
        var frame: CGRect = .zero
    }

    private struct ChipFrameKey: PreferenceKey {
        static let defaultValue = CGRect.zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
    }

    /// The chip in the same overlay `ComparisonView` puts it in. The
    /// `GeometryReader` is attached *inside* the 8pt padding so it measures
    /// the pill itself, which is the thing whose width is capped.
    private struct ChipProbe: View {
        let status: String
        let width: CGFloat
        let height: CGFloat
        let report: (CGRect) -> Void

        var body: some View {
            Color.black
                .frame(width: width, height: height)
                .overlay(alignment: .topTrailing) {
                    ComparisonStatusChip(status: status)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ChipFrameKey.self,
                                    value: proxy.frame(in: .named("video"))
                                )
                            }
                        )
                        .padding(8)
                }
                .coordinateSpace(name: "video")
                .onPreferenceChange(ChipFrameKey.self) { report($0) }
        }
    }
}
