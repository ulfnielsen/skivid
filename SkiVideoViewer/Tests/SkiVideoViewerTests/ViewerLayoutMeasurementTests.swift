import AppKit
import SwiftUI
import XCTest
@testable import SkiVideoCore
@testable import SkiVideoViewer

/// Headless layout measurement for the redesigned viewer band, mirroring the
/// `NSHostingView`/`fittingSize` harness in `ComparisonLayoutMeasurementTests`.
///
/// The spec claimed — and explicitly labelled as an *expectation, not a
/// measurement* — that the viewer's bar fits one row at both 834pt and 744pt,
/// for a band of roughly `44pt scrubber + 60pt row = ~104pt` at every iPad
/// width. This file is the measurement. The numbers below were read off this
/// harness, not derived from the comparison screen's 880.5/60/112: that is a
/// different bar, carrying two segmented pickers this one does not have.
///
/// **The zoom control ended that, at the narrower iPad width only.** Adding it
/// moved the ideal width from 557.0pt to 793.0pt, which is above 744pt, so the
/// mini's portrait width now gets the wrapped layout and a 156pt band. That is
/// recorded here as measured rather than engineered around: this file's own
/// rule is to re-measure, not to shrink a control to preserve a number, and
/// whether a 156pt band on a mini in portrait is acceptable is a design call
/// and not a test failure. See
/// `testTheBarIsOneRowAt834ButWrapsAt744AfterTheZoomControl`.
///
/// **These are macOS metrics**, and macOS metrics are not iPadOS metrics — a
/// `.callout` is 13pt here and 16pt there, so the time readout, and with it the
/// ideal width, is wider on an iPad. What used to transfer was the *relation*:
/// the ideal width sat far enough below 744pt that a ~25pt difference in one
/// label could not close it. It no longer does — 793.0pt is 49pt *above* 744pt,
/// and the iPad's wider metrics can only push it further above, so the wrap at
/// 744pt is if anything more certain there than here. 834pt keeps 41pt of
/// headroom, which is the margin a ~25pt label difference now eats into.
/// `ViewerOnIPadUITests.testTheControlBarFitsOneRowInPortrait` closes the loop
/// on the device itself, where the row is observed directly.
@MainActor
final class ViewerControlBarLayoutTests: XCTestCase {
    /// **Measured**, by binary search over this harness to 0.05pt: the bar's
    /// ideal width is 793.0pt. 792pt wraps, 794pt does not. The bar's own
    /// `fittingSize.width`, measured unconstrained, reads 793.0 directly and
    /// agrees.
    ///
    /// Recorded as a constant because it is the number the whole one-row claim
    /// rests on.
    ///
    /// **It was 557.0pt before the zoom control, and the 236.0pt it moved is
    /// accounted for**: `ZoomControl` measures 220.0pt wide inside the
    /// `.frame(maxWidth: 220)` `ViewerControlBar` gives it (224.0pt uncapped,
    /// so the cap is what binds), plus the 16pt of `HStack` spacing that joins
    /// it to the transport. 557.0 + 220 + 16 = 793.0.
    ///
    /// The comparison screen's equivalent is 880.5pt, which is above every iPad
    /// portrait width and is why that bar is always wrapped there. This one is
    /// now 87.5pt narrower rather than 323.5pt narrower, which puts it between
    /// the two portrait widths instead of below both.
    private static let idealWidth: CGFloat = 793.0

    /// **Measured**: one row of 44pt controls plus the bar's 2×8pt vertical
    /// padding.
    private static let oneRowHeight: CGFloat = 60.0

    /// **Measured**: the `ViewThatFits` fallback — two 44pt rows, 8pt of
    /// `VStack` spacing, plus the same 2×8pt padding.
    private static let wrappedHeight: CGFloat = 112.0

    /// **Measured**: `TimelineScrubber`'s explicit `.frame(height: 44)`, with
    /// the 12pt horizontal insets `ContentView.detail` applies. Horizontal
    /// padding only, so it contributes exactly 44pt of height.
    private static let scrubberHeight: CGFloat = 44.0

    override func setUp() {
        super.setUp()
        // NSHostingView needs the shared application to exist before it will
        // lay anything out. `.prohibited` keeps it out of the Dock and off the
        // screen; nothing is presented.
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    /// The ideal width itself, pinned from both sides. Without the lower side
    /// this file could not tell "the bar fits one row at 744pt" from "the bar
    /// has no wrapped layout at all" — deleting the `ViewThatFits` fallback
    /// leaves every width one row tall, and every other assertion here green.
    func testTheBarsIdealWidthIs793Points() {
        let model = makeModel()

        XCTAssertEqual(
            barHeight(model: model, width: Self.idealWidth + 1),
            Self.oneRowHeight,
            accuracy: 0.5,
            """
            1pt above the measured ideal width the bar must be one row; \
            measured \(barHeight(model: model, width: Self.idealWidth + 1))
            """
        )
        XCTAssertEqual(
            barHeight(model: model, width: Self.idealWidth - 1),
            Self.wrappedHeight,
            accuracy: 0.5,
            """
            1pt below the measured ideal width the bar must fall back to the \
            wrapped layout; measured \(barHeight(model: model, width: Self.idealWidth - 1)). \
            A one-row height here means the ViewThatFits fallback is gone, not \
            that the bar got narrower.
            """
        )
        XCTAssertGreaterThan(
            Self.wrappedHeight,
            Self.oneRowHeight,
            "the wrapped layout must be the taller one, or these two constants are swapped"
        )
    }

    /// **The headline number, and it changed.** Both iPad portrait widths,
    /// measured. Before the zoom control this asserted one row at both and
    /// asserted the two equal to each other; the ideal width is now 793.0pt,
    /// which sits between them, so they are no longer the same bar:
    ///
    /// | width | before | now |
    /// | ---------------------- | ------- | -------- |
    /// | 834pt (11-inch portrait) | 60.0pt | 60.0pt |
    /// | 744pt (mini portrait)    | 60.0pt | 112.0pt |
    ///
    /// Written as an inequality on purpose. It is not "744pt must wrap" as a
    /// goal — nothing wants that — but "744pt wraps and 834pt does not" as the
    /// measured state of the shipping bar, so that a later change which
    /// recovers the one-row fit at 744pt fails here loudly and gets the
    /// constant re-measured, rather than passing silently against a stale
    /// expectation.
    ///
    /// Deliberately *not* fixed by shrinking `ZoomControl`'s 220pt cap. This
    /// file's rule is to re-measure rather than adjust a control to preserve a
    /// number, and a slider narrow enough to buy back 49pt is a worse control
    /// than a wrapped bar is a worse layout — but that trade is a design call
    /// for the humans, and this test only records which way it currently sits.
    func testTheBarIsOneRowAt834ButWrapsAt744AfterTheZoomControl() {
        let model = makeModel()

        let atElevenInch = barHeight(model: model, width: 834)
        let atMini = barHeight(model: model, width: 744)

        XCTAssertEqual(
            atElevenInch,
            Self.oneRowHeight,
            accuracy: 0.5,
            "834pt (11-inch portrait) must still be one row; measured \(atElevenInch)"
        )
        XCTAssertEqual(
            atMini,
            Self.wrappedHeight,
            accuracy: 0.5,
            """
            744pt (mini portrait) is below the 793.0pt ideal width and must \
            therefore wrap; measured \(atMini). A one-row height here means the \
            bar got narrower — re-measure `idealWidth` rather than editing this \
            expectation.
            """
        )
    }

    /// The band as a whole — scrubber plus bar — which is the figure the spec
    /// put at "roughly 104pt" and the figure to compare against the ~130pt
    /// control band this redesign deleted.
    ///
    /// `ContentView.detail` stacks the two in a `VStack(spacing: 0)`, so the
    /// band is exactly their sum; measured here as a composite anyway rather
    /// than added up, so that a spacing appearing between them would be caught.
    ///
    /// **The "smaller than the ~130pt band it replaced" claim now holds at
    /// 834pt only.** Measured: 104.0pt at 834pt, 156.0pt at 744pt. The 744pt
    /// figure is 26pt *worse* than the control band the redesign deleted, and
    /// it is the direct cost of the zoom control pushing the ideal width past
    /// the mini's portrait width. Recorded, not worked around — see
    /// `testTheBarIsOneRowAt834ButWrapsAt744AfterTheZoomControl`.
    func testTheWholeBandIs104PointsAt834AndGrowsTo156AtTheMini() {
        let model = makeModel()

        let atElevenInch = bandHeight(model: model, width: 834)
        XCTAssertEqual(
            atElevenInch,
            Self.scrubberHeight + Self.oneRowHeight,
            accuracy: 0.5,
            "the scrubber-plus-bar band must measure 104pt at 834pt; measured \(atElevenInch)"
        )
        XCTAssertLessThan(
            atElevenInch,
            130,
            """
            at 834pt the band must still be smaller than the ~130pt control \
            band it replaced, or the redesign costs height rather than saving \
            it at every iPad width; measured \(atElevenInch)
            """
        )

        let atMini = bandHeight(model: model, width: 744)
        XCTAssertEqual(
            atMini,
            Self.scrubberHeight + Self.wrappedHeight,
            accuracy: 0.5,
            """
            at 744pt the wrapped bar makes the band 156pt; measured \(atMini). \
            This is the measured cost of the zoom control, not a target — if it \
            drops back to 104pt the bar has stopped wrapping and `idealWidth` \
            needs re-measuring.
            """
        )
    }

    /// A model with nothing loaded is enough: every control in the bar is
    /// present-but-disabled without a clip, and `Timecode.string(0)` is
    /// `00:00.0` — the same character count, in the same monospaced-digit font,
    /// as every clip this app plays under 100 minutes. Nothing in the bar's
    /// width depends on playback state.
    private func makeModel() -> ViewerModel {
        ViewerModel(
            input: AppKitInputSource(),
            folderPicker: AppKitFolderPicker(),
            oauthPresenter: StubOAuthPresenter()
        )
    }

    private func barHeight(model: ViewerModel, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: ViewerControlBar(model: model).frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// The scrubber and the bar composed exactly as `ContentView.detail`
    /// composes them: a zero-spacing `VStack`, the scrubber inset 12pt
    /// horizontally, the bar carrying its own padding.
    private func bandHeight(model: ViewerModel, width: CGFloat) -> CGFloat {
        let host = NSHostingView(
            rootView: VStack(spacing: 0) {
                TimelineScrubber(time: model.currentTime, duration: model.duration, onScrub: { _ in })
                    .padding(.horizontal, 12)
                ViewerControlBar(model: model)
            }
            .frame(width: width)
        )
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
}
