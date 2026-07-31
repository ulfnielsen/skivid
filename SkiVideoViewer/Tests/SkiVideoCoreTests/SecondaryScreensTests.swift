import XCTest
@testable import SkiVideoCore

@MainActor
final class SecondaryScreensTests: XCTestCase {
    /// Stands in for the iPad's phase-3 presenter, which cannot show anything yet.
    private final class UnavailablePresenter: SecondaryScreenPresenter {
        var canPresent: Bool { false }
        private(set) var comparisonCalls = 0
        private(set) var sortingCalls = 0

        func presentComparison(
            initialLeftVideo: URL?,
            openLibrary: [ComparisonAthleteChoice],
            onClose: @escaping () -> Void
        ) {
            comparisonCalls += 1
        }

        func presentSorting(
            openResizedLibrary: @escaping (URL) -> Void,
            onClose: @escaping () -> Void
        ) {
            sortingCalls += 1
        }
    }

    func testCanPresentGatesTheUI() {
        let presenter = UnavailablePresenter()
        XCTAssertFalse(
            presenter.canPresent,
            "a presenter that cannot show screens must say so, so the view hides its buttons"
        )
    }

    func testAPresenterThatCannotPresentIsStillSafeToCall() {
        // The view hides the buttons, but a stray call must not trap.
        let presenter = UnavailablePresenter()
        presenter.presentComparison(initialLeftVideo: nil, openLibrary: []) {}
        presenter.presentSorting(openResizedLibrary: { _ in }) {}
        XCTAssertEqual(presenter.comparisonCalls, 1)
        XCTAssertEqual(presenter.sortingCalls, 1)
    }
}
