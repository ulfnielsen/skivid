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

}
