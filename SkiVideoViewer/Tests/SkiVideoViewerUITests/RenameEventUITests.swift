import XCTest

/// Rename an event against the seam's in-memory Drive, then hit the merge
/// question and back out of it.
///
/// The seam (`-SkiUITestPhotosToDrive`) opens a fake Drive laid out
/// event → athlete with two events on 2026-01-10: "Seed Camp" and
/// "Spring-Camp". Everything between the long-press and the sidebar — the
/// sheet, the planner, the runner, the reload — is the app's own code; only
/// the Drive is fake, and nothing here can reach a real one.
///
/// Phone only, like `PhotosToDriveUITests`: the seam's flow was built and
/// measured there. Every wait is bounded.
///
///     export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
///     xcodebuild -scheme SkiVideoViewer-iPad \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///       -only-testing:SkiVideoViewer-iPadUITests/RenameEventUITests test
final class RenameEventUITests: XCTestCase {
    private let seedEvent = "2026-01-10_Seed Camp"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testRenamingAnEventMovesItInTheSidebar() throws {
        let app = try launch()
        openRename(of: seedEvent, in: app)
        retitle("Autumn Camp", in: app)
        add(screenshot(of: app, named: "01-rename-sheet"))
        app.buttons["rename.submit"].tap()

        XCTAssertTrue(app.staticTexts["rename.summary"].waitForExistence(timeout: 30),
                      "the rename must finish; texts were \(labels(app.staticTexts))")
        app.buttons["Done"].tap()

        let renamed = header("2026-01-10_Autumn-Camp", in: app)
        XCTAssertTrue(renamed.waitForExistence(timeout: 30),
                      "the sidebar must show the new name; buttons were \(labels(app.buttons))")
        XCTAssertFalse(header(seedEvent, in: app).exists, "the old name must be gone")
        XCTAssertTrue(app.buttons["sidebar.athlete.Seed Athlete"].exists,
                      "the athlete must have moved with the event")
        add(screenshot(of: app, named: "03-sidebar-after-rename"))

        // The header became a `Menu` on iOS so its long-press could offer the
        // rename; a plain tap must still fold the section.
        renamed.tap()
        let athlete = app.buttons["sidebar.athlete.Seed Athlete"]
        let folded = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: athlete)
        XCTAssertEqual(XCTWaiter().wait(for: [folded], timeout: 10), .completed,
                       "a tap on the header must still fold its section")
    }

    /// The spec: a name that already exists asks first, and backing out
    /// changes nothing and keeps what was typed.
    func testAnExistingNameAsksBeforeMerging() throws {
        let app = try launch()
        openRename(of: seedEvent, in: app)
        retitle("Spring Camp", in: app)
        app.buttons["rename.submit"].tap()

        let otherName = dialogButton("rename.otherName", label: "Choose Another Name", in: app)
        XCTAssertTrue(otherName.waitForExistence(timeout: 30),
                      "an existing name must ask before merging; buttons were \(labels(app.buttons))")
        XCTAssertTrue(dialogButton("rename.merge", label: "Merge", in: app).exists)
        add(screenshot(of: app, named: "02-merge-question"))
        otherName.tap()

        let title = app.textFields["rename.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.value as? String, "Spring Camp", "the typed name is kept")
        XCTAssertTrue(app.buttons["rename.submit"].exists, "the sheet stays open to choose again")

        // Nothing moved: close the sheet and both events are as seeded.
        app.buttons["Cancel"].tap()
        XCTAssertTrue(header(seedEvent, in: app).waitForExistence(timeout: 10), "nothing moved")
        XCTAssertTrue(header("2026-01-10_Spring-Camp", in: app).exists)
        XCTAssertTrue(app.buttons["sidebar.athlete.Seed Athlete"].exists)
        XCTAssertTrue(app.buttons["sidebar.athlete.Other Athlete"].exists)
    }

    private func launch() throws -> XCUIApplication {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .phone,
            "the seam's flow is the phone's; see PhotosToDriveUITests"
        )
        let app = XCUIApplication()
        app.launchArguments = ["-SkiUITestPhotosToDrive"]
        // The open selects a clip and fetches it; the seam "downloads" it by
        // copying this fixture.
        if let fixture = Bundle(for: Self.self).url(forResource: "supported-420-8bit", withExtension: "mp4") {
            app.launchEnvironment = ["SKI_UITEST_FIXTURE_MOVIE": fixture.path]
        }
        app.launch()
        return app
    }

    private func header(_ event: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons["sidebar.event.\(event)"]
    }

    /// The identifier does reach XCUITest (measured), but an action sheet
    /// shows its buttons twice in the hierarchy, so a plain subscript finds
    /// "multiple matching elements" — hence `firstMatch`. The label is the
    /// fallback in case a later OS drops the identifier.
    private func dialogButton(_ identifier: String, label: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", identifier, label)).firstMatch
    }

    private func openRename(of event: String, in app: XCUIApplication) {
        let header = header(event, in: app)
        XCTAssertTrue(header.waitForExistence(timeout: 60),
                      "the fake Drive must open; buttons were \(labels(app.buttons))")
        header.press(forDuration: 1.0)
        let item = app.buttons["Rename Event…"]
        XCTAssertTrue(item.waitForExistence(timeout: 10),
                      "the header's menu must offer Rename Event…; buttons were \(labels(app.buttons))")
        item.tap()
    }

    /// Clears the title by deleting what is there — no reliance on an edit
    /// menu — and types the new one.
    private func retitle(_ text: String, in app: XCUIApplication) {
        let title = app.textFields["rename.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the rename sheet must open")
        // At the far end, so the cursor lands after the text and the deletes
        // below take all of it.
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let current = title.value as? String ?? ""
        title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
        XCTAssertEqual(title.value as? String, text)
    }

    private func labels(_ query: XCUIElementQuery) -> [String] {
        query.allElementsBoundByIndex.prefix(30).map { "\($0.identifier)|\($0.label)" }
    }

    private func screenshot(of app: XCUIApplication, named name: String) -> XCTAttachment {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}
