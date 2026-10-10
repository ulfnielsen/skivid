import XCTest

/// From Photos to the club Drive, on a phone, end to end: pick, tag, finish,
/// upload — and nothing goes up twice.
///
/// Neither end is real. The Photos picker runs out of process and XCUITest
/// cannot drive it, and a test must never write to the club's Drive. The app's
/// DEBUG-only `UITestPhotosToDriveSeam` (launch argument
/// `-SkiUITestPhotosToDrive`) stands in for both: "From Photos…" hands over
/// this bundle's fixture movie under Photos-style names through the real
/// `PhotosClipExporter`, and an in-memory Drive is signed in and opened as a
/// library laid out event → athlete. Everything between — the sorting screen,
/// tagging, the resize, `uploadTarget()`, the batch, the tray — is the app's
/// own code. What the fake Drive received is read back off an on-screen
/// readout the seam adds (`uitest.fakeDrive.uploads`), its value the uploaded
/// paths.
///
/// Every wait has a timeout. Task 4's version of this walk sat 2h50m in one
/// wait. Its cause is unproven. The most likely one is the container
/// accessibility-identifier override — an identifier set on a container
/// standing in for the identifiers inside it, so the element being waited for
/// never appeared — together with a wait that had no bound. The containers
/// now use `.accessibilityElement(children: .contain)` and every wait here is
/// bounded, so whatever it was, a recurrence fails instead of hanging.
///
///     export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
///     xcodebuild -scheme SkiVideoViewer-iPad \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///       -only-testing:SkiVideoViewer-iPadUITests/PhotosToDriveUITests test
final class PhotosToDriveUITests: XCTestCase {
    /// The fixed capture date the seam gives every pick (2026-02-14) and the
    /// title typed below make the event folder.
    private let event = "2026-02-14_Hoch-Ybrig"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testPhotosPicksAreTaggedAndUploadedToTheClubDriveOnce() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .phone,
            "this is the phone flow; the iPad's sorting screen is a different layout"
        )
        let fixture = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "supported-420-8bit", withExtension: "mp4"),
            "the fixture movie must be in the UI-test bundle"
        )

        let app = XCUIApplication()
        app.launchArguments = ["-SkiUITestPhotosToDrive"]
        app.launchEnvironment = [
            "SKI_UITEST_FIXTURE_MOVIE": fixture.path,
            "SKI_UITEST_PICKS": "IMG_0101,IMG_0102",
        ]
        app.launch()

        // The seam opens the fake Drive, which pushes its athletes; one more
        // tap reaches the viewer, whose toolbar carries Sort & Resize.
        let athlete = app.buttons["sidebar.athlete.Seed Athlete"]
        XCTAssertTrue(athlete.waitForExistence(timeout: 60),
                      "the fake Drive library must open; buttons were \(labels(app.buttons))")
        athlete.tap()

        let sort = app.buttons["Sort & Resize…"]
        if !sort.waitForExistence(timeout: 20) {
            let more = app.buttons["More"]
            XCTAssertTrue(more.waitForExistence(timeout: 10), "no Sort & Resize, and no overflow to look in")
            more.tap()
        }
        XCTAssertTrue(sort.waitForExistence(timeout: 10), "sorting must be reachable from the viewer")
        sort.tap()

        // Upload is offered before any tagging — the library resolved.
        XCTAssertTrue(
            app.staticTexts["When tagging is done, the clips can be uploaded to UI Test Club Drive."]
                .waitForExistence(timeout: 20),
            "the setup screen must say uploading is available; texts were \(labels(app.staticTexts))"
        )

        let fromPhotos = app.buttons["sorting.chooseFromPhotos"]
        XCTAssertTrue(fromPhotos.waitForExistence(timeout: 10), "a phone must offer From Photos…")
        fromPhotos.tap()

        let source = app.textFields["Choose a source folder…"]
        XCTAssertTrue(
            waitUntil(timeout: 30) { (source.value as? String)?.contains("PhotosPicks") == true },
            "the picks must become the source; the field reads \(String(describing: source.value))"
        )

        let title = app.textFields["e.g. Neuss"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        title.typeText("Hoch-Ybrig")

        let start = app.buttons["Start Tagging"]
        XCTAssertTrue(waitUntil(timeout: 10) { start.isEnabled }, "Start Tagging must enable")
        start.tap()

        tag(as: "Anna Muster", in: app)
        tag(as: "Bo Beispiel", in: app)

        // The finished-tagging tray: exactly this session's two clips.
        let upload = app.buttons["upload.start"]
        XCTAssertTrue(upload.waitForExistence(timeout: 120),
                      "the tray must appear once the resizes land; texts were \(labels(app.staticTexts))")
        XCTAssertTrue(waitUntil(timeout: 30) { upload.label == "Upload 2 clips to UI Test Club Drive" },
                      "the tray must offer exactly the two tagged clips; it says \(upload.label)")
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'upload.row.'"))
        XCTAssertEqual(Set(rows.allElementsBoundByIndex.map(\.identifier)),
                       ["upload.row.IMG_0101.mp4", "upload.row.IMG_0102.mp4"])
        add(screenshot(of: app, named: "01-tray-before-upload"))

        let readout = app.staticTexts["uitest.fakeDrive.uploads"]
        XCTAssertTrue(readout.exists, "the seam's readout of the fake Drive must be on screen")
        XCTAssertEqual(readout.label, "Fake Drive uploads: 0", "nothing may upload before the coach asks")

        upload.tap()

        for name in ["IMG_0101.mp4", "IMG_0102.mp4"] {
            let state = app.staticTexts["upload.state.\(name)"]
            XCTAssertTrue(waitUntil(timeout: 60) { state.exists && state.label == "Uploaded" },
                          "\(name) must reach Uploaded; it reads \(state.exists ? state.label : "nothing")")
        }
        XCTAssertTrue(waitUntil(timeout: 10) { upload.label == "Nothing waiting to upload" && !upload.isEnabled })
        add(screenshot(of: app, named: "02-tray-uploaded"))

        // Each clip in its own folder, by the library's event → athlete layout.
        XCTAssertEqual(readout.label, "Fake Drive uploads: 2")
        XCTAssertEqual(
            (readout.value as? String)?.split(separator: "\n").map(String.init).sorted(),
            ["\(event)/Anna Muster/IMG_0101.mp4", "\(event)/Bo Beispiel/IMG_0102.mp4"]
        )

        // Again, from the setup screen's whole-history tray: a tray rebuilt
        // from disk asks Drive, finds both there, and offers nothing.
        app.buttons["Close"].tap()
        XCTAssertTrue(sort.waitForExistence(timeout: 20))
        sort.tap()
        let history = app.buttons["sorting.showUploadTray"]
        XCTAssertTrue(history.waitForExistence(timeout: 20), "the setup screen must offer Clips waiting to upload…")
        history.tap()
        for name in ["IMG_0101.mp4", "IMG_0102.mp4"] {
            let state = app.staticTexts["upload.state.\(name)"]
            XCTAssertTrue(waitUntil(timeout: 30) { state.exists && state.label == "In Drive" },
                          "\(name) is in Drive and must say so; it reads \(state.exists ? state.label : "nothing")")
        }
        let again = app.buttons["upload.start"]
        XCTAssertEqual(again.label, "Nothing waiting to upload")
        XCTAssertFalse(again.isEnabled, "nothing already in Drive may be offered for upload")
        add(screenshot(of: app, named: "03-history-tray-in-drive"))
        XCTAssertEqual(app.staticTexts["uitest.fakeDrive.uploads"].label, "Fake Drive uploads: 2",
                       "nothing may upload twice")
    }

    /// Types a new athlete's name for the clip on screen and tags it.
    private func tag(as athlete: String, in app: XCUIApplication) {
        let field = app.textFields["Type athlete name"]
        XCTAssertTrue(field.waitForExistence(timeout: 60), "a clip must be up for tagging")
        field.tap()
        field.typeText(athlete)
        let add = app.buttons["Add “\(athlete)” & Tag"]
        XCTAssertTrue(add.waitForExistence(timeout: 10),
                      "a new name must be offered for adding; buttons were \(labels(app.buttons))")
        add.tap()
    }

    /// Polls rather than relying on one query: a bounded wait that fails fast.
    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let predicate = NSPredicate { _, _ in condition() }
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: nil)], timeout: timeout) == .completed
    }

    private func labels(_ query: XCUIElementQuery) -> [String] {
        query.allElementsBoundByIndex.prefix(30).map(\.label)
    }

    private func screenshot(of app: XCUIApplication, named name: String) -> XCTAttachment {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}
