import XCTest
@testable import SkiVideoCore

final class IOSRedirectTests: XCTestCase {
    /// An iOS client's redirect is its client id reversed, and Google matches
    /// it exactly. Built from the id rather than written out twice, so the two
    /// cannot drift.
    ///
    /// Fails if the reversal is wrong or the path is dropped — asserted on the
    /// whole string, not on a prefix.
    func testTheRedirectIsTheReversedClientIDWithACallbackPath() {
        let configuration = GoogleOAuthConfiguration(
            clientID: "123-abc.apps.googleusercontent.com",
            clientSecret: nil,
            redirectKind: .customScheme("com.googleusercontent.apps.123-abc")
        )
        XCTAssertEqual(
            GoogleOAuth.redirectURI(for: configuration),
            "com.googleusercontent.apps.123-abc:/oauth2redirect"
        )
    }

    /// macOS keeps the loopback form. Loopback is blocked for iOS clients and
    /// a custom scheme is not offered to Desktop clients, so the two platforms
    /// genuinely differ and this pins that they do.
    func testALoopbackConfigurationStillProducesALoopbackRedirect() {
        let configuration = GoogleOAuthConfiguration(
            clientID: "123.apps.googleusercontent.com",
            clientSecret: "shh",
            redirectKind: .loopback
        )
        XCTAssertTrue(
            GoogleOAuth.redirectURI(for: configuration).hasPrefix("http://127.0.0.1"),
            "got \(GoogleOAuth.redirectURI(for: configuration))"
        )
    }

    /// The scheme the app registers must be the one the flow asks Google to
    /// redirect to. These are declared in two different files — `iPad-Info.plist`
    /// (not `project.yml`: `CFBundleURLTypes` is an array of dictionaries, and
    /// project.yml's target settings are flat build-setting values with no
    /// `INFOPLIST_KEY_*` form for it, so it is registered in the partial
    /// Info.plist `INFOPLIST_FILE` merges in — see that file's own comment)
    /// and `IOSOAuthPresenter.callbackScheme` — and nothing but this test
    /// connects them.
    ///
    /// Cannot reach `IOSOAuthPresenter` by importing it: `Package.swift`
    /// excludes all of `Sources/SkiVideoViewer/iOS` from every SwiftPM target
    /// (UIKitFolderPicker.swift documents the same fact), so no test target —
    /// this one included — ever compiles that directory. Reading the
    /// declaration out of the source file as text is the only way this test
    /// can see the value at all, so a rename of the property or a change to
    /// how its value is written fails this test loudly rather than silently
    /// stops checking anything.
    func testTheRegisteredSchemeMatchesTheConfiguredOne() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/SkiVideoViewerTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // SkiVideoViewer/

        let presenterURL = packageRoot
            .appendingPathComponent("Sources/SkiVideoViewer/iOS/IOSOAuthPresenter.swift")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: presenterURL.path),
            "expected IOSOAuthPresenter.swift at \(presenterURL.path); adjust the " +
                "deletingLastPathComponent() count above if IOSRedirectTests.swift has moved"
        )
        let presenterSource = try String(contentsOf: presenterURL, encoding: .utf8)
        guard let declarationRange = presenterSource.range(
            of: #"callbackScheme\s*=\s*"([^"]+)""#,
            options: .regularExpression
        ) else {
            return XCTFail("could not find a `callbackScheme = \"...\"` declaration in \(presenterURL.path)")
        }
        let declaration = presenterSource[declarationRange]
        guard let quotedRange = declaration.range(of: #""[^"]+""#, options: .regularExpression) else {
            return XCTFail("could not extract a quoted string from: \(declaration)")
        }
        let scheme = declaration[quotedRange].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        XCTAssertFalse(scheme.isEmpty, "extracted an empty scheme from: \(declaration)")

        let infoPlistURL = packageRoot.appendingPathComponent("iPad-Info.plist")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: infoPlistURL.path),
            "expected iPad-Info.plist at \(infoPlistURL.path)"
        )
        let infoPlist = try String(contentsOf: infoPlistURL, encoding: .utf8)
        XCTAssertTrue(
            infoPlist.contains(scheme),
            "iPad-Info.plist does not register \(scheme); a redirect Google accepts would never reach the app"
        )
    }
}
