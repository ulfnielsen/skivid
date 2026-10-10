import Foundation

/// Which Drive library a sorting session uploads to — chosen on the sorting
/// screen itself, so sorting can start from the libraries list with nothing
/// open.
///
/// **Choosing a library opens it.** An upload needs more than a root id: the
/// folder layout and a known folder for the batch's safety probe both come
/// from the opened library's index (`ViewerModel.uploadTarget()`), and the
/// tagging screen's athlete suggestions come from its roster. Opening is the
/// one path that produces all three, so the choice goes through it rather
/// than assembling a second, partial version.
///
/// Built from closures, not a `ViewerModel`, for the reason
/// `SecondaryScreenPresenter` gives: the sorting screen and both window
/// controllers never learn what a `ViewerModel` is.
@MainActor
public final class UploadLibraryChoice: ObservableObject {

    public struct Option: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let name: String
    }

    /// The Drive libraries, most recently opened first. Folders are left out:
    /// they cannot take an upload (`UploadRefusal.libraryIsAFolder`).
    public let options: [Option]
    /// Nil is "don't upload": the clips stay sorted on this device.
    @Published public private(set) var selection: UUID?
    @Published public private(set) var isOpening = false
    /// Why the chosen library did not open, in the words `ViewerModel.open`
    /// returned. Shown under the picker, not as an alert.
    @Published public private(set) var failure: String?
    /// Nil while nothing is chosen, while it opens, or when it failed to open.
    @Published public private(set) var upload: Result<UploadTarget, UploadRefusal>?
    /// The roster of what is open now, for the tagging screen's suggestions.
    @Published public private(set) var athletes: [AthleteGroup]

    private let libraries: [Library]
    private var openLibraryID: UUID?
    private let open: (Library) async -> String?
    private let current: () -> (upload: Result<UploadTarget, UploadRefusal>, athletes: [AthleteGroup])
    /// Bumped on every choice, so an open that finishes after the coach has
    /// already chosen something else cannot overwrite the newer choice.
    private var generation = 0

    /// `libraries` in `LibraryStore.all()` order, most recently opened first.
    ///
    /// The starting choice: the open library when it is a Drive; nothing when
    /// it is a folder — choosing a Drive would close the folder the coach is
    /// looking at, which nobody asked for; and with nothing open, the most
    /// recently opened Drive, opened by `start()`.
    public init(
        libraries: [Library],
        openLibraryID: UUID?,
        open: @escaping (Library) async -> String?,
        current: @escaping () -> (upload: Result<UploadTarget, UploadRefusal>, athletes: [AthleteGroup])
    ) {
        self.libraries = libraries
        self.openLibraryID = openLibraryID
        self.open = open
        self.current = current
        let drives = libraries.filter {
            if case .drive = $0.kind { return true } else { return false }
        }
        options = drives.map { Option(id: $0.id, name: $0.name) }
        if let openLibraryID {
            selection = drives.contains { $0.id == openLibraryID } ? openLibraryID : nil
        } else {
            selection = drives.first?.id
        }
        let snapshot = current()
        athletes = snapshot.athletes
        if selection != nil, selection == openLibraryID {
            upload = snapshot.upload
        }
    }

    /// Opens the starting choice when it is not already open. Called once, as
    /// the screen appears.
    public func start() async {
        guard let selection, selection != openLibraryID else { return }
        await choose(selection)
    }

    public func choose(_ id: UUID?) async {
        generation += 1
        let mine = generation
        selection = id
        failure = nil
        guard let id, let library = libraries.first(where: { $0.id == id }) else {
            upload = nil
            isOpening = false
            return
        }
        if id == openLibraryID {
            take(current())
            isOpening = false
            return
        }
        upload = nil
        isOpening = true
        let failed = await open(library)
        guard mine == generation else { return }
        isOpening = false
        if let failed {
            failure = failed
            return
        }
        openLibraryID = id
        take(current())
    }

    private func take(_ snapshot: (upload: Result<UploadTarget, UploadRefusal>, athletes: [AthleteGroup])) {
        upload = snapshot.upload
        athletes = snapshot.athletes
    }
}
