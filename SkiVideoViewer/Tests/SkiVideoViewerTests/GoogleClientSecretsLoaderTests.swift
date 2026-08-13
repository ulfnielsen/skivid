import XCTest
@testable import SkiVideoCore
@testable import SkiVideoViewer

/// `GoogleClientSecretsLoader` reads the Desktop OAuth client
/// `upload_to_drive.py` already uses so a developer running this app from a
/// checkout with that file present gets a working "Sign in with Google"
/// without editing source — and so the sheet can say plainly why it cannot,
/// rather than offering a button that silently fails.
///
/// Every case here injects both the environment and the search directory:
/// the loader must never touch the real `~/Ski/script`, the network, or the
/// Keychain from a test.
final class GoogleClientSecretsLoaderTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoogleClientSecretsLoaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        try super.tearDownWithError()
    }

    private func write(_ json: String, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func clientSecretsJSON(clientID: String, clientSecret: String) -> String {
        """
        {"installed":{"client_id":"\(clientID)","client_secret":"\(clientSecret)",\
        "auth_uri":"https://accounts.google.com/o/oauth2/auth",\
        "token_uri":"https://oauth2.googleapis.com/token",\
        "redirect_uris":["http://localhost"]}}
        """
    }

    /// Fails if the loader ignores the directory search entirely (always nil)
    /// or if it returns *a* configuration without actually decoding the
    /// file's own id — a loader that fabricated or hardcoded a client id
    /// would pass a weaker assertion but not this one.
    func testADirectoryWithAClientSecretsFileYieldsAConfigurationWithThatFilesClientID() throws {
        _ = try write(
            clientSecretsJSON(clientID: "dir-client-id.apps.googleusercontent.com", clientSecret: "dir-secret"),
            named: "client_secret_dir.apps.googleusercontent.com.json",
            in: tempDirectory
        )

        let configuration = GoogleClientSecretsLoader.load(environment: [:], directory: tempDirectory)

        let unwrapped = try XCTUnwrap(configuration)
        XCTAssertEqual(unwrapped.clientID, "dir-client-id.apps.googleusercontent.com")
        XCTAssertEqual(unwrapped.clientSecret, "dir-secret")
    }

    /// Two different client ids, not one reused for both files — a loader
    /// that always preferred the directory (or always preferred the
    /// environment variable by coincidence of file order) would still pass a
    /// fixture where both files carried the same id.
    func testTheEnvironmentVariableTakesPrecedenceOverTheDirectorySearch() throws {
        _ = try write(
            clientSecretsJSON(clientID: "dir-client-id.apps.googleusercontent.com", clientSecret: "dir-secret"),
            named: "client_secret_dir.apps.googleusercontent.com.json",
            in: tempDirectory
        )
        let envFileDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoogleClientSecretsLoaderTests-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: envFileDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: envFileDirectory) }
        let envFile = try write(
            clientSecretsJSON(clientID: "env-client-id.apps.googleusercontent.com", clientSecret: "env-secret"),
            named: "client_secret_env.apps.googleusercontent.com.json",
            in: envFileDirectory
        )

        let configuration = GoogleClientSecretsLoader.load(
            environment: [GoogleClientSecretsLoader.environmentVariable: envFile.path],
            directory: tempDirectory
        )

        let unwrapped = try XCTUnwrap(configuration)
        XCTAssertEqual(unwrapped.clientID, "env-client-id.apps.googleusercontent.com")
    }

    /// Fails if the loader falls back to some non-nil default (a placeholder,
    /// for instance) instead of reporting that nothing was found.
    func testAnEmptyDirectoryWithNoEnvironmentVariableYieldsNil() {
        let configuration = GoogleClientSecretsLoader.load(environment: [:], directory: tempDirectory)

        XCTAssertNil(configuration)
    }

    /// Fails if the loader force-unwraps or otherwise traps on undecodable
    /// JSON instead of treating it the same as "nothing found".
    func testAMalformedJSONFileYieldsNilRatherThanCrashing() throws {
        _ = try write(
            "{ this is not valid json",
            named: "client_secret_broken.apps.googleusercontent.com.json",
            in: tempDirectory
        )

        let configuration = GoogleClientSecretsLoader.load(environment: [:], directory: tempDirectory)

        XCTAssertNil(configuration)
    }
}
