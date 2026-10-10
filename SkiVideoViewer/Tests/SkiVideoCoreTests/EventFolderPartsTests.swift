import Foundation
import SkiVideoCore
import XCTest

/// The rename sheet pre-fills its date and title from the current event name.
/// What matters is that the pre-fill joins back into the same name, so
/// opening the sheet and changing nothing proposes no rename.
final class EventFolderPartsTests: XCTestCase {
    private func day(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)!
    }

    func testDatedNameSplitsIntoDateAndSpacedTitle() {
        let parts = SortingLibrary.eventFolderParts("2026-08-08_Wittenburg-GS")
        XCTAssertEqual(parts.date, day("2026-08-08"))
        XCTAssertEqual(parts.title, "Wittenburg GS")
    }

    func testSortedNamesRoundTripUnchanged() throws {
        for name in ["2026-08-08_Wittenburg-GS", "2026-01-10_Zürs", "2026-02-14_Hoch-Ybrig-2"] {
            let parts = SortingLibrary.eventFolderParts(name)
            let date = try XCTUnwrap(parts.date, name)
            XCTAssertEqual(try SortingLibrary.eventFolder(date: date, title: parts.title), name)
        }
    }

    func testOnlyTheFirstUnderscoreSeparatesTheDate() {
        let parts = SortingLibrary.eventFolderParts("2026-08-08_Neuss_Halle")
        XCTAssertEqual(parts.date, day("2026-08-08"))
        XCTAssertEqual(parts.title, "Neuss_Halle")
    }

    func testDateWithoutTitleLeavesTitleEmpty() {
        let parts = SortingLibrary.eventFolderParts("2026-08-08")
        XCTAssertEqual(parts.date, day("2026-08-08"))
        XCTAssertEqual(parts.title, "")
    }

    func testUndatedNameIsAllTitle() {
        let parts = SortingLibrary.eventFolderParts("Wittenburg-GS")
        XCTAssertNil(parts.date)
        XCTAssertEqual(parts.title, "Wittenburg-GS")
    }

    func testImpossibleDateIsNotADate() {
        let parts = SortingLibrary.eventFolderParts("2026-13-45_Wittenburg")
        XCTAssertNil(parts.date)
        XCTAssertEqual(parts.title, "2026-13-45_Wittenburg")
    }
}
