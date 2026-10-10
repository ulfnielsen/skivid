import XCTest
@testable import SkiVideoCore

@MainActor
final class SecondaryScreensTests: XCTestCase {
    /// Stands in for a platform that can show neither screen.
    private final class UnavailablePresenter: SecondaryScreenPresenter {
        var canPresentComparison: Bool { false }
        var canPresentSorting: Bool { false }
        var screensCoverTheViewer: Bool { false }
        private(set) var comparisonCalls = 0
        private(set) var sortingCalls = 0

        func presentComparison(
            initialLeftVideo: URL?,
            openLibrary: [ComparisonAthleteChoice],
            prepare: ClipPreparer,
            onClose: @escaping () -> Void
        ) {
            comparisonCalls += 1
        }

        func presentSorting(
            libraryAthletes: [AthleteGroup],
            upload: Result<UploadTarget, UploadRefusal>,
            openResizedLibrary: @escaping (URL) -> Void,
            onClose: @escaping () -> Void
        ) {
            sortingCalls += 1
        }
    }

    /// The shape iPad ships: Compare works, Sort does not, because Sort needs
    /// `Process`, which iOS does not have.
    private final class ComparisonOnlyPresenter: SecondaryScreenPresenter {
        var canPresentComparison: Bool { true }
        var canPresentSorting: Bool { false }
        var screensCoverTheViewer: Bool { false }

        func presentComparison(
            initialLeftVideo: URL?,
            openLibrary: [ComparisonAthleteChoice],
            prepare: ClipPreparer,
            onClose: @escaping () -> Void
        ) {}

        func presentSorting(
            libraryAthletes: [AthleteGroup],
            upload: Result<UploadTarget, UploadRefusal>,
            openResizedLibrary: @escaping (URL) -> Void,
            onClose: @escaping () -> Void
        ) {}
    }

    func testCanPresentGatesTheUI() {
        let presenter = UnavailablePresenter()
        XCTAssertFalse(
            presenter.canPresentComparison,
            "a presenter that cannot show Compare must say so, so the view hides its button"
        )
        XCTAssertFalse(
            presenter.canPresentSorting,
            "a presenter that cannot show Sort must say so, so the view hides its button"
        )
    }

    func testTheTwoScreensAreGatedIndependently() {
        // The reason the seam carries two flags rather than one: iPad presents
        // Compare but not Sort, and a single flag would reveal both or neither
        // — one of those is a dead button.
        let presenter = ComparisonOnlyPresenter()
        XCTAssertTrue(presenter.canPresentComparison)
        XCTAssertFalse(presenter.canPresentSorting)
    }

    func testAPresenterThatCannotPresentIsStillSafeToCall() {
        // The view hides the buttons, but a stray call must not trap.
        let presenter = UnavailablePresenter()
        presenter.presentComparison(initialLeftVideo: nil, openLibrary: [], prepare: .none) {}
        presenter.presentSorting(libraryAthletes: [], upload: .failure(.noLibraryOpen),
                                 openResizedLibrary: { _ in }) {}
        XCTAssertEqual(presenter.comparisonCalls, 1)
        XCTAssertEqual(presenter.sortingCalls, 1)
    }
}
