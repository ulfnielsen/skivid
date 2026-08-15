import XCTest

/// Drives the one screen a club that is not rg-albis.ch has to get through
/// before it can use the app at all — entering its own Google OAuth client id.
///
/// An XCUITest rather than a macOS unit test for the reason the sibling suites
/// document: a `swift test` host process on macOS never registers as an
/// accessible application, so nothing there can read a label off a live
/// control. And `GoogleDriveSheet` lives in the app target, which no SwiftPM
/// test target compiles for iOS at all.
///
/// This suite deliberately stops at the field. Everything past **Save** needs
/// Google, a browser, and a human at a keyboard;
/// `ClubOAuthClientTests` covers what happens to the value once it is in.
///
///     export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
///     xcodebuild -scheme SkiVideoViewer-iPad \
///       -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
///       -only-testing:SkiVideoViewer-iPadUITests/ClubClientSetupUITests test
final class ClubClientSetupUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testTheSheetOffersAClubClientFieldAndNamesTheBundleIDToRegister() {
        let app = XCUIApplication()
        app.launch()

        dismissTheDocumentPicker(in: app)

        let openLibrary = app.buttons["Open Club Library…"]
        XCTAssertTrue(
            openLibrary.waitForExistence(timeout: 10),
            "no Open Club Library button; toolbar was \(app.toolbars.buttons.allElementsBoundByIndex.map(\.label))"
        )
        openLibrary.tap()

        // The DisclosureGroup's label. Collapsed on launch here, because the
        // iPad build has a built-in client and so is not in the
        // nothing-configured state that expands it.
        let disclosure = app.buttons["Use your club's own Google account"]
        XCTAssertTrue(
            disclosure.waitForExistence(timeout: 5),
            "no club-client disclosure in the sheet; buttons were \(app.buttons.allElementsBoundByIndex.map(\.label))"
        )
        add(screenshot(of: app, named: "01-sheet-collapsed"))

        disclosure.tap()

        let field = app.textFields.firstMatch
        XCTAssertTrue(
            field.waitForExistence(timeout: 5),
            "expanding the disclosure revealed no text field to paste a client id into"
        )
        add(screenshot(of: app, named: "02-sheet-expanded"))

        // The bundle id a club must type into Google's console. Wrong here and
        // every club-supplied sign-in fails with redirect_uri_mismatch, so the
        // string being on screen at all is the thing worth pinning.
        XCTAssertTrue(
            app.staticTexts.allElementsBoundByIndex.contains { $0.label.contains("ch.ski.video-viewer") },
            "the sheet never names the bundle id to register; a club cannot complete setup "
                + "from what it can see"
        )
    }

    /// With no library loaded the app opens `UIDocumentPickerViewController`
    /// straight away, and it covers the toolbar. Dismissed by its Cancel
    /// button, whose label the picker owns rather than this app.
    private func dismissTheDocumentPicker(in app: XCUIApplication) {
        for label in ["Cancel", "Done", "Close"] {
            let button = app.buttons[label]
            if button.waitForExistence(timeout: label == "Cancel" ? 10 : 1), button.isHittable {
                button.tap()
                return
            }
        }
    }

    private func screenshot(of app: XCUIApplication, named name: String) -> XCTAttachment {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}
