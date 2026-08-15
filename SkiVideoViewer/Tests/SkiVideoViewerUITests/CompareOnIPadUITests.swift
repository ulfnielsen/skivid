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
        // per side, because with no clips loaded the panes are otherwise
        // indistinguishable and a bare count of two passes just as happily when
        // both panes are wired to the same side — mutation-verified.
        XCTAssertTrue(app.buttons["Choose left clip"].exists)
        XCTAssertTrue(app.buttons["Choose right clip"].exists)
        // Those two are the *spoken* labels, which naming the side makes
        // side-specific. The visible title is the identifier, and nothing else
        // observes it — without this, renaming the button on screen is a change
        // no test can see.
        XCTAssertEqual(
            app.buttons.matching(identifier: "Choose Clip").count,
            2,
            "the visible title of both choosers must still read Choose Clip"
        )

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

        // Landscape on an 11-inch is 1210pt, above the bar's 880.5pt wrap
        // threshold, so the layout picker and the transport are on the *same*
        // row and side-by-side costs two rows of chrome in total: the scrubber
        // and the bar. This is the width at which the spec's "seven rows to
        // two" claim is true, and it is asserted here so that the portrait
        // test's opposite assertion cannot be read as the only behaviour.
        XCTAssertTrue(
            sharesARow(app.buttons["Side-by-side"].frame, app.buttons["Play or pause"].frame),
            """
            the bar must fit on one row in landscape: \
            \(app.buttons["Side-by-side"].frame) vs \(app.buttons["Play or pause"].frame)
            """
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
        // Rotation is animated, and the window reports its new size before the
        // controls inside it have finished moving — this loop failed once with
        // "Back 5 seconds" at y 2343 in an 1210pt-tall window, roughly twice
        // the height, on a screen that was otherwise laid out correctly. Wait
        // for one control to land before measuring any of them. This cannot
        // mask a genuine clipping: the wait is bounded, and the assertions
        // below still run.
        let settled = expectation(
            for: NSPredicate { element, _ in
                guard let element = element as? XCUIElement else { return false }
                return window.contains(element.frame)
            },
            evaluatedWith: app.buttons["Back 5 seconds"]
        )
        _ = XCTWaiter().wait(for: [settled], timeout: 10)

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

        // Every iPad portrait width is below the 880.5pt threshold, so the bar
        // is *always* wrapped here — the layout picker and the transport are on
        // different rows, and side-by-side therefore costs three rows of chrome
        // (scrubber, pickers, transport), not the spec's two. Pinned rather
        // than left to the screenshots, because it is the difference between
        // the redesign's headline number holding and not.
        XCTAssertFalse(
            sharesARow(app.buttons["Side-by-side"].frame, app.buttons["Play or pause"].frame),
            """
            the bar is expected to wrap to two rows below 880.5pt: \
            \(app.buttons["Side-by-side"].frame) vs \(app.buttons["Play or pause"].frame)
            """
        )

        assertTheStatusChipClearsEverythingUnderIt(app, window: window)

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

    /// `Both` is the control this redesign refuses to show before it can work:
    /// `playSynced` and `seekSynced` both bail out unless sync points are set,
    /// so offering it while aligning is a control that can only produce a nag —
    /// exactly what the redesign deletes. `availableTargets` is what enforces
    /// it, and this is the only check that the view is bound to that rather
    /// than to `ComparisonTarget.allCases`.
    ///
    /// The converse — `Both` *appearing* once sync points are set — is not
    /// covered here and cannot be: `setSyncPoints()` requires two loaded clips
    /// and a UI test cannot load one. See the task report; the headless
    /// `ComparisonControlBarLayoutTests` drives the synced state instead.
    func testTheControlBarOffersOnlyPerSideTargetsBeforeSyncing() {
        let app = launchPastTheFolderPicker()

        let compare = app.buttons["Compare Videos…"]
        XCTAssertTrue(compare.waitForExistence(timeout: 30))
        compare.tap()

        XCTAssertTrue(
            app.buttons["Left"].waitForExistence(timeout: 30),
            "the target selector must offer Left while aligning"
        )
        XCTAssertTrue(app.buttons["Right"].exists)
        XCTAssertFalse(
            app.buttons["Both"].exists,
            "Both cannot work before sync points are set"
        )
    }

    /// The anchor absorbs three of the deleted text buttons and says which one
    /// it currently is. Before anything is synced it must advertise *setting*
    /// the sync points — an icon whose label still read "Return to sync points"
    /// while aligning would be the icon-only bar's worst failure mode.
    func testTheAnchorButtonAdvertisesSettingSyncPoints() {
        let app = launchPastTheFolderPicker()

        let compare = app.buttons["Compare Videos…"]
        XCTAssertTrue(compare.waitForExistence(timeout: 30))
        compare.tap()

        XCTAssertTrue(
            app.buttons["Set sync points"].waitForExistence(timeout: 30),
            "the anchor must say what it does before anything is synced"
        )
        XCTAssertFalse(
            app.buttons["Return to sync points"].exists,
            "the anchor must not advertise the synced meaning while aligning"
        )
    }

    /// One transport, and it is disabled rather than absent until there is
    /// something to drive. Present matters because this single row replaced
    /// three separate transports; disabled matters because the redesign's rule
    /// is that a control which cannot work does not sit there waiting to nag.
    func testTheTransportIsPresentAndDisabledWithoutClips() {
        let app = launchPastTheFolderPicker()

        let compare = app.buttons["Compare Videos…"]
        XCTAssertTrue(compare.waitForExistence(timeout: 30))
        compare.tap()

        let playPause = app.buttons["Play or pause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 30))
        XCTAssertFalse(
            playPause.isEnabled,
            "transport must be disabled until two clips are loaded"
        )
        // The whole transport, not just its middle button: `ForEach` over
        // `TransportAction.allCases` means one `disabled` modifier governs all
        // six, and a regression that dropped it would drop it for all six.
        for label in [
            "Back 5 seconds", "Back 1 second", "Forward 1 second",
            "Forward 5 seconds", "Play at quarter speed", "Set sync points",
        ] {
            XCTAssertFalse(
                app.buttons[label].isEnabled,
                "\(label) must be disabled until two clips are loaded"
            )
        }
    }

    /// Sort & Resize now has an iPad UI: the pipeline it drives runs
    /// in-process on AVFoundation and compiles for iOS, and `SortingSheet` is
    /// plain SwiftUI, so there is no longer anything Mac-only standing in the
    /// way. The button must be present, and tapping it must actually open the
    /// sorting sheet rather than merely exist — asserting on "Start Tagging",
    /// a control that only exists inside the sheet, is what tells the two
    /// apart. Before this test, nothing proved the sheet opens at all on
    /// iPad.
    func testTappingSortOpensTheSortingSheet() {
        let app = launchPastTheFolderPicker()

        let sort = app.buttons["Sort & Resize…"]
        XCTAssertTrue(
            sort.waitForExistence(timeout: 30),
            "the iPad toolbar must offer Sort & Resize"
        )
        sort.tap()

        XCTAssertTrue(
            app.buttons["Start Tagging"].waitForExistence(timeout: 30),
            "tapping Sort & Resize must present the sorting sheet"
        )

        attachScreenshot(named: "sorting-sheet")
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

    /// The status chip floats over the video, so the only thing keeping it off
    /// the controls beneath it is its geometry — and geometry is exactly what
    /// `exists` and `isHittable` say nothing about. The first version of it was
    /// bottom-trailing and *unbounded*: measured at 834pt it laid out 446pt
    /// wide against a 415pt pane, overran the divider and covered the left
    /// pane's caption. It is not hit-testable, so nothing failed — the chip
    /// simply sat on top of the filename.
    ///
    /// Asserted as "stays in the right half" rather than "does not intersect
    /// the caption", because the captions only exist once clips are loaded and
    /// a UI test cannot load them. Half the window is the same bound: the panes
    /// split it evenly.
    private func assertTheStatusChipClearsEverythingUnderIt(
        _ app: XCUIApplication,
        window: CGRect
    ) {
        let chip = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH 'Status: '"))
            .firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "the status must be on screen to be placed")

        let frame = chip.frame
        // The clearance below is only durable if the chip's width does not
        // depend on the sentence in it, and this test can only ever see the
        // initial 46-character status: no UI route reaches a longer one
        // without two loaded clips. So it pins the *cap* — 320pt of text plus
        // 2×10pt of padding — while `ComparisonStatusChipTests` measures the
        // real 83-character status against the same bound headlessly, which
        // this comment previously (and wrongly) claimed was impossible.
        XCTAssertEqual(
            frame.width,
            340,
            accuracy: 0.5,
            "the status chip must be a constant width, not sized to its text: \(frame)"
        )
        XCTAssertGreaterThanOrEqual(
            frame.minX,
            window.midX,
            "the status chip reaches into the left pane: \(frame) in \(window)"
        )
        XCTAssertTrue(
            window.contains(frame),
            "the status chip is clipped: \(frame) outside \(window)"
        )
        for label in ["Close comparison", "Choose left clip", "Choose right clip"] {
            XCTAssertFalse(
                frame.intersects(app.buttons[label].frame),
                "the status chip covers \(label): \(frame) over \(app.buttons[label].frame)"
            )
        }
    }

    /// `ViewerModel.start(initialDirectory: nil)` opens the folder picker from
    /// `onAppear`, so every launch begins with a `UIDocumentPickerViewController`
    /// on screen. Its content lives in another process and never reaches this
    /// app's accessibility tree, but its dismiss region does — and until it is
    /// gone that region swallows every tap, so a toolbar button can be found,
    /// reported hittable, and tapped with no effect whatsoever. That is exactly
    /// what happened the first time these tests were written.
    ///
    /// **The region is not universal, and the difference is measured.** On an
    /// iPad mini (A17 Pro) the picker presents as a sheet with no
    /// `PopoverDismissRegion` at all — but, unlike the 11-inch's form sheet,
    /// its own contents *do* reach this app's tree, Cancel button included.
    /// Dumped from `app.debugDescription`, not guessed: Cancel, More, Recents,
    /// Locations, iCloud Drive. Tapping Cancel is the dismissal there.
    ///
    /// Do not "simplify" this to just asserting the toolbar is reachable. That
    /// was tried, and it passed on the mini *while the picker was still up* —
    /// the toolbar is in the tree underneath it — and the tap on Compare then
    /// went nowhere. That is precisely the trap this helper exists for.
    private func launchPastTheFolderPicker() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()

        let dismissRegion = app.otherElements["PopoverDismissRegion"]
        guard dismissRegion.waitForExistence(timeout: 30) else {
            dismissTheFolderPickerByCancelling(app)
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

    /// The iPad mini's sheet-style presentation of the same picker. Asserted
    /// gone afterwards for the same reason the region path is: a picker still
    /// on screen swallows every subsequent tap.
    private func dismissTheFolderPickerByCancelling(_ app: XCUIApplication) {
        let cancel = app.buttons["Cancel"]
        guard cancel.waitForExistence(timeout: 15) else {
            XCTFail("expected the launch folder picker; did ViewerModel.start change?")
            return
        }
        cancel.tap()

        let gone = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: cancel
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [gone], timeout: 30),
            .completed,
            "the folder picker must be dismissed before anything else is tappable"
        )
    }

    /// Whether two controls are on the same row of the bar, which is how the
    /// wrap is observed from outside: `ViewThatFits` picks the stacked layout
    /// below 880.5pt, and the only visible consequence is that the pickers and
    /// the transport stop sharing a vertical band.
    private func sharesARow(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minY < b.maxY && b.minY < a.maxY
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
