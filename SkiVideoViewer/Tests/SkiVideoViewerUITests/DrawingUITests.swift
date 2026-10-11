import XCTest

/// Drawing on a paused frame, on the phone. The screenshots are attached to
/// the result bundle so the line's position can be judged by eye.
final class DrawingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // walkToAClip() and openTheFixtureFolder(in:) — copied from
    // PhoneNavigationUITests.swift.

    @discardableResult
    private func walkToAClip() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()

        // 1. The root screen is the libraries list. This is the assertion the
        //    old build could not have passed: it landed on "Athletes".
        let addFolder = app.buttons["libraries.addFolder"]
        XCTAssertTrue(
            addFolder.waitForExistence(timeout: 60),
            "a phone must land on the libraries list; buttons were \(app.buttons.allElementsBoundByIndex.map(\.label))"
        )
        addFolder.tap()

        // 2. Opening a folder pushes the athletes.
        openTheFixtureFolder(in: app)

        let athlete = app.buttons["sidebar.athlete.Snow"]
        XCTAssertTrue(
            athlete.waitForExistence(timeout: 30),
            "opening a library must push the athlete list on a phone"
        )

        // 3. And an athlete pushes the clip. A tagged row would look like this
        //    and do nothing, which is the failure this step is here to catch.
        athlete.tap()

        let caption = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Clip 1 of 3'")
        ).firstMatch
        XCTAssertTrue(
            caption.waitForExistence(timeout: 30),
            "tapping an athlete must push the viewer; texts were \(app.staticTexts.allElementsBoundByIndex.prefix(12).map(\.label))"
        )
        return app
    }

    /// The document picker, from the tap on "Add Folder…" to the open folder.
    /// The picker's own identifiers, which name the device rather than the
    /// idiom — "On My iPhone" here where the iPad suite says "On My iPad".
    /// The document picker, from the tap on "Add Folder…" to the opened folder.
    ///
    /// A phone's picker is not the iPad's. Dumped from `app.debugDescription`
    /// rather than guessed, it opens *inside* the app's own container —
    /// `DOC.browsingRoot … Title: On My iPhone`, the fixture folder already on
    /// screen — where the iPad opens on a sidebar of locations. It also
    /// remembers where it was last, so the walk in is attempted only when the
    /// folder is not already there rather than assumed either way.
    private func openTheFixtureFolder(in app: XCUIApplication) {
        let snow = app.cells["Snow, Folder"]
        if !snow.waitForExistence(timeout: 20) {
            let browse = app.buttons["Browse"]
            if browse.waitForExistence(timeout: 10) { browse.tap() }

            let location = app.cells["DOC.sidebar.item.On My iPhone"]
            if location.waitForExistence(timeout: 10) { location.tap() }

            let container = app.cells["SkiVideoViewer, Container"]
            if container.waitForExistence(timeout: 10) { container.tap() }
        }

        XCTAssertTrue(
            snow.waitForExistence(timeout: 20),
            """
            the fixture folder Documents/Snow must exist in the app container — \
            see this file's header for the ffmpeg lines that build it.
            """
        )
        snow.tap()

        let accept = app.buttons["Open"]
        XCTAssertTrue(accept.waitForExistence(timeout: 10), "the picker must offer its accept button")
        accept.tap()
    }

    private func enterDrawing(_ app: XCUIApplication) -> XCUIElement {
        let draw = app.buttons["viewer.draw"]
        XCTAssertTrue(draw.waitForExistence(timeout: 20))
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: draw)
        waitForExpectations(timeout: 20)
        draw.tap()
        let overlay = app.otherElements["drawing.overlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 10))
        return overlay
    }

    private func drawLine(on overlay: XCUIElement, app: XCUIApplication) {
        app.buttons["drawing.tool.line"].tap()
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testALineStretchesAcrossStepsAndSurvivesReopening() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "this walk is the phone's")
        let app = walkToAClip()
        let overlay = enterDrawing(app)
        drawLine(on: overlay, app: app)
        XCTAssertEqual(overlay.value as? String, "1 on this frame")
        screenshot("01-line-drawn")

        for _ in 0..<3 { app.buttons["drawing.stepForward"].tap() }
        XCTAssertEqual(overlay.value as? String, "1 on this frame", "stepping must carry the line along")
        screenshot("02-after-three-steps")

        app.buttons["drawing.done"].tap()
        app.buttons["Next clip"].tap()
        app.buttons["Previous clip"].tap()
        app.buttons["drawing.done"].waitForNonExistence(timeout: 5)
        // Back on the first clip at 0 s: the line's first frame.
        XCTAssertEqual(app.otherElements["drawing.overlay"].value as? String, "1 on this frame",
                       "reopening the clip must bring the line back")
    }

    func testTheLineStaysOnThePictureWhenZoomed() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "this walk is the phone's")
        let app = walkToAClip()
        let overlay = enterDrawing(app)
        drawLine(on: overlay, app: app)
        screenshot("03-before-zoom")
        let zoomIn = app.buttons["Zoom in"]
        XCTAssertTrue(zoomIn.waitForExistence(timeout: 5), "the zoom chip's plus button")
        for _ in 0..<4 { zoomIn.tap() }   // 1× → 3× in 0.5 steps
        screenshot("04-at-3x")
    }

    func testARightAngleReadsNinetyDegrees() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "this walk is the phone's")
        let app = walkToAClip()
        let overlay = enterDrawing(app)
        app.buttons["drawing.tool.angle"].tap()
        if app.buttons["OK"].waitForExistence(timeout: 2) { app.buttons["OK"].tap() }   // first-use note
        let corner = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        corner.press(forDuration: 0.1, thenDragTo: overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6)))
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        let value = app.staticTexts["drawing.angleValue.0"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        XCTAssertEqual(value.label, "90°")
        screenshot("05-right-angle")
    }

    func testTappingWhileDrawingDoesNotPlay() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "this walk is the phone's")
        let app = walkToAClip()
        let overlay = enterDrawing(app)
        app.buttons["drawing.tool.pen"].tap()
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        XCTAssertTrue(app.buttons["drawing.done"].exists, "a tap in drawing mode must not leave it or play")
    }
}
