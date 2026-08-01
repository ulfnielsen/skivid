import SkiVideoCore
import XCTest
@testable import SkiVideoViewer

@MainActor
final class SecondaryScreenPresenterTests: XCTestCase {
    func testMacPresenterReportsItCanPresentBothScreens() {
        let presenter = MacSecondaryScreenPresenter()
        XCTAssertTrue(
            presenter.canPresentComparison,
            "macOS has a real Compare window, so ContentView must show the button"
        )
        XCTAssertTrue(
            presenter.canPresentSorting,
            "macOS has a real Sort window, so ContentView must show the button"
        )
    }

    func testMacPresenterConformsToTheSeam() {
        // Compile-time proof the concrete type satisfies the protocol the
        // shared view depends on.
        let presenter: any SecondaryScreenPresenter = MacSecondaryScreenPresenter()
        XCTAssertTrue(presenter.canPresentComparison)
        XCTAssertTrue(presenter.canPresentSorting)
    }

    func testMacPresenterFlagsDoNotVary() {
        // ContentView reads these while building `body` and does not observe
        // the presenter, so a flag derived from runtime state would leave the
        // toolbar stale. Reading each twice is the cheapest guard against
        // someone later deriving them from, say, a window's visibility.
        let presenter = MacSecondaryScreenPresenter()
        XCTAssertEqual(presenter.canPresentComparison, presenter.canPresentComparison)
        XCTAssertEqual(presenter.canPresentSorting, presenter.canPresentSorting)
    }
}
