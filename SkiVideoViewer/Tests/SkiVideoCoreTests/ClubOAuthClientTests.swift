import XCTest
@testable import SkiVideoCore

/// Covers the store that lets a club other than the one this app was written
/// for sign into its own Drive — see
/// `docs/superpowers/specs/2026-08-15-club-supplied-oauth-client-design.md`.
final class ClubOAuthClientTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ClubOAuthClientStore!

    /// A built-in client that is obviously not the club's, so a test asserting
    /// "fell back" cannot pass by accident on a shared value.
    private let builtIn = GoogleOAuthConfiguration(
        clientID: "built-in.apps.googleusercontent.com",
        clientSecret: "desktop-secret",
        redirectKind: .loopback
    )

    private let clubID = "555-club.apps.googleusercontent.com"

    /// One fixed suite for the whole class, **not** a per-test UUID.
    ///
    /// A UUID per test isolates them perfectly and leaves a plist per test in
    /// the developer's real `~/Library/Preferences`: `cfprefsd` flushes the
    /// file asynchronously, so a `tearDown` that removes the domain and unlinks
    /// the file still loses the race, and a first version of this suite left 63
    /// of them behind. A fixed name bounds that at one file, named after this
    /// class, and `setUp` empties it so tests remain independent.
    private static let fixedSuiteName = "ClubOAuthClientTests"

    override func setUp() {
        super.setUp()
        suiteName = Self.fixedSuiteName
        defaults = UserDefaults(suiteName: suiteName)
        // Cleared here rather than trusted from tearDown, so a test that
        // crashed mid-run cannot leak a client id into the next one.
        defaults.removePersistentDomain(forName: suiteName)
        store = ClubOAuthClientStore(defaults: defaults)
    }

    override func tearDown() {
        // Both steps are needed, and finding that out cost a cleanup:
        // `removePersistentDomain` empties the domain but leaves the suite's
        // plist behind in ~/Library/Preferences, so a first version of this
        // file left 63 stray `ClubOAuthClientTests.<uuid>.plist` in the
        // developer's real preferences directory. Deleting the file is what
        // actually leaves nothing behind — the same "check what the test
        // wrote to the real home directory" lesson that stray index files in
        // ~/Library/Application Support taught earlier in this project.
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: Self.preferencesFile(for: suiteName))
        defaults = nil
        store = nil
        suiteName = nil
        super.tearDown()
    }

    /// Where `UserDefaults(suiteName:)` puts a suite's backing plist for a
    /// non-sandboxed test process.
    private static func preferencesFile(for suiteName: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent("\(suiteName).plist")
    }

    // MARK: - Validation

    /// Fails if the suffix check is dropped, which would let the client
    /// *secret* be stored as an id and turn a typo into a
    /// `redirect_uri_mismatch` three screens later.
    func testAStringThatIsNotAClientIDIsRefused() {
        for bad in ["GOCSPX-abc123def456", "1075094033080", "", "   ", ".apps.googleusercontent.com"] {
            XCTAssertThrowsError(try ClubOAuthClientStore.validated(bad), "accepted \"\(bad)\"") { error in
                XCTAssertEqual(error as? ClubOAuthClientError, .notAClientID)
            }
        }
    }

    /// The bare suffix is refused above; this pins that a real id with a
    /// non-empty prefix is *not*, so the length guard cannot be tightened into
    /// rejecting everything and still pass the negative cases.
    func testARealClientIDIsAccepted() throws {
        XCTAssertEqual(try ClubOAuthClientStore.validated(clubID), clubID)
    }

    /// Pasting from a browser or a chat message routinely brings whitespace and
    /// a trailing newline. Fails if `save` stores the raw string, in which case
    /// the id reaches Google with a leading space and is rejected.
    func testAPastedIDIsTrimmedBeforeItIsStored() throws {
        try store.save("  \(clubID)\n")
        XCTAssertEqual(store.clientID, clubID)
    }

    // MARK: - Which client sign-in uses

    /// Fails if `configuration` ignores the stored id — the whole feature.
    func testASavedClubIDIsWhatSignInWouldUse() throws {
        try store.save(clubID)
        let configuration = try XCTUnwrap(store.configuration(fallingBackTo: builtIn))

        XCTAssertEqual(configuration.clientID, clubID)
        // Google issues an iOS client no secret, and sending an empty one is
        // rejected — so this must be nil, not "".
        XCTAssertNil(configuration.clientSecret)
        XCTAssertEqual(
            schemeOf(configuration.redirectKind),
            ClubOAuthClientStore.redirectScheme,
            "a club client must redirect through the one scheme both apps register"
        )
    }

    /// The other direction, and the reason both are here: a `configuration`
    /// that always returned the fallback would pass a club-id test that only
    /// checked for non-nil, and one that never fell back would pass this
    /// suite's other half. Asserting only one direction pins neither.
    func testWithNothingConfiguredTheBuiltInClientIsUsed() throws {
        let configuration = try XCTUnwrap(store.configuration(fallingBackTo: builtIn))

        XCTAssertEqual(configuration.clientID, builtIn.clientID)
        XCTAssertEqual(configuration.clientSecret, builtIn.clientSecret)
        XCTAssertNil(
            schemeOf(configuration.redirectKind),
            "the built-in Mac client is a Desktop client and must keep its loopback redirect"
        )
    }

    /// Fails if `clear` writes an empty string instead of removing the key, in
    /// which case the club would be left with a client id of "" rather than
    /// back on the built-in one.
    func testClearingRestoresTheBuiltInClient() throws {
        try store.save(clubID)
        store.clear()

        XCTAssertNil(store.clientID)
        XCTAssertEqual(store.configuration(fallingBackTo: builtIn)?.clientID, builtIn.clientID)
    }

    /// Fails if `save` writes before validating. A club that mistypes over a
    /// working id would otherwise be signed out by the typo.
    func testARejectedPasteLeavesThePreviousIDIntact() throws {
        try store.save(clubID)
        XCTAssertThrowsError(try store.save("GOCSPX-not-an-id"))
        XCTAssertEqual(store.clientID, clubID)
    }

    /// Fails if the id is held in memory rather than written to defaults — in
    /// which case setup would appear to work and be gone at the next launch.
    /// A second store on the same defaults stands in for the relaunch, since
    /// nothing in `ClubOAuthClientStore` caches across instances.
    func testASavedIDSurvivesRelaunch() throws {
        try store.save(clubID)
        let afterRelaunch = ClubOAuthClientStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        XCTAssertEqual(afterRelaunch.clientID, clubID)
    }

    /// A value written by an older build or by `defaults write` has not been
    /// through `save`. Fails if `clientID` returns the raw string, which would
    /// send a padded id to Google.
    func testAnUntrimmedValueAlreadyInDefaultsIsStillReadCleanly() {
        defaults.set("  \(clubID)  ", forKey: ClubOAuthClientStore.defaultsKey)
        XCTAssertEqual(store.clientID, clubID)
    }

    /// Whitespace-only is indistinguishable from unconfigured, and must fall
    /// back rather than ask Google to authorize a blank client.
    func testAWhitespaceOnlyValueCountsAsUnconfigured() {
        defaults.set("   \n", forKey: ClubOAuthClientStore.defaultsKey)
        XCTAssertNil(store.clientID)
        XCTAssertEqual(store.configuration(fallingBackTo: builtIn)?.clientID, builtIn.clientID)
    }

    // MARK: - The scheme both apps must register

    /// The scheme the flow asks Google to redirect to has to be one the app
    /// actually receives, and those are declared in different files that
    /// nothing but this test connects — the same gap `IOSRedirectTests` covers
    /// for the built-in client.
    ///
    /// Fails if `redirectScheme` is changed without updating both plists, in
    /// which case every club-supplied sign-in would hand off to Google and
    /// never come back.
    ///
    /// Parses the plist rather than searching it as text, and that is not
    /// fastidiousness — a text search was written first and **could not fail**.
    /// The Mac bundle's `CFBundleIdentifier` is `dk.dyregod.video-viewer`, the same
    /// string as the scheme, so `contents.contains(...)` stayed true after the
    /// URL scheme was deleted outright. Deleting it is now caught because the
    /// assertion reaches into `CFBundleURLTypes` specifically.
    func testBothAppsRegisterTheClubRedirectScheme() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/SkiVideoCoreTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // SkiVideoViewer/

        for relativePath in ["iPad-Info.plist", "AppBundle/Info.plist"] {
            let url = repositoryRoot.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return XCTFail(
                    "expected \(relativePath) at \(url.path); adjust the "
                        + "deletingLastPathComponent() count above if this test file has moved"
                )
            }
            let parsed = try PropertyListSerialization.propertyList(
                from: try Data(contentsOf: url),
                options: [],
                format: nil
            )
            let urlTypes = (parsed as? [String: Any])?["CFBundleURLTypes"] as? [[String: Any]]
            let schemes = (urlTypes ?? []).flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }

            XCTAssertTrue(
                schemes.contains(ClubOAuthClientStore.redirectScheme),
                "\(relativePath) registers \(schemes) under CFBundleURLTypes, which does not "
                    + "include \(ClubOAuthClientStore.redirectScheme); a club-supplied sign-in "
                    + "would redirect to a scheme the app never receives"
            )
        }
    }

    /// `GoogleRedirectKind` carries an associated value and is not `Equatable`,
    /// so tests reach the scheme through this rather than through a `case` in
    /// each one. Nil for `.loopback`.
    private func schemeOf(_ kind: GoogleRedirectKind) -> String? {
        if case .customScheme(let scheme) = kind { return scheme }
        return nil
    }
}
