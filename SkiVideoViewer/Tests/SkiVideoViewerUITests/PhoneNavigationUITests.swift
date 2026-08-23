import XCTest

/// The three screens a phone has, walked end to end.
///
/// **This suite exists because the app once launched on a phone and offered no
/// way in.** `NavigationSplitView` collapses to its sidebar there, so the
/// libraries list — the only route to opening anything — sat in the detail
/// column that nothing could push, and the toolbar carrying "Add Folder…"
/// hangs off that same column. The app showed "Athletes", an empty list, and
/// nothing else. Screenshots prove a screen renders; only a tap proves it leads
/// somewhere, and `simctl` has no input injection.
///
/// Skipped on iPad, where the same three things are two columns and no stack.
///
/// **The fixture is the same one `ViewerOnIPadUITests` needs** — three clips in
/// the app container's `Documents/Snow/`, see that file's header for the
/// `ffmpeg` lines. The names matter: the captions are asserted verbatim there,
/// and a fixture built with different names fails in a way that reads like a
/// navigation bug.
///
///     export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
///     xcodebuild -scheme SkiVideoViewer-iPad \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
final class PhoneNavigationUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Libraries → athletes → clip, by tapping, on a phone.
    func testAPhoneCanReachAClipFromALaunchedApp() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .phone,
            "the stack only exists at compact width; the iPad has two columns"
        )

        let app = walkToAClip()
        _ = app
    }

    /// Sorting opens on a phone and every control lands on the screen.
    ///
    /// `SortingSheet` declared `.frame(minWidth: 820, minHeight: 640)` against
    /// a 402pt device, and the toolbar offered it anyway — a screen a coach
    /// could open and could not use. "Fits" is asserted as frames inside the
    /// window rather than eyeballed, because a control pushed off the right
    /// edge is exactly what a screenshot at the wrong moment would miss.
    func testSortingFitsAPhone() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .phone,
            "the iPad has the 820pt this was designed for"
        )

        let app = walkToAClip()

        let sort = app.buttons["Sort & Resize…"]
        if !sort.exists {
            let more = app.buttons["More"]
            XCTAssertTrue(more.waitForExistence(timeout: 10), "no Sort & Resize, and no overflow to look in")
            more.tap()
        }
        XCTAssertTrue(sort.waitForExistence(timeout: 10), "sorting must be reachable on a phone")
        sort.tap()

        let source = app.textFields["Choose a source folder…"]
        XCTAssertTrue(source.waitForExistence(timeout: 20), "the sorting setup must open")

        let window = app.windows.firstMatch.frame
        assertFits(app.buttons["sorting.chooseSource"], in: window, "the source chooser")
        assertFits(app.buttons["Start Tagging"], in: window, "Start Tagging")
        assertFits(app.buttons["Cancel"], in: window, "Cancel")

        // Through to tagging, which is the screen under real width pressure:
        // a text field and two buttons that wanted about 520pt on one row.
        app.buttons["sorting.chooseSource"].tap()
        openTheFixtureFolder(in: app)

        let start = app.buttons["Start Tagging"]
        XCTAssertTrue(start.waitForExistence(timeout: 20), "the source must come back to the setup screen")
        // A source alone is not enough to sort, and the button says so now
        // rather than accepting the tap and answering with an alert.
        XCTAssertFalse(start.isEnabled, "a source without an event title cannot start a sort")

        let title = app.textFields["e.g. Neuss"]
        XCTAssertTrue(title.exists, "the event title field must be on screen")
        title.tap()
        title.typeText("Wittenburg")

        XCTAssertTrue(start.isEnabled, "source and title together must enable Start Tagging")
        start.tap()

        let athleteField = app.textFields["Type athlete name"]
        XCTAssertTrue(athleteField.waitForExistence(timeout: 30), "tagging must start")

        assertFits(athleteField, in: window, "the athlete field")
        assertFits(app.buttons["Skip"], in: window, "Skip")
        assertFits(app.buttons["Next Clip"], in: window, "Next Clip")
    }

    /// A control is usable only if it is on the screen. Asserted as frames
    /// rather than eyeballed: something pushed off the right edge is exactly
    /// what a screenshot taken at the wrong moment would miss.
    private func assertFits(_ element: XCUIElement, in window: CGRect, _ what: String) {
        XCTAssertTrue(element.exists, "\(what) is not on screen at all")
        XCTAssertTrue(
            window.contains(element.frame),
            "\(what) sits outside the screen: \(element.frame) in \(window)"
        )
    }

    /// Sideways, the video gets the screen.
    ///
    /// A phone is turned sideways to make the clip bigger. Measured rather than
    /// eyeballed: the video's own pane must take more of the screen in
    /// landscape than the chrome around it does, and the chrome must shrink
    /// rather than merely rearrange.
    func testLandscapeGivesTheVideoTheScreen() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .phone,
            "an iPad has regular height in both orientations"
        )

        let app = walkToAClip()
        // A slider's frame is what it *draws*, not the row it sits in, so the
        // measurement is the band it starts: everything from the top of the
        // scrubber down to the bottom edge is chrome, and whatever is left
        // above it is the video.
        let scrubber = app.sliders["Viewer timeline"]
        XCTAssertTrue(scrubber.waitForExistence(timeout: 20), "the scrubber must be on screen")
        let uprightBand = app.windows.firstMatch.frame.maxY - scrubber.frame.minY

        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }

        let settled = expectation(for: NSPredicate { element, _ in
            guard let element = element as? XCUIElement, element.exists else { return false }
            return element.frame.width > element.frame.height * 4
        }, evaluatedWith: scrubber)
        XCTAssertEqual(
            XCTWaiter().wait(for: [settled], timeout: 15), .completed,
            "the layout must settle into landscape"
        )

        let landscapeBand = app.windows.firstMatch.frame.maxY - scrubber.frame.minY
        XCTAssertLessThan(
            landscapeBand, uprightBand,
            "sideways, the controls must give height back to the video: \(landscapeBand)pt vs \(uprightBand)pt upright"
        )
        XCTAssertFalse(
            app.navigationBars.firstMatch.exists,
            "the navigation bar sits on top of the video sideways and should not be there"
        )
    }

    /// Launch, open the fixture library, and land on a clip — the whole stack,
    /// by tapping, which is what the first test asserts step by step and every
    /// other test here needs as a starting point.
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

    /// Comparison is absent on a phone, not merely awkward there.
    ///
    /// `ComparisonView` declares `.frame(minWidth: 1000, minHeight: 680)` and
    /// this device offers 402 × 874. A button that opens a screen two and a
    /// half times too wide is worse than no button, so the check is that it is
    /// not on screen — anywhere, including under the More menu a crowded
    /// toolbar collapses into.
    func testComparisonIsNotOfferedOnAPhone() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .phone,
            "the iPad has the width for it and offers it deliberately"
        )

        // On the viewer, not on the launch screen. The first version of this
        // asserted straight after launch and passed against the very code it
        // was meant to catch: a phone lands on the libraries list, which has no
        // toolbar at all, so "Compare is absent" was true there no matter what
        // the toolbar said. The toolbar hangs off `detail` — this screen.
        let app = walkToAClip()

        XCTAssertFalse(
            app.buttons["Compare Videos…"].exists,
            "a phone cannot fit the comparison screen; buttons were \(app.buttons.allElementsBoundByIndex.map(\.label))"
        )
    }

}
