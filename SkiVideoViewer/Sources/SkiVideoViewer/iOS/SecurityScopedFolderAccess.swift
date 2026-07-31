import Foundation

/// A document-picker URL is only readable between
/// `startAccessingSecurityScopedResource()` and `stopAccessing...`. Child URLs
/// produced by `FileManager.enumerator` inherit the parent's scope, so
/// `VideoLibrary.scan` needs no change.
///
/// Scopes are held for the lifetime of the picker — that is, the whole session
/// — and released together in `deinit`. Nothing is released when a new folder
/// is picked, because the picked folder is not yet known to be the one the app
/// ends up showing. Releasing eagerly made a working library silently
/// unreadable in two ways:
///
/// - the new folder's `startAccessing...` fails, `pickFolder` reports a
///   cancel, and `ViewerModel` correctly keeps showing the old folder — whose
///   scope has just been dropped;
/// - the new folder succeeds but has no videos, so `ViewerModel.openDirectory`
///   throws, sets `errorMessage` and never reassigns `directory`. The user
///   dismisses the alert expecting to be back in the old folder, which is
///   still listed and no longer readable.
///
/// Holding every scope also means a second `pickFolder` caller needs no
/// special handling: `SortingModel.chooseSourceDirectory` can pick a source
/// folder while the library folder stays readable, so making Sort reachable on
/// iPad requires no change here.
///
/// The cost is a handful of sandbox extensions held until the app exits, which
/// is what a document-based app does anyway.
///
/// Not unit-tested: `startAccessingSecurityScopedResource()` returns false for
/// any URL that did not come from a document picker or a security-scoped
/// bookmark, so an off-device test could only assert the failure path. There
/// is also no test target that reaches this file — `Package.swift` excludes
/// `Sources/SkiVideoViewer/iOS` and the iOS test scheme covers `SkiVideoCore`
/// only. Task 6's simulator run is what exercises this.
final class SecurityScopedFolderAccess {
    private var scopes: Set<URL> = []

    /// Acquires access to `url` and keeps it for the session. Returns false
    /// only when the system refuses the scope, in which case nothing is
    /// recorded and no previously held scope is disturbed. Callers must treat
    /// false as a failed pick: the URL is not readable, so handing it to
    /// `ViewerModel` would produce an empty library rather than an error.
    ///
    /// Re-picking a folder already held is a success that acquires nothing.
    /// `startAccessingSecurityScopedResource()` is reference-counted, so
    /// acquiring twice against a single release in `end` would leak a sandbox
    /// extension.
    @discardableResult
    func begin(_ url: URL) -> Bool {
        guard !scopes.contains(url) else { return true }
        guard url.startAccessingSecurityScopedResource() else { return false }
        scopes.insert(url)
        return true
    }

    /// Releases every held scope exactly once. Only `deinit` calls this — a
    /// mid-session release is the bug this type exists to avoid.
    func end() {
        for url in scopes {
            url.stopAccessingSecurityScopedResource()
        }
        scopes.removeAll()
    }

    deinit {
        end()
    }
}
