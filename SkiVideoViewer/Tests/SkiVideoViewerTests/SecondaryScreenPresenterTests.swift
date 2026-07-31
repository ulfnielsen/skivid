import SkiVideoCore
import XCTest
@testable import SkiVideoViewer

@MainActor
final class SecondaryScreenPresenterTests: XCTestCase {
    func testMacPresenterReportsItCanPresent() {
        XCTAssertTrue(
            MacSecondaryScreenPresenter().canPresent,
            "macOS has real windows, so ContentView must show the buttons"
        )
    }

    func testMacPresenterConformsToTheSeam() {
        // Compile-time proof the concrete type satisfies the protocol the
        // shared view depends on.
        let presenter: any SecondaryScreenPresenter = MacSecondaryScreenPresenter()
        XCTAssertTrue(presenter.canPresent)
    }
}
