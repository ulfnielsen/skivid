import XCTest
@testable import SkiVideoViewer

/// `ViewerPane.videoArea(in:picture:)`: the picture sits at the top of the
/// pane, so the spare height is one band below it rather than one above and
/// one below.
final class ViewerPaneVideoAreaTests: XCTestCase {
    /// A 16:9 clip in a pane taller than it needs: the area is exactly the
    /// picture's height at the pane's width, so nothing is left above it.
    func testALetterboxedPictureTakesOnlyItsOwnHeight() {
        let area = ViewerPane.videoArea(in: CGSize(width: 1280, height: 900),
                                        picture: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(area, CGSize(width: 1280, height: 720))
    }

    /// Bars at the sides instead: there is no spare height to move.
    func testAPillarboxedPictureKeepsTheWholePane() {
        let pane = CGSize(width: 1600, height: 600)
        XCTAssertEqual(ViewerPane.videoArea(in: pane, picture: CGSize(width: 1920, height: 1080)), pane)
    }

    /// Before the clip reports a size there is nothing to fit.
    func testAnUnknownPictureSizeKeepsTheWholePane() {
        let pane = CGSize(width: 800, height: 600)
        XCTAssertEqual(ViewerPane.videoArea(in: pane, picture: .zero), pane)
    }
}
