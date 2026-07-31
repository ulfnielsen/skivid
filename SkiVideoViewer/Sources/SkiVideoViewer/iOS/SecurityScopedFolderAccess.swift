import Foundation

/// A document-picker URL is only readable between
/// `startAccessingSecurityScopedResource()` and `stopAccessing...`. The
/// viewer keeps one folder open for the whole session, so this holds exactly
/// one scope and releases the previous one when a new folder is picked.
/// Child URLs produced by `FileManager.enumerator` inherit the parent's scope,
/// so `VideoLibrary.scan` needs no change.
///
/// One scope is enough only while `ViewerModel.chooseDirectory` is the sole
/// reachable folder pick on iPad. `SortingModel.chooseSourceDirectory` also
/// picks a folder, but Sort is hidden there — `NoSecondaryScreenPresenter`
/// reports `canPresent == false` — so two folders are never open at once.
/// Whoever makes Sort reachable on iPad has to give it its own scope, because
/// `begin` releasing the previous folder would make the open library
/// unreadable.
///
/// Not unit-tested: `startAccessingSecurityScopedResource()` returns false for
/// any URL that did not come from a document picker or a security-scoped
/// bookmark, so an off-device test could only assert the failure path. There
/// is also no test target that reaches this file — `Package.swift` excludes
/// `Sources/SkiVideoViewer/iOS` and the iOS test scheme covers `SkiVideoCore`
/// only. Task 6's simulator run is what exercises this.
final class SecurityScopedFolderAccess {
    private(set) var current: URL?

    /// Returns false when the system refuses the scope, in which case nothing
    /// is recorded and `end` stays balanced. Callers must treat false as a
    /// failed pick: the URL is not readable, so handing it to `ViewerModel`
    /// would only produce an empty library.
    @discardableResult
    func begin(_ url: URL) -> Bool {
        end()
        guard url.startAccessingSecurityScopedResource() else { return false }
        current = url
        return true
    }

    func end() {
        current?.stopAccessingSecurityScopedResource()
        current = nil
    }

    deinit {
        end()
    }
}
