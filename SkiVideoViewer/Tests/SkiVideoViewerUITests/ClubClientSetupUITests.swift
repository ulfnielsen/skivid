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

        // No document picker to dismiss any more — launching lands on the
        // libraries list. The button that opens this sheet was renamed with the
        // same change: "Open Club Library…" became "Connect Google Drive…",
        // because connecting is what it does and opening one already connected
        // is a row on that list.
        //
        // By identifier rather than label where the list offers the action too,
        // so this test does not have to know which of the two it found.
        let connect = app.buttons["libraries.connectDrive"]
        XCTAssertTrue(
            connect.waitForExistence(timeout: 10),
            "no Connect Google Drive button; buttons were \(app.buttons.allElementsBoundByIndex.map(\.label))"
        )
        connect.tap()

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
            app.staticTexts.allElementsBoundByIndex.contains { $0.label.contains("dk.dyregod.video-viewer") },
            "the sheet never names the bundle id to register; a club cannot complete setup "
                + "from what it can see"
        )
    }

    private func screenshot(of app: XCUIApplication, named name: String) -> XCTAttachment {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}
