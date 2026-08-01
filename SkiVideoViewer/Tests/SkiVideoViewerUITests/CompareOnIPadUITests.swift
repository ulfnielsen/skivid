import XCTest

/// The only automated check that the iPad toolbar's Compare button actually
/// opens the comparison screen. `simctl` has no input injection, so nothing
/// else in this repo can tap anything; the other iPad gate, `ipad-smoke.sh`,
/// stops at "the process is alive, here is a screenshot".
///
/// Runs as part of the `SkiVideoViewer-iPad` scheme:
///
///     export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
///     xcodebuild -scheme SkiVideoViewer-iPad \
///       -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' test
final class CompareOnIPadUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        // Orientation is simulator-wide and outlives the process, so a test
        // that rotates would leave every later test in portrait.
        XCUIDevice.shared.orientation = .landscapeLeft
        super.tearDown()
    }

    /// Tap Compare, and assert the comparison screen is on screen. The three
    /// things asserted are the three the screen is made of: the
    /// side-by-side/overlay picker, two panes, and the one control bar that
    /// replaced the three transports. A screenshot is attached because element
    /// existence says nothing about layout, and this screen was designed for a
    /// 1000pt macOS window.
    func testTappingCompareOpensTheComparisonScreen() {
        let app = launchPastTheFolderPicker()

        let compare = app.buttons["Compare Videos…"]
        XCTAssertTrue(
            compare.waitForExistence(timeout: 30),
            "the iPad toolbar must offer Compare"
        )
        compare.tap()

        // The layout picker's two segments: the clearest proof it is the
        // comparison screen specifically that came up.
        XCTAssertTrue(
            app.buttons["Side-by-side"].waitForExistence(timeout: 30),
            "the comparison screen's layout picker must be on screen"
        )
        XCTAssertTrue(app.buttons["Overlay"].exists)

        // Two panes. Neither has a clip yet, so each shows its own centred
        // Choose Clip control where the deleted header row used to be. Asserted
        // per side rather than as a count of two: with no clips loaded the
        // panes are otherwise indistinguishable, so a count passes just as
        // happily when both panes are wired to the same side.
        XCTAssertTrue(app.buttons["Choose left clip"].exists)
        XCTAssertTrue(app.buttons["Choose right clip"].exists)

        // The one control bar at the foot of the screen: transport, anchor,
        // and — because nothing is synced yet — a target selector without Both.
        XCTAssertTrue(app.buttons["Play or pause"].exists)
        XCTAssertTrue(app.buttons["Set sync points"].exists)
        XCTAssertTrue(app.buttons["Close comparison"].exists)

        // `model.status` is the only feedback a nudge produces, and the rows
        // that used to display it are gone — it now floats over the video.
        // Matched by prefix rather than by the exact sentence so this pins
        // *that the status is displayed at all*, which is the thing that can
        // silently disappear, without pinning the model's wording.
        XCTAssertTrue(
            app.staticTexts
                .matching(NSPredicate(format: "label BEGINSWITH 'Status: '"))
                .firstMatch
                .waitForExistence(timeout: 5),
            "the status text must survive the deletion of the rows it lived in"
        )

        attachScreenshot(named: "comparison-side-by-side")

        app.buttons["Overlay"].tap()
        XCTAssertTrue(
            app.buttons["Difference"].waitForExistence(timeout: 30),
            "the overlay layout must offer the blend/difference picker"
        )
        attachScreenshot(named: "comparison-overlay")
    }

    /// The layout risk the phase-5 plan flagged: `ComparisonView` was written
    /// for a 1000pt-wide macOS window, and an 11-inch iPad in portrait is
    /// 834pt. Every control must still be on screen and hittable there —
    /// `exists` alone would pass on a control pushed off the edge.
    func testTheComparisonScreenIsUsableInPortrait() {
        let app = launchPastTheFolderPicker()
        XCUIDevice.shared.orientation = .portrait

        let compare = app.buttons["Compare Videos…"]
        XCTAssertTrue(compare.waitForExistence(timeout: 30))
        compare.tap()

        XCTAssertTrue(app.buttons["Side-by-side"].waitForExistence(timeout: 30))
        attachScreenshot(named: "comparison-portrait-side-by-side")

        let window = app.windows.firstMatch.frame
        // 834pt is below the bar's measured 880.5pt wrap threshold, so this is
        // also the check that nothing is clipped once it has wrapped to two
        // rows — which is the state an 11-inch portrait iPad is always in.
        for label in [
            "Side-by-side", "Overlay", "Left", "Right", "Close comparison",
            "Set sync points", "Play or pause", "Back 5 seconds",
            "Forward 5 seconds", "Play at quarter speed",
        ] {
            let button = app.buttons[label]
            XCTAssertTrue(button.exists, "\(label) must be on the portrait screen")
            XCTAssertTrue(button.isHittable, "\(label) must be reachable in portrait")
            XCTAssertTrue(
                window.contains(button.frame),
                "\(label) is clipped in portrait: \(button.frame) outside \(window)"
            )
        }

        app.buttons["Overlay"].tap()
        XCTAssertTrue(app.buttons["Difference"].waitForExistence(timeout: 30))
        attachScreenshot(named: "comparison-portrait-overlay")
        for label in ["Blend", "Difference"] {
            let button = app.buttons[label]
            XCTAssertTrue(button.isHittable, "\(label) must be reachable in portrait")
            XCTAssertTrue(
                window.contains(button.frame),
                "\(label) is clipped in portrait: \(button.frame) outside \(window)"
            )
        }
    }

    /// Sort & Resize drives `FFmpegMediaPipeline`, which needs `Process` and so
    /// cannot exist on iOS. Its button must be absent, not merely disabled — a
    /// visible control that does nothing is the regression this guards, and it
    /// is why the seam carries one flag per screen.
    func testSortIsNotOfferedOnIPad() {
        let app = launchPastTheFolderPicker()

        XCTAssertTrue(
            app.buttons["Compare Videos…"].waitForExistence(timeout: 30),
            "wait for the toolbar before asserting something is absent from it"
        )
        XCTAssertFalse(
            app.buttons["Sort & Resize…"].exists,
            "Sort cannot work on iPad, so it must not appear as a dead button"
        )

        attachScreenshot(named: "toolbar")
    }

    /// Closing must return to the viewer, or the cover is a trap: iPad has no
    /// window chrome to dismiss it with, and phase 4 still owns keyboard input.
    func testClosingTheComparisonScreenReturnsToTheViewer() {
        let app = launchPastTheFolderPicker()

        let compare = app.buttons["Compare Videos…"]
        XCTAssertTrue(compare.waitForExistence(timeout: 30))
        compare.tap()

        let close = app.buttons["Close comparison"]
        XCTAssertTrue(close.waitForExistence(timeout: 30))
        close.tap()

        XCTAssertTrue(
            compare.waitForExistence(timeout: 30),
            "dismissing the cover must reveal the viewer's toolbar again"
        )
    }

    /// `ViewerModel.start(initialDirectory: nil)` opens the folder picker from
    /// `onAppear`, so every launch begins with a `UIDocumentPickerViewController`
    /// on screen. Its content lives in another process and never reaches this
    /// app's accessibility tree, but its dismiss region does — and until it is
    /// gone that region swallows every tap, so a toolbar button can be found,
    /// reported hittable, and tapped with no effect whatsoever. That is exactly
    /// what happened the first time these tests were written.
    private func launchPastTheFolderPicker() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()

        let dismissRegion = app.otherElements["PopoverDismissRegion"]
        guard dismissRegion.waitForExistence(timeout: 30) else {
            XCTFail("expected the launch folder picker; did ViewerModel.start change?")
            return app
        }
        // Tap near the bottom edge — outside the centred form sheet, inside the
        // dismiss region.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).tap()

        let gone = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: dismissRegion
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [gone], timeout: 30),
            .completed,
            "the folder picker must be dismissed before anything else is tappable"
        )
        return app
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
