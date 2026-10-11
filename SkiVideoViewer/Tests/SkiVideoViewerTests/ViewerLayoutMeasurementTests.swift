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
/// **These are macOS metrics**, and macOS metrics are not iPadOS metrics — a
/// `.callout` is 13pt here and 16pt there, so the time readout, and with it the
/// ideal width, is wider on an iPad. What transfers is the *relation*: the ideal
/// width is far enough below 744pt that a ~25pt difference in one label cannot
/// close it. `ViewerOnIPadUITests.testTheControlBarFitsOneRowInPortrait` closes
/// the loop on the device itself, where the row is observed directly.
@MainActor
final class ViewerControlBarLayoutTests: XCTestCase {
    /// **Measured**, by binary search over this harness to 0.05pt: the bar's
    /// ideal width is 665.0pt (665.04). 664pt wraps, 666pt does not. It was
    /// 557.0pt before the Draw and Show drawings buttons: two 44pt buttons, a
    /// 4pt gap between them and one more 16pt row spacing, 108pt in all. That
    /// leaves 79pt below the 744pt iPad mini portrait width on macOS metrics.
    ///
    /// Recorded as a constant because it is the number the whole one-row claim
    /// rests on. The comparison screen's equivalent is 880.5pt, which is
    /// *above* every iPad portrait width and is why that bar is always wrapped
    /// there; this one is 323.5pt narrower, which is roughly the two segmented
    /// pickers the viewer does not carry.
    private static let idealWidth: CGFloat = 665.0

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
    func testTheBarsIdealWidthIs665Points() {
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

    /// **The headline number.** Both iPad portrait widths, measured, and
    /// asserted equal to each other so the band cannot change height between an
    /// 11-inch and a mini.
    ///
    /// The comparison screen's bar wraps at both of these; this one does not,
    /// and the whole redesign's "~104pt band" claim depends on that staying
    /// true.
    func testTheBarIsOneRowAtBothIPadPortraitWidths() {
        let model = makeModel()

        let atElevenInch = barHeight(model: model, width: 834)
        let atMini = barHeight(model: model, width: 744)

        XCTAssertEqual(
            atElevenInch,
            Self.oneRowHeight,
            accuracy: 0.5,
            "834pt (11-inch portrait) must be one row; measured \(atElevenInch)"
        )
        XCTAssertEqual(
            atMini,
            Self.oneRowHeight,
            accuracy: 0.5,
            "744pt (mini portrait) must be one row; measured \(atMini)"
        )
        XCTAssertEqual(
            atElevenInch,
            atMini,
            accuracy: 0.5,
            """
            the band must not change height between iPad widths: \
            \(atElevenInch) at 834pt vs \(atMini) at 744pt
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
    func testTheWholeBandIs104PointsAtBothIPadPortraitWidths() {
        let model = makeModel()

        for width in [834.0, 744.0] as [CGFloat] {
            let band = bandHeight(model: model, width: width)
            XCTAssertEqual(
                band,
                Self.scrubberHeight + Self.oneRowHeight,
                accuracy: 0.5,
                "the scrubber-plus-bar band must measure 104pt at \(width)pt; measured \(band)"
            )
            XCTAssertLessThan(
                band,
                130,
                """
                the band must be smaller than the ~130pt control band it \
                replaced, or the redesign cost height rather than saving it; \
                measured \(band) at \(width)pt
                """
            )
        }
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
