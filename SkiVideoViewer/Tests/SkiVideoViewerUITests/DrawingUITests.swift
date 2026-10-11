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
        clearLeftovers(app, overlay)
        return overlay
    }

    /// Drawings persist in the app container, and every test's marks start at
    /// frame 0 of clip 1, where Clear frame deletes a mark on its first frame.
    private func clearLeftovers(_ app: XCUIApplication, _ overlay: XCUIElement) {
        for _ in 0..<10 where overlay.value as? String != "0 on this frame" {
            app.buttons["drawing.clearFrame"].tap()
        }
        XCTAssertEqual(overlay.value as? String, "0 on this frame", "leftover drawings must clear")
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

        let pill = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Status: Frame '")).firstMatch
        for _ in 0..<3 { app.buttons["drawing.stepForward"].tap() }
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "stepping must show a frame number in the status pill")
        XCTAssertEqual(pill.label, "Status: Frame 4", "three steps from frame 0 must land on frame 4 (1-based)")
        XCTAssertEqual(overlay.value as? String, "1 on this frame", "stepping must carry the line along")
        screenshot("02-after-three-steps")

        app.buttons["drawing.done"].tap()
        func caption(_ text: String) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
        }
        app.buttons["Next clip"].tap()
        XCTAssertTrue(caption("Clip 2 of 3").waitForExistence(timeout: 10), "Next clip must reach clip 2")
        // Drawing mode may still be up on clip 2; its overlay must be empty.
        let overlay2 = app.otherElements["drawing.overlay"]
        if overlay2.exists { XCTAssertEqual(overlay2.value as? String, "0 on this frame", "clip 2 has no marks") }
        app.buttons["Previous clip"].tap()
        XCTAssertTrue(caption("Clip 1 of 3").waitForExistence(timeout: 10), "Previous clip must return to clip 1")
        // Back on the first clip at 0 s: the line's first frame.
        let back = app.otherElements["drawing.overlay"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertEqual(back.value as? String, "1 on this frame",
                       "reopening the clip must bring the line back")
    }

    /// Proves the overlay's 3x mapping about the picture centre, not alignment
    /// with video content: the fixture is flat grey. Layer placement is covered
    /// by DrawingGeometryTests against VideoZoom.layerFrame.
    func testMarksScaleAboutThePictureCentreWhenZoomed() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "this walk is the phone's")
        let app = walkToAClip()
        let overlay = enterDrawing(app)
        app.buttons["drawing.tool.angle"].tap()
        if app.buttons["OK"].waitForExistence(timeout: 2) { app.buttons["OK"].tap() }
        // Corner off-centre at (0.6, 0.6); arms as in the angle test.
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6))
            .press(forDuration: 0.1, thenDragTo: overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.6)))
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.35)).tap()
        let label = app.staticTexts["drawing.angleValue.0"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        // The label sits 22pt above the corner and does not scale; add that back
        // so the offset measured is the corner's, which is what zoom scales.
        func cornerOffset() -> CGVector {
            let l = label.frame, o = overlay.frame
            return CGVector(dx: l.midX - o.midX, dy: (l.midY + 22) - o.midY)
        }
        let before = cornerOffset()
        screenshot("03-before-zoom")
        let zoomIn = app.buttons["Zoom in"]
        XCTAssertTrue(zoomIn.waitForExistence(timeout: 5), "the zoom chip's plus button")
        for _ in 0..<4 { zoomIn.tap() }   // 1× → 3× in 0.5 steps
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reset zoom'")).firstMatch
        XCTAssertTrue(chip.label.contains("3.0×"), "the zoom chip must read 3.0× but reads \(chip.label)")
        XCTAssertTrue(label.waitForExistence(timeout: 5), "the angle label must stay on screen at 3×")
        screenshot("04-at-3x")
        let after = cornerOffset()
        for (b, a, axis) in [(before.dx, after.dx, "x"), (before.dy, after.dy, "y")] where abs(b) > 10 {
            XCTAssertEqual(a, 3 * b, accuracy: abs(3 * b) * 0.15,
                           "corner offset on \(axis) must triple: before \(b), after \(a)")
        }
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

    func testAFortyFiveDegreeAngleReadsFortyFive() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "this walk is the phone's")
        let app = walkToAClip()
        let overlay = enterDrawing(app)
        app.buttons["drawing.tool.angle"].tap()
        if app.buttons["OK"].waitForExistence(timeout: 2) { app.buttons["OK"].tap() }
        // Points, not normalised offsets, so the pane's aspect ratio cannot skew
        // the angle. All inside the picture band (0.4-0.6 of the overlay height).
        let origin = overlay.coordinate(withNormalizedOffset: .zero)
        let h = overlay.frame.height, w = overlay.frame.width
        let corner = CGVector(dx: w * 0.3, dy: h * 0.55)
        origin.withOffset(corner).press(forDuration: 0.1,
            thenDragTo: origin.withOffset(CGVector(dx: corner.dx + 100, dy: corner.dy)))
        origin.withOffset(CGVector(dx: corner.dx + 100, dy: corner.dy - 100)).tap()
        let value = app.staticTexts["drawing.angleValue.0"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        XCTAssertEqual(value.label, "45°")
        screenshot("06-forty-five")
    }

    func testTappingWhileDrawingDoesNotPlay() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "this walk is the phone's")
        let app = walkToAClip()
        let overlay = enterDrawing(app)
        let timeline = app.sliders["Viewer timeline"]
        let before = timeline.value as? String
        app.buttons["drawing.tool.pen"].tap()
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(2)   // deliberate negative wait: playback, if it started, would move the playhead by now
        XCTAssertTrue(app.buttons["drawing.done"].exists, "a tap in drawing mode must not leave it")
        XCTAssertEqual(timeline.value as? String, before, "the playhead must not have moved: nothing played")
        XCTAssertEqual(overlay.value as? String, "0 on this frame", "pen plus a tap must not make a mark")
    }
}
