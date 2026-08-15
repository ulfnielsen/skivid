import XCTest

/// The redesigned viewer, driven on a real iPad simulator with a real clip
/// loaded.
///
/// **This suite exists to produce a number, not a pass.** The spec claimed the
/// viewer's bar fits one row at both 834pt and 744pt, for a band of roughly
/// `44pt scrubber + 60pt row = ~104pt` at every iPad width — and labelled that
/// an expectation rather than a measurement. Measured here, the claim holds
/// only in landscape. See
/// `testTheControlBarWrapsInPortraitBecauseTheSidebarKeeps270Points`: the bar
/// never gets the *window* width in portrait, because `NavigationSplitView`
/// keeps its 270pt sidebar on screen there, leaving 564pt on an 11-inch and
/// 474pt on a mini. Both are below the bar's ideal width, so it wraps and the
/// band measures 156pt.
///
/// Three things earlier tasks could not close are closed here, all of them for
/// the same reason: a `swift test` host process on macOS never registers as an
/// accessible application (`AXUIElementCopyAttributeValue` returns
/// `kAXErrorNotImplemented`), so nothing in the macOS suite can read a semantic
/// label off a live control or drive a UIKit gesture. An XCUITest runner reads a
/// fully populated UIKit accessibility tree.
///
/// 1. `testNextClipAdvancesAndPreviousClipGoesBack` pins the *labels*
///    `Previous clip` and `Next clip` to the directions they actually step.
///    `ViewerControlsWiringTests` finds those two buttons positionally, so
///    swapping only the label strings leaves every macOS test green.
/// 2. `testTappingTheVideoTogglesPlaybackEvenThroughTheStatusChip` covers
///    tap-to-play on iPadOS, whose UIKit gesture arbitration is a different
///    subsystem from the AppKit one the macOS suite drives. Task 3 could only
///    cover macOS.
/// 3. `testTheStatusChipIsAConstantWidthAndClearsTheControlsBelowIt` measures
///    the chip on the device rather than in an `NSHostingView`.
///
/// Runs as part of the `SkiVideoViewer-iPad` scheme:
///
///     export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
///     xcodebuild -scheme SkiVideoViewer-iPad \
///       -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' test
///
/// **The fixture is not optional and cannot be created from inside the test.**
/// `ViewerModel.start(initialDirectory: nil)` is the app's only load route on
/// iPad, and it opens `UIDocumentPickerViewController`, which browses the
/// device rather than anything the runner can write. Three clips must already
/// be in the app container's `Documents/Snow/` before the suite runs:
///
///     ffmpeg -y -f lavfi -i "color=c=0xF0F0F0:size=1280x720:rate=30:duration=8" \
///       -c:v libx264 -pix_fmt yuv420p /tmp/viewer-fixture/Snow/run1-bright-snow.mp4
///     C=$(xcrun simctl get_app_container <udid> dk.dyregod.video-viewer.ipad data)
///     cp -R /tmp/viewer-fixture/Snow "$C/Documents/"
///
/// `-pix_fmt yuv420p` is not optional: without it ffmpeg negotiates up to 10-bit
/// 4:4:4, which VideoToolbox on iPhone and iPad cannot decode at all
/// (`kVTVideoDecoderBadDataErr`, −8969).
final class ViewerOnIPadUITests: XCTestCase {
    /// `TimelineScrubber`'s own `.frame(height: 44)`. The slider *draws* over
    /// about 31pt and is centred in that row, so the row's top has to be
    /// derived from the slider's midY rather than read off its frame.
    private static let scrubberRowHeight: CGFloat = 44

    /// `ViewerControlBar`'s own `.padding(.vertical, 8)`, above the first row of
    /// controls and below the last.
    private static let barVerticalPadding: CGFloat = 8

    /// **Measured** on both an iPad Pro 11-inch (M5) and an iPad mini (A17 Pro):
    /// the scrubber's 44pt row plus a single 44pt row of controls with 2×8pt of
    /// padding. This is the spec's claimed figure, and it is what the band
    /// actually measures wherever the bar gets enough width.
    private static let oneRowBandHeight: CGFloat = 104

    /// **Measured** on both devices in portrait: the same scrubber row plus a
    /// *wrapped* bar — two 44pt rows, 8pt of `VStack` spacing, 2×8pt padding.
    private static let wrappedBandHeight: CGFloat = 156

    /// `ViewerPane`'s `.frame(maxWidth: 320)` on the chip's `Text`, plus its
    /// 2×10pt horizontal padding. A flexible `maxWidth` frame takes the width it
    /// is offered up to the cap, so the pill is this wide for *every* status —
    /// which is the point. Without the cap it shrinks to fit the sentence.
    private static let statusChipWidth: CGFloat = 340

    /// The six shared transport buttons, in `TransportAction.allCases` order.
    private static let transportLabels = [
        "Back 5 seconds", "Back 1 second", "Play or pause",
        "Forward 1 second", "Forward 5 seconds", "Play at quarter speed",
    ]

    /// Every control in the band: the transport, then the two clip-stepping
    /// buttons `ViewerControlBar` adds beside it.
    private static let barButtonLabels = transportLabels + ["Previous clip", "Next clip"]

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        // Orientation is simulator-wide and outlives the process, so a test that
        // rotates would leave every later test — in this file and in
        // `CompareOnIPadUITests` — in the orientation it finished in.
        XCUIDevice.shared.orientation = .landscapeLeft
        super.tearDown()
    }

    // MARK: - What the redesign put on screen

    /// Everything the band is made of, present, enabled and reachable once a
    /// clip is loaded. The whole point of the redesign is that these controls
    /// replaced three text buttons and a hint line describing keyboard
    /// shortcuts that do not exist on iPad, so "they are all here and all
    /// usable" is the first thing to pin.
    ///
    /// `isHittable`, not just `exists`: a control pushed off the edge of the
    /// window still exists.
    func testTheViewerLoadsAClipAndEnablesEveryControl() {
        let app = launchAndOpenTheFixtureFolder()

        let timeline = app.sliders["Viewer timeline"]
        XCTAssertTrue(timeline.exists, "the shared scrubber must be in the band")
        XCTAssertTrue(
            timeline.isEnabled,
            """
            the timeline must be enabled once a clip is loaded — TimelineScrubber \
            disables itself while `duration <= 0`, so a disabled slider here means \
            the fixture never published a duration (check -pix_fmt yuv420p)
            """
        )

        for label in Self.barButtonLabels {
            let button = app.buttons[label]
            XCTAssertTrue(button.exists, "\(label) must be in the control bar")
            XCTAssertTrue(button.isEnabled, "\(label) must be enabled with a clip loaded")
            XCTAssertTrue(button.isHittable, "\(label) must be reachable")
        }

        // The status moved out of the deleted control rows and onto the video.
        // Matched by prefix rather than by the exact sentence, so this pins
        // *that the status is displayed at all* without pinning the model's
        // wording.
        XCTAssertTrue(
            statusChip(app).exists,
            "the status must be on screen; it has no other home since the rows went"
        )
        // The athlete name and the clip caption, the other two deleted rows.
        XCTAssertTrue(app.staticTexts["Snow"].exists, "the athlete name must be over the video")
        XCTAssertTrue(
            caption(app).exists,
            "the clip caption must be over the video"
        )
    }

    /// **The clip-stepping label-swap gap, closed.** `ViewerControlsWiringTests`
    /// finds these two buttons by position in the AppKit view tree, so swapping
    /// only the label strings `"Previous clip"` and `"Next clip"` leaves the
    /// entire macOS suite green. Here the button is found *by its spoken label*
    /// and the clip it lands on is read back from the caption, so the label and
    /// the direction are pinned to each other.
    ///
    /// Three clips, not two: from clip 1 of 2, `+1` and `-1` both land on clip
    /// 2, so a two-clip fixture cannot tell a sign flip from a correct step.
    /// With three, Next goes 1→2 and Previous wraps 1→3.
    func testNextClipAdvancesAndPreviousClipGoesBack() {
        let app = launchAndOpenTheFixtureFolder()
        XCTAssertEqual(
            caption(app).label,
            "Clip 1 of 3 · run1-bright-snow.mp4",
            "precondition: the fixture must load its three clips, first one selected"
        )

        app.buttons["Next clip"].tap()
        XCTAssertTrue(
            waitForCaption(app, "Clip 2 of 3 · run2-whiteout.mp4"),
            """
            the button labelled 'Next clip' must advance the clip; the caption \
            reads '\(caption(app).label)'
            """
        )

        app.buttons["Previous clip"].tap()
        XCTAssertTrue(
            waitForCaption(app, "Clip 1 of 3 · run1-bright-snow.mp4"),
            """
            the button labelled 'Previous clip' must step back; the caption \
            reads '\(caption(app).label)'
            """
        )

        // Once more from the first clip, which wraps to the last. This is what
        // makes the pair distinguishable: a swapped implementation would land on
        // clip 2 here, which the assertion above already visited legitimately.
        app.buttons["Previous clip"].tap()
        XCTAssertTrue(
            waitForCaption(app, "Clip 3 of 3 · run3-testpattern.mp4"),
            """
            'Previous clip' must wrap from the first clip to the last, not \
            advance to the second; the caption reads '\(caption(app).label)'
            """
        )
    }

    /// **Tap-to-play on iPadOS**, which Task 3 could only cover on macOS: there
    /// the pane is an `NSView` reachable with a synthetic `NSEvent` through
    /// `window.sendEvent(_:)`; here it is UIKit's own gesture arbitration, a
    /// different subsystem entirely. (Both platforms have rendered the pane
    /// through `SinglePlayerView` since the zoom landed — it is the *event*
    /// route that differs, not the view.)
    ///
    /// The tap deliberately lands **on the status chip**, the strictest place on
    /// the pane to tap: the chip floats over the video and a chip that swallowed
    /// the gesture would look completely normal in a screenshot.
    ///
    /// **It does not, however, kill the deletion of the chip's
    /// `.allowsHitTesting(false)` — measured.** With that modifier removed this
    /// test still passes: UIKit routes the tap past the overlay to the gesture
    /// below whether or not the chip claims hits. AppKit does not, so the
    /// mutation is killed on macOS instead, by
    /// `ViewerControlsWiringTests.testTappingWhereTheStatusChipSitsStillTogglesPlayback`.
    /// What this test *does* cover, and nothing else does, is that tap-to-play
    /// works on iPadOS at all — UIKit gesture arbitration, which the macOS
    /// test says nothing about.
    func testTappingTheVideoTogglesPlaybackEvenThroughTheStatusChip() {
        let app = launchAndOpenTheFixtureFolder()
        XCTAssertEqual(
            statusChip(app).label, "Status: Paused",
            "precondition: a freshly loaded clip is paused"
        )

        let chip = statusChip(app).frame
        let overTheChip = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: chip.midX, dy: chip.midY))

        overTheChip.tap()
        XCTAssertTrue(
            waitForStatus(app, "Status: Playing"),
            """
            a tap on the video must start playback, and the status chip must not \
            swallow it; the status reads '\(statusChip(app).label)'
            """
        )

        overTheChip.tap()
        XCTAssertTrue(
            waitForStatus(app, "Status: Paused"),
            """
            a second tap must pause again; the status reads \
            '\(statusChip(app).label)'
            """
        )
    }

    // MARK: - The measurement

    /// **Landscape: the spec's claim holds.** The detail pane is 940pt on an
    /// 11-inch and 863pt on a mini, both comfortably above the bar's ideal
    /// width, so transport, time readout and clip stepping share one row and the
    /// band measures the claimed 104pt.
    func testTheControlBarFitsOneRowInLandscape() {
        let app = launchAndOpenTheFixtureFolder()
        rotate(app, to: .landscapeLeft)

        XCTAssertTrue(
            sharesARow(app.buttons["Play or pause"].frame, app.buttons["Next clip"].frame),
            """
            the bar must fit one row in landscape: \
            \(app.buttons["Play or pause"].frame) vs \(app.buttons["Next clip"].frame)
            """
        )
        let band = bandHeight(app)
        XCTAssertEqual(
            band,
            Self.oneRowBandHeight,
            accuracy: 1,
            "the landscape band must measure 104pt; measured \(band) in \(mainWindow(app))"
        )
        XCTAssertLessThan(
            band,
            130,
            """
            the band must be smaller than the ~130pt control band it replaced; \
            measured \(band)
            """
        )
        assertNothingIsClipped(app)
        attachScreenshot(named: "viewer-landscape")
    }

    /// **Portrait: the spec's claim fails, and this is the measurement that says
    /// so.**
    ///
    /// The spec reasoned from the *window* width — 834pt on an 11-inch, 744pt on
    /// a mini — and concluded the bar fits one row at both. The bar never gets
    /// the window width. `ContentView` is a `NavigationSplitView`, and in
    /// portrait iPadOS keeps the 270pt sidebar on screen beside the detail
    /// column rather than collapsing it, so the bar is laid out in **564pt** on
    /// an 11-inch and **474pt** on a mini. Both are below its ideal width, so it
    /// takes the `ViewThatFits` fallback: two rows, and a band of 156pt rather
    /// than 104pt.
    ///
    /// The arithmetic in the spec was right about the bar and wrong about what
    /// width the bar is offered. `testHidingTheSidebarInPortraitRestoresTheOneRowBar`
    /// is the control that separates those two claims.
    func testTheControlBarWrapsInPortraitBecauseTheSidebarKeeps270Points() {
        let app = launchAndOpenTheFixtureFolder()
        rotate(app, to: .portrait)

        let window = mainWindow(app)
        XCTAssertGreaterThan(window.height, window.width, "precondition: the device must be in portrait")

        // The sidebar is still there, which is the whole finding. Its Hide
        // button only exists while it is showing.
        XCTAssertTrue(
            app.buttons["Hide Sidebar"].exists,
            "the sidebar must still be on screen in portrait, or this test measures the wrong thing"
        )
        XCTAssertLessThan(
            app.sliders["Viewer timeline"].frame.width,
            window.width - 200,
            """
            the band must be narrower than the window by roughly the sidebar's \
            width: the scrubber is \(app.sliders["Viewer timeline"].frame.width)pt \
            in a \(window.width)pt window
            """
        )

        XCTAssertFalse(
            sharesARow(app.buttons["Play or pause"].frame, app.buttons["Next clip"].frame),
            """
            measured: the bar wraps in portrait, so the transport and the clip \
            stepping are on different rows: \(app.buttons["Play or pause"].frame) \
            vs \(app.buttons["Next clip"].frame)
            """
        )
        let band = bandHeight(app)
        XCTAssertEqual(
            band,
            Self.wrappedBandHeight,
            accuracy: 1,
            """
            the portrait band measures 156pt, not the spec's 104pt; measured \
            \(band) in \(window)
            """
        )
        assertNothingIsClipped(app)
        attachScreenshot(named: "viewer-portrait")
    }

    /// The control that isolates *why* portrait wraps. Hiding the sidebar hands
    /// the bar the full window width — 834pt on an 11-inch, 744pt on a mini,
    /// exactly the two widths the spec named — and the bar snaps back to one row
    /// and 104pt at both.
    ///
    /// So the spec's arithmetic about the bar was correct: it does fit one row
    /// at 834pt and at 744pt. What it missed is that the viewer's bar is never
    /// offered those widths in portrait.
    func testHidingTheSidebarInPortraitRestoresTheOneRowBar() {
        let app = launchAndOpenTheFixtureFolder()
        rotate(app, to: .portrait)

        XCTAssertFalse(
            sharesARow(app.buttons["Play or pause"].frame, app.buttons["Next clip"].frame),
            "precondition: the bar must be wrapped before the sidebar is hidden"
        )

        app.buttons["Hide Sidebar"].tap()

        let window = mainWindow(app)
        let fullWidth = expectation(
            for: NSPredicate { element, _ in
                guard let element = element as? XCUIElement else { return false }
                // The scrubber spans the detail column less its 12pt insets, so
                // this is "the sidebar has finished sliding away", not a sleep.
                return element.frame.width >= window.width - 30
            },
            evaluatedWith: app.sliders["Viewer timeline"]
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [fullWidth], timeout: 10),
            .completed,
            "the sidebar must actually collapse before the bar is measured again"
        )

        XCTAssertTrue(
            sharesARow(app.buttons["Play or pause"].frame, app.buttons["Next clip"].frame),
            """
            given the full \(window.width)pt window the bar must fit one row: \
            \(app.buttons["Play or pause"].frame) vs \(app.buttons["Next clip"].frame)
            """
        )
        let band = bandHeight(app)
        XCTAssertEqual(
            band,
            Self.oneRowBandHeight,
            accuracy: 1,
            """
            at the full window width the band must measure the spec's 104pt; \
            measured \(band) in \(window)
            """
        )
        assertNothingIsClipped(app)
        attachScreenshot(named: "viewer-portrait-sidebar-hidden")
    }

    // MARK: - The chip

    /// The chip floats over the video, so the only thing keeping it off the
    /// video's edge and off the caption is its geometry — which is exactly what
    /// `exists` and `isHittable` say nothing about.
    ///
    /// The constant width is the assertion that matters. `.frame(maxWidth: 320)`
    /// sits on the `Text`, before the padding and background, and a flexible
    /// `maxWidth` frame takes the width it is offered up to the cap — so the
    /// pill is 340pt wide for every status the model can produce. Remove the
    /// cap and the pill sizes to its sentence instead: measured at 62.0pt for
    /// `Paused`, and it would move and resize on every status change.
    func testTheStatusChipIsAConstantWidthAndClearsTheControlsBelowIt() {
        let app = launchAndOpenTheFixtureFolder()
        rotate(app, to: .portrait)

        let window = mainWindow(app)
        let chip = statusChip(app).frame
        XCTAssertEqual(
            chip.width,
            Self.statusChipWidth,
            accuracy: 0.5,
            "the chip must be a constant 340pt wide, not sized to its text: \(chip)"
        )
        XCTAssertTrue(window.contains(chip), "the chip is clipped: \(chip) outside \(window)")
        XCTAssertFalse(
            chip.intersects(caption(app).frame),
            "the chip covers the clip caption: \(chip) over \(caption(app).frame)"
        )
        for label in Self.barButtonLabels {
            XCTAssertFalse(
                chip.intersects(app.buttons[label].frame),
                "the chip covers \(label): \(chip) over \(app.buttons[label].frame)"
            )
        }
    }

    // MARK: - Launch

    /// Launches, drives the launch document picker to the fixture folder, and
    /// returns only once a clip is genuinely loaded.
    ///
    /// **On the picker, and why this is not `CompareOnIPadUITests`'s helper.**
    /// That helper *cancels* the picker, which is exactly what these tests
    /// cannot do: every assertion in this file needs a clip on screen, and the
    /// picker is the app's only load route on iPad — `initialDirectory` is nil
    /// and there is no in-app opener. So this completes the pick instead of
    /// dismissing it.
    ///
    /// The trap that helper documents is still checked here, and checked harder.
    /// The 11-inch presents the picker as a popover whose `PopoverDismissRegion`
    /// swallows every tap while being invisible to the accessibility tree; a
    /// previous attempt used "the toolbar is reachable" as its dismissal check,
    /// which passed while the picker was still up and sent every later tap
    /// nowhere. This helper asserts four things before returning, each stronger
    /// than that:
    ///
    /// - **no** `PopoverDismissRegion` remains. Counted through
    ///   `matching(identifier:)` rather than read off
    ///   `app.otherElements["PopoverDismissRegion"]`, because on an 11-inch
    ///   there are *two* of them while the picker is up — measured — and a
    ///   single-element query over an ambiguous match resolves unreliably. The
    ///   first version of this helper used the single-element form and timed
    ///   out once at 30s on a region that a probe showed had gone within 2s.
    /// - the picker's own accept button is gone;
    /// - the viewer's timeline exists **and is enabled**, which no amount of
    ///   tapping into a dismiss region can produce — it requires
    ///   `openDirectory` to have scanned the folder and `AVPlayerItem` to have
    ///   published a duration;
    /// - **a tap actually lands.** Play/pause is tapped and the status is
    ///   required to change, then tapped back. This is the one check that
    ///   directly contradicts the failure mode the whole warning is about: a
    ///   tap that goes nowhere cannot move the status.
    ///
    /// The navigation itself is by accessibility identifier
    /// (`DOC.sidebar.item.On My iPad`, `SkiVideoViewer, Container`) rather than
    /// by coordinate. Those identifiers are the picker's own and reach this
    /// app's tree on both an 11-inch and a mini — dumped from
    /// `app.debugDescription`, not guessed.
    private func launchAndOpenTheFixtureFolder() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()

        let locations = app.cells["DOC.sidebar.item.On My iPad"]
        XCTAssertTrue(
            locations.waitForExistence(timeout: 60),
            "expected the launch folder picker; did ViewerModel.start change?"
        )
        locations.tap()

        let container = app.cells["SkiVideoViewer, Container"]
        XCTAssertTrue(
            container.waitForExistence(timeout: 30),
            """
            the app's own Documents folder must be visible under On My iPad. \
            It is published by UIFileSharingEnabled in iPad-Info.plist; if it is \
            missing, the fixture was never copied into the container — see this \
            file's header.
            """
        )
        container.tap()

        XCTAssertTrue(
            app.cells["Snow, Folder"].waitForExistence(timeout: 30),
            "the fixture folder Documents/Snow must exist — see this file's header"
        )
        let accept = app.buttons["Open"]
        XCTAssertTrue(accept.waitForExistence(timeout: 10), "the picker must offer its accept button")
        accept.tap()

        let regionsGone = expectation(
            for: NSPredicate { query, _ in
                (query as? XCUIElementQuery)?.count == 0
            },
            evaluatedWith: app.otherElements.matching(identifier: "PopoverDismissRegion")
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [regionsGone], timeout: 30),
            .completed,
            "the picker's dismiss regions must all be gone, or every later tap goes nowhere"
        )
        let pickerGone = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: accept
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [pickerGone], timeout: 30),
            .completed,
            "the picker must be off screen before anything else is tapped"
        )

        let timeline = app.sliders["Viewer timeline"]
        XCTAssertTrue(
            timeline.waitForExistence(timeout: 30),
            "the viewer band must appear once a folder is open"
        )
        let playable = expectation(
            for: NSPredicate(format: "isEnabled == true"),
            evaluatedWith: timeline
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [playable], timeout: 30),
            .completed,
            """
            the timeline stays disabled until the clip publishes a duration, so \
            this is the proof the fixture actually decoded — check -pix_fmt \
            yuv420p if it times out
            """
        )

        // The tap round-trip. Nothing above proves a tap *lands*: every check so
        // far is satisfied by state the app reached on its own. A dismiss region
        // still in front of the window would let all of them pass and swallow
        // this one.
        app.buttons["Play or pause"].tap()
        XCTAssertTrue(
            waitForStatus(app, "Status: Playing"),
            """
            taps are not reaching the app — the picker is probably still in \
            front of it. Status reads '\(statusChip(app).label)'
            """
        )
        app.buttons["Play or pause"].tap()
        XCTAssertTrue(
            waitForStatus(app, "Status: Paused"),
            "the second tap must pause again; status reads '\(statusChip(app).label)'"
        )
        return app
    }

    // MARK: - Geometry

    /// Rotates and waits — bounded, 10s — for a control to land inside the
    /// window before anything is measured.
    ///
    /// Rotation is animated and the window reports its new size before the
    /// controls inside it have finished moving: the comparison suite's
    /// equivalent loop once read `Back 5 seconds` at y 2343 in a 1210pt-tall
    /// window. Both halves of the predicate are load-bearing — the aspect check
    /// alone passes mid-animation, and the containment check alone passes before
    /// the rotation has begun.
    private func rotate(_ app: XCUIApplication, to orientation: UIDeviceOrientation) {
        let wantsLandscape = orientation.isLandscape
        XCUIDevice.shared.orientation = orientation

        let settled = expectation(
            for: NSPredicate { [weak self] element, _ in
                guard let self, let element = element as? XCUIElement else { return false }
                let window = self.mainWindow(app)
                guard window.width > 0, (window.width > window.height) == wantsLandscape else {
                    return false
                }
                let frame = element.frame
                return frame.height > 0 && window.contains(frame)
            },
            evaluatedWith: app.buttons["Play or pause"]
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [settled], timeout: 10),
            .completed,
            "the rotation to \(orientation.rawValue) never settled inside \(mainWindow(app))"
        )
    }

    /// The band's height, from two independent real frames plus the two literals
    /// the views themselves declare.
    ///
    /// The scrubber's row top cannot be read off the slider: `TimelineScrubber`
    /// frames itself at 44pt but the slider *draws* over about 31pt and is
    /// centred, so the row top is `midY - 22`. The bar's bottom is the lowest
    /// control's `maxY` plus its own 8pt of padding. Neither constant is a fudge
    /// factor: both appear verbatim in the views under test.
    private func bandHeight(_ app: XCUIApplication) -> CGFloat {
        let slider = app.sliders["Viewer timeline"].frame
        let rowTop = slider.midY - Self.scrubberRowHeight / 2
        let lowest = Self.barButtonLabels
            .map { app.buttons[$0].frame.maxY }
            .max() ?? 0
        return (lowest + Self.barVerticalPadding) - rowTop
    }

    /// Nothing the viewer draws may fall outside the window. Checked over every
    /// button, slider and text in the tree rather than a named list: the failure
    /// this guards is a control pushed off an edge, and naming the controls in
    /// advance is exactly how a newly-added one escapes the check.
    ///
    /// Zero-sized elements are skipped — the accessibility tree carries a few
    /// placeholder entries with empty frames that are not drawn at all.
    private func assertNothingIsClipped(_ app: XCUIApplication) {
        let window = mainWindow(app)
        XCTAssertGreaterThan(window.width, 0, "no window to measure against")

        let elements = app.buttons.allElementsBoundByIndex
            + app.sliders.allElementsBoundByIndex
            + app.staticTexts.allElementsBoundByIndex
        var checked = 0
        for element in elements {
            let frame = element.frame
            guard frame.width > 0, frame.height > 0 else { continue }
            checked += 1
            XCTAssertTrue(
                window.contains(frame),
                "'\(element.label)' is clipped: \(frame) outside \(window)"
            )
        }
        XCTAssertGreaterThan(
            checked,
            Self.barButtonLabels.count,
            "the containment check found almost nothing to check, so it proves nothing"
        )
    }

    /// The app can report more than one window, and the extra one has a zero
    /// frame — `app.windows.firstMatch` returned `(0, 0, 0, 0)` on an 11-inch,
    /// which would make every containment assertion below vacuously false. The
    /// largest window is the scene.
    private func mainWindow(_ app: XCUIApplication) -> CGRect {
        app.windows.allElementsBoundByIndex
            .map(\.frame)
            .max(by: { $0.width * $0.height < $1.width * $1.height }) ?? .zero
    }

    /// Whether two controls are on the same row of the bar, which is how the
    /// wrap is observed from outside: `ViewThatFits` picks the stacked layout
    /// below the bar's ideal width, and the only visible consequence is that the
    /// transport and the clip stepping stop sharing a vertical band.
    private func sharesARow(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minY < b.maxY && b.minY < a.maxY
    }

    // MARK: - Elements

    private func statusChip(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Status: '")).firstMatch
    }

    private func caption(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Clip '")).firstMatch
    }

    private func waitForCaption(_ app: XCUIApplication, _ expected: String) -> Bool {
        wait(app.staticTexts[expected])
    }

    private func waitForStatus(_ app: XCUIApplication, _ expected: String) -> Bool {
        wait(app.staticTexts[expected])
    }

    private func wait(_ element: XCUIElement) -> Bool {
        element.waitForExistence(timeout: 10)
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
