import Foundation
import SkiVideoCore

/// Finds the Desktop OAuth client `upload_to_drive.py` already uses, so a
/// developer running this app from a checkout that has that file present
/// gets a working "Sign in with Google" without editing source.
///
/// Lives in the app target, not `SkiVideoCore`: it reads a developer's home
/// directory, which is not core's business. It sits in `Shared/` rather than
/// `macOS/` because nothing in it touches AppKit or any other macOS-only
/// API — it is plain `Foundation` — so keeping it here needs no
/// `#if os(macOS)` guard at its one call site in `GoogleDriveSheet`, and it
/// costs nothing to let it compile on iOS too: no `client_secret_*.json`
/// exists in an iPad app's sandboxed home directory, so it reports the same
/// honest "not configured" nil there as it would on a Mac with nothing set
/// up, rather than a `Sign in` button dressed up to look like it could work.
///
/// Google issues Desktop clients with a secret and explicitly permits
/// shipping it in an installed app — the confidentiality Google asks OAuth
/// clients to keep does not apply to this client type — so decoding
/// `client_secret` out of the JSON and handing it to
/// `GoogleOAuthConfiguration` is the intended use, not a leak.
enum GoogleClientSecretsLoader {
    /// Google's standard installed-app client-secret JSON shape. Only the
    /// two fields `GoogleOAuthConfiguration` needs are decoded; the file
    /// also carries `project_id`, `auth_uri`, `token_uri`, and
    /// `redirect_uris`, all fixed values `GoogleOAuth` already hardcodes.
    private struct ClientSecretsFile: Decodable {
        struct Installed: Decodable {
            let clientID: String
            let clientSecret: String

            enum CodingKeys: String, CodingKey {
                case clientID = "client_id"
                case clientSecret = "client_secret"
            }
        }

        let installed: Installed
    }

    /// Checked before the directory search. Named in
    /// `missingConfigurationMessage` so a developer without
    /// `~/Ski/script/client_secret_*.json` — anyone whose checkout lives
    /// somewhere else — knows the other way to point this at their file.
    static let environmentVariable = "SKI_GOOGLE_CLIENT_SECRETS"

    /// Where a person should look when `load` returns nil, spelled out so
    /// `GoogleDriveSheet` can put it in front of them directly instead of
    /// showing a button that silently cannot work.
    static var missingConfigurationMessage: String {
        "No Google client secrets found. Set \(environmentVariable) to a client_secret_*.json path, " +
            "or place one in ~/Ski/script."
    }

    /// `environment` and `directory` default to the real environment and
    /// `~/Ski/script`, so the production call site in `GoogleDriveSheet`
    /// names neither; a test supplies both to stay off the developer's real
    /// home directory, matching the seam pattern `GoogleOAuth.authorize`
    /// already uses for `transport` and `tokenStore`.
    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        directory: URL? = defaultSearchDirectory
    ) -> GoogleOAuthConfiguration? {
        let path = environment[environmentVariable]
            ?? directory.flatMap(firstClientSecretsFile(in:))
        guard let path, let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        guard let decoded = try? JSONDecoder().decode(ClientSecretsFile.self, from: data) else {
            return nil
        }
        return GoogleOAuthConfiguration(
            clientID: decoded.installed.clientID,
            clientSecret: decoded.installed.clientSecret,
            redirectKind: .loopback
        )
    }

    /// Where to look when no path is given: `~/Ski/script` on a Mac, and
    /// nowhere at all on iPadOS.
    ///
    /// Nil rather than some iOS equivalent because there is no equivalent:
    /// `homeDirectoryForCurrentUser` does not exist there — this file lives in
    /// `Shared/` and so compiles into the iPad target, where naming it broke
    /// the build outright — and an iPad has no developer home directory to
    /// scan even in principle. The environment variable still works on both,
    /// which is the seam a test uses; the directory scan is a Mac convenience
    /// for the person who has a client-secrets file sitting beside the repo.
    private static var defaultSearchDirectory: URL? {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Ski").appendingPathComponent("script")
        #else
        return nil
        #endif
    }

    /// Sorted so the search is deterministic when a directory somehow holds
    /// more than one match, rather than picking whatever order the
    /// filesystem happened to enumerate them in.
    private static func firstClientSecretsFile(in directory: URL) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        return entries
            .filter { $0.hasPrefix("client_secret_") && $0.hasSuffix(".json") }
            .sorted()
            .first
            .map { directory.appendingPathComponent($0).path }
    }
}
