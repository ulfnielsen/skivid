import AVFoundation
import Foundation

/// Platform-agnostic playback state. Everything platform-specific reaches it
/// through the seams in `Seams.swift`, so the same model backs the macOS app
/// and, in phase 2, an iPadOS one.
///
/// Access levels are deliberately narrow: `public` marks exactly what the app
/// target's views and `App` struct touch. Members used only by tests stay
/// internal and are reached with `@testable import SkiVideoCore`.
@MainActor
public final class ViewerModel: ObservableObject {
    @Published public private(set) var directory: URL?
    @Published public private(set) var athletes: [AthleteGroup] = []
    @Published public var selectedAthleteID: String?
    @Published public var athleteQuery = ""
    /// Which dimension heads the sidebar — a coach's preference, restored
    /// from `UserDefaults` on launch and applied to whichever library is
    /// open, local or remote. Changing it re-orders `athletes` in place —
    /// `LibraryGrouping.order(_:by:)` never re-folds the library — so every
    /// row keeps its id and a selection survives the pivot.
    @Published public var sidebarGrouping: SidebarGrouping = ViewerModel.loadSidebarGrouping() {
        didSet {
            guard oldValue != sidebarGrouping else { return }
            Self.defaults.set(sidebarGrouping.rawValue, forKey: Self.sidebarGroupingDefaultsKey)
            athletes = LibraryGrouping.order(athletes, by: sidebarGrouping)
        }
    }
    /// Internal: no view reads it, but the intent tests assert on it.
    @Published private(set) var videoIndex = 0
    @Published public private(set) var status = "Choose an organized video directory"
    @Published public var errorMessage: String?
    /// Position and length of the current clip, for the scrubber and the time
    /// readout. Published for the same reason `ComparisonModel` publishes its
    /// pair: `AVPlayer` reports neither, so a view that wants them has to be
    /// told.
    @Published public private(set) var currentTime = 0.0
    @Published public private(set) var duration = 0.0
    /// Whether the player is actually moving. Derived from the player by KVO —
    /// see `startObservingRate` — not written by hand at each call site, because
    /// there are several of those (`togglePlayback`, `applyTransport`'s `.slow`,
    /// `SlowMotionHold.begin`/`.end` and `loadCurrentVideo`) and another is one
    /// refactor away.
    ///
    /// `ContentView` uses it to give up the athlete-search field's focus once
    /// the operator starts watching, so Space reaches the transport instead of
    /// being typed into the field.
    @Published public private(set) var isPlaying = false

    /// How far into the current clip the operator has zoomed.
    ///
    /// Kept across clip and athlete changes — watching several runs of one
    /// drill at a fixed magnification is what the control is for — and reset in
    /// `openDirectory`/`openRemoteLibrary`, where a pan into one library's
    /// corner says nothing about another's.
    @Published public private(set) var zoom = VideoZoom()

    public let player = AVPlayer()

    /// The cloud library, when one is open. Nil for a local folder.
    private var remoteIndex: RemoteLibraryIndex?
    private var remoteProvider: (any RemoteLibraryProvider)?
    private var clipCache: ClipCache?

    @Published public private(set) var isUsingRemoteLibrary = false
    /// The drives sign-in found, or empty before signing in and after a
    /// failure. The sheet shows a button while this is empty and a list once
    /// it is not, so the two states need no separate flag.
    @Published public private(set) var availableRoots: [RemoteFolder] = []
    /// Why the last sign-in failed, for the sheet to show inline. Nil clears
    /// it on the next attempt.
    @Published public private(set) var signInError: String?

    /// Set when the current clip's video track cannot be decoded here — the
    /// symptom is audio with a blank frame, which otherwise looks like the
    /// fetch failed. Nil for every clip that plays.
    @Published public private(set) var unsupportedFormatMessage: String?
    /// True while any clip's bytes are being fetched. No view reads this
    /// yet — plan 3 is what puts a spinner on screen instead of an empty
    /// player — but the flag and the counter behind it are exercised by
    /// `testIsPreparingClipStaysTrueUntilBothOverlappingFetchesFinish`.
    @Published public private(set) var isPreparingClip = false
    /// How many fetches are in flight. A count rather than a bare flag:
    /// with two overlapping fetches — a coach reselecting while the first is
    /// still downloading, which is exactly what plan 3's fetch-on-select
    /// produces — whichever finished first would clear the flag while the
    /// other was still running, showing neither a spinner nor a clip.
    private var preparingCount = 0

    /// The current clip's own fetch — one `Task` per call to `changeVideo`,
    /// `changeAthlete`, `selectAthlete`, or the auto-select
    /// `openRemoteLibrary`/`openDirectory` make when a library first opens —
    /// so `settleFetches()` can await every `prepareCurrentClip` invocation a
    /// selection change started.
    ///
    /// All of them, not just the explicit ones: `prepareCurrentClip` reads
    /// `currentVideo` — live, at the moment its `Task` actually runs, not a
    /// snapshot from when the `Task` was created — so a coach (or a test)
    /// who moves on again before an *earlier* selection's fetch has even
    /// started leaves that earlier `Task` to resolve against whatever is
    /// current by the time it runs. Its `preparingCount` contribution is real
    /// regardless of which clip it ends up naming, and leaving it untracked
    /// was measured to make `isPreparingClip` flake false after
    /// `settleFetches()` returned — the untracked `Task` was still mid-flight,
    /// decrementing a moment later.
    ///
    /// Deliberately **not** the neighbour prefetches `fetchSelection` also
    /// starts (see `prefetch`, which does not touch `preparingCount` at
    /// all). Those are best-effort and may legitimately never finish — a
    /// coach who moves on again before a prefetch lands, or a test that
    /// gates the downloader and only releases the clips it selected — so
    /// awaiting them here would make `settleFetches()` hang on a fetch
    /// nobody asked it to wait for.
    private var fetchTasks: [Task<Void, Never>] = []

    /// Mirrors the cache for synchronous reads. `currentPlaybackURL` and
    /// `comparisonLibrary` are computed properties a SwiftUI view reads
    /// directly, so neither can await an actor.
    private var materialisedByFileID: [String: URL] = [:]

    private var activeAthleteID: String?
    private var hasStarted = false
    private let hold = SlowMotionHold()
    private var lastTapDirection: ScrubDirection?
    private var lastTapTime = Date.distantPast
    private var timeObserver: Any?
    private var durationObserver: NSKeyValueObservation?
    private var rateObserver: NSKeyValueObservation?

    private let input: PlaybackInputSource
    private let folderPicker: FolderPicker
    private let oauthPresenter: OAuthPresenter
    /// Re-encodes a clip the app has refused to fetch at full size. The same
    /// pipeline `SortingModel` uses, so a repaired clip is byte-for-byte the
    /// kind of file this app would have produced had the coach imported the
    /// footage through it in the first place — which is exactly what
    /// `ClipWeight` measures against.
    private let mediaPipeline: MediaPipeline
    private let now: () -> Date

    /// Exposed so tests can assert on seeks without a playable asset.
    private(set) var lastSeekOffset: Double?

    /// Where the sidebar pivot is persisted. Settable so a test never writes
    /// to the coach's real preferences or leaks state into another test —
    /// the same seam `RemoteLibraryIndex.storeRoot` uses for its own store.
    public static var defaults: UserDefaults = .standard

    /// The libraries this machine has connected, in the order they were last
    /// opened. Held here rather than in a view so that opening one records
    /// itself: the recording has to happen where the open *succeeds*, and every
    /// open goes through this model.
    public private(set) lazy var libraryStore = LibraryStore(defaults: Self.defaults)

    /// Republished for the landing list. A stored property rather than a
    /// computed one so SwiftUI is told when it changes; `LibraryStore` reads
    /// `UserDefaults` and cannot announce itself.
    @Published public private(set) var libraries: [Library] = []

    /// Which library is open, when one is. Nil for a folder or drive opened
    /// before any of this existed, and for the empty landing state.
    @Published public private(set) var openLibraryID: UUID?

    public func refreshLibraries() {
        libraries = libraryStore.all()
    }

    private static let sidebarGroupingDefaultsKey = "SidebarGrouping"

    /// `.event` when nothing is stored yet — today's only behaviour, so a
    /// coach who has never touched the pivot sees exactly what they always
    /// have.
    private static func loadSidebarGrouping() -> SidebarGrouping {
        Self.defaults.string(forKey: sidebarGroupingDefaultsKey)
            .flatMap(SidebarGrouping.init(rawValue:)) ?? .event
    }

    public init(
        input: PlaybackInputSource,
        folderPicker: FolderPicker,
        oauthPresenter: OAuthPresenter,
        mediaPipeline: MediaPipeline = AVFoundationMediaPipeline(),
        now: @escaping () -> Date = Date.init
    ) {
        self.input = input
        self.folderPicker = folderPicker
        self.oauthPresenter = oauthPresenter
        self.mediaPipeline = mediaPipeline
        self.now = now
        self.input.onIntent = { [weak self] intent in
            self?.handle(intent)
        }
        startObservingTime()
        startObservingRate()
    }

    /// `ViewerModel` has no `close()` the way `ComparisonModel` does — it is
    /// expected to live for the app's lifetime — but `removeTimeObserver` is
    /// cheap and correct to call anyway rather than leave `timeObserver` as
    /// write-only storage.
    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    /// Internal: the model subscribes itself to `input.onIntent`, so no caller
    /// outside the module drives it directly.
    func handle(_ intent: PlaybackIntent) {
        switch intent {
        case .togglePlayback:
            togglePlayback()
        case let .clip(step):
            changeVideo(by: step.offset)
        case let .athlete(step):
            changeAthlete(by: step.offset)
        case let .seek(direction):
            hold.end()
            performArrowTap(direction)
        case let .slowMotionBegan(direction):
            // Two different preconditions, and neither subsumes the other.
            //
            // `currentVideo != nil` is the viewer's own: with no clip selected
            // there is nothing to scrub, and the player still exists, so
            // `begin` would happily hold an item-less player. This is the only
            // copy of that rule.
            //
            // `hold.begin`'s answer is the shared one, and it is read rather
            // than re-derived on purpose: the status line is written here, so a
            // refused `begin` must not word the status after a hold it did not
            // start. It matters for the cross-direction press — ⌘→ held, then
            // ⌘← without releasing — where the player keeps running forward and
            // an unguarded write would announce "Slow backward" over it. This
            // used to be a local `!hold.isActive`, which was the same rule
            // written out a second time; `ComparisonModel` wrote it out a third
            // time and got it wrong. Short-circuiting matters: `begin` is not
            // reached, and so cannot start a hold, when there is no clip.
            guard currentVideo != nil,
                  hold.begin(direction, players: [player])
            else { return }
            status = direction == .forward ? "Slow forward" : "Slow backward"
        case .slowMotionEnded:
            endSlowMotion()
        case .focusAthleteSearch, .openFolder:
            // Handled by the view layer, which owns focus and the picker.
            break
        }
    }

    public var currentAthlete: AthleteGroup? {
        guard let activeAthleteID else { return nil }
        return athletes.first { $0.id == activeAthleteID }
    }

    public var filteredAthletes: [AthleteGroup] {
        let query = normalizedName(athleteQuery)
        guard !query.isEmpty else { return athletes }
        return athletes.filter {
            normalizedName($0.name).contains(query)
                || normalizedName($0.event ?? "").contains(query)
        }
    }

    /// `filteredAthletes` in sidebar sections — the grouping already sorted
    /// every event's athletes together, so one forward pass is enough and the
    /// sections come out in the same order as the flat list. Computed, never
    /// stored: the flat array stays the source of truth because selection-by-id,
    /// `changeAthlete` and the Page keys all run on it.
    public var events: [EventGroup] {
        EventGroup.sections(of: filteredAthletes, by: sidebarGrouping)
    }

    var currentVideo: URL? {
        guard let athlete = currentAthlete,
              athlete.videos.indices.contains(videoIndex)
        else {
            return nil
        }
        return athlete.videos[videoIndex]
    }

    /// What playback opens. A local library's URLs are already files; a cloud
    /// library's resolve to whatever the cache holds, and to nil until the
    /// bytes land — there is nothing to play before then, and handing back a
    /// path to a missing file would show an error instead of progress.
    public var currentPlaybackURL: URL? {
        guard let currentVideo else { return nil }
        guard let remoteIndex, let file = remoteIndex.file(for: currentVideo) else {
            return currentVideo
        }
        return cachedRemoteURL(for: file)
    }

    /// What the analysis stores should file this clip under. A cloud clip is
    /// its provider and file id; a local clip is its own URL.
    func identity(of video: URL) -> ClipIdentity {
        guard let remoteIndex, let file = remoteIndex.file(for: video) else {
            return ClipIdentity(video)
        }
        return file.identity(inProvider: remoteIndex.providerIdentifier)
    }

    /// The selected clip's identity, or nil when nothing is selected.
    public var currentClipIdentity: ClipIdentity? {
        currentVideo.map(identity(of:))
    }

    private func cachedRemoteURL(for file: RemoteFile) -> URL? {
        guard let url = materialisedByFileID[file.id] else { return nil }
        // The mirror can outlive the bytes. Eviction deletes a clip's file
        // whenever a later download pushes the cache over budget, and iOS may
        // purge Caches outright — `ClipCache.cachedURL` guards exactly this and
        // says so. Without the same guard here a view gets a `file://` URL that
        // looks valid and points at nothing, which shows an error where the
        // design promises progress.
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    public var comparisonLibrary: [ComparisonAthleteChoice] {
        athletes.map { athlete in
            ComparisonAthleteChoice(
                id: athlete.id,
                // The picker draws a flat menu with no section headers, so two
                // Alices from two events would be indistinguishable without
                // this. Left alone when there is no event, so a single-event
                // library reads exactly as it always has.
                name: athlete.event.map { "\(athlete.name) — \($0)" } ?? athlete.name,
                videos: athlete.videos.map { video in
                    ComparisonVideoChoice(
                        id: "\(athlete.id)|\(video.absoluteString)",
                        name: video.lastPathComponent,
                        playbackURL: remoteIndex?.file(for: video)
                            .flatMap { cachedRemoteURL(for: $0) } ?? video,
                        identity: identity(of: video)
                    )
                }
            )
        }
    }

    public var clipDescription: String {
        guard let athlete = currentAthlete, let currentVideo else { return "" }
        let position = "Clip \(videoIndex + 1) of \(athlete.videos.count)"
        guard let event = athlete.event else {
            return "\(position) · \(currentVideo.lastPathComponent)"
        }
        return "\(position) · \(event) · \(currentVideo.lastPathComponent)"
    }

    public func start(initialDirectory: URL?) {
        guard !hasStarted else { return }
        hasStarted = true
        if let initialDirectory {
            // A path on the command line is a folder somebody asked for by
            // name. Everything else lands on the library list.
            openDirectory(initialDirectory)
        }
        // Launching used to open the file picker here, which is why the coach
        // was hunting for the same folder every morning: the panel came up
        // before any part of the app was on screen, so there was nowhere for
        // "the libraries you already have" to be shown. Landing with nothing
        // open is now an answer rather than a gap.
    }

    public func chooseDirectory() async {
        guard let url = await folderPicker.pickFolder(
            startingAt: directory,
            title: "Choose organized video directory",
            confirmLabel: "Open"
        ) else {
            return
        }
        openDirectory(url)
        // Written down here rather than only on the landing screen, so a folder
        // opened from the menu is a folder the coach has, not one they will
        // have to find again. Only on success: `openDirectory` sets
        // `errorMessage` for a folder with no videos in it, and a library that
        // could not be read is not one to list.
        if errorMessage == nil {
            rememberFolder(at: url)
        }
    }

    public func setKeyboardControlsEnabled(_ enabled: Bool) {
        input.setEnabled(enabled)
        if !enabled {
            endSlowMotion()
        }
    }

    /// Signs in and asks which drives this account can see. Fetches nothing:
    /// the library is gigabytes and a coach has picked no clip yet.
    /// Clears a failed sign-in's message without attempting another.
    ///
    /// The drive sheet calls this when a club saves its own OAuth client id:
    /// whatever is on screen describes a client that is no longer in use, and
    /// leaving it there sends someone who has just fixed their setup back to
    /// debugging the thing they replaced. `signIn` clears it too, but only once
    /// the next attempt starts — too late to stop the reading.
    public func clearSignInError() {
        signInError = nil
    }

    /// Tries to pick up the previous session's sign-in without a browser, and
    /// lists the drives if it worked.
    ///
    /// The operator's complaint was "I don't understand why I have to login
    /// with google every time I run the app." The credential to avoid that was
    /// already in the Keychain; what was missing was anything that reached it
    /// before the interactive flow.
    ///
    /// **Where this runs is deliberate: the Club Library sheet calls it when it
    /// opens, not the app at launch.** Nothing should touch the network until
    /// the coach asks for the library, and a cold launch that silently reaches
    /// out to Google is surprising in a tool that mostly opens local folders —
    /// on a phone tether at a race it is also someone's data. Opening the sheet
    /// is the moment the coach has asked, and it is early enough to save them
    /// the browser.
    ///
    /// Three outcomes, and the difference between the last two is the whole
    /// point:
    ///
    ///  - Resumed and listed: the drive list appears, no browser.
    ///  - Nothing to resume — first run, or a token Google has since refused:
    ///    silent, leaving `availableRoots` empty, which is exactly what puts
    ///    the ordinary "Sign in with Google" button on screen. No error, because
    ///    an automatic attempt finding nothing is not a failure the coach
    ///    caused, and a red banner about it reads as a bug.
    ///  - Resumed and then failed to list: reported. The credential was
    ///    accepted, so whatever went wrong is not something the coach can infer
    ///    from a sign-in button — and an empty library that looks like a bug is
    ///    worse than being told.
    ///
    /// Nothing here can leave the coach stuck: every path that does not end in
    /// a drive list ends at the prompt they would have seen anyway.
    public func resumeSignIn(with provider: any RemoteLibraryProvider) async {
        guard await provider.resumeSession() else { return }
        do {
            availableRoots = try await provider.roots()
            remoteProvider = provider
            status = availableRoots.isEmpty
                ? "No shared drives are visible to this account."
                : "Choose a drive"
        } catch {
            availableRoots = []
            signInError = error.localizedDescription
        }
    }

    public func signIn(with provider: any RemoteLibraryProvider) async {
        signInError = nil
        do {
            try await provider.connect(presenter: oauthPresenter)
            availableRoots = try await provider.roots()
            remoteProvider = provider
            status = availableRoots.isEmpty
                ? "No shared drives are visible to this account."
                : "Choose a drive"
        } catch {
            availableRoots = []
            signInError = error.localizedDescription
            status = "Could not sign in"
        }
    }

    /// Opens the chosen drive's library. Separate from `signIn` because a
    /// coach in several drives picks one, and because the picker must be able
    /// to reappear without signing in again.
    ///
    /// Returns whether the library actually opened, so a caller — the sheet's
    /// button — can dismiss only then, rather than on every tap regardless of
    /// outcome. Clears any earlier failure's message at the start, the way
    /// `signIn` does, so a later successful pick never leaves a stale one on
    /// screen.
    @discardableResult
    public func chooseRoot(
        _ root: RemoteFolder, cache: ClipCache,
        convention: FolderConvention? = nil,
        rebuilding: Bool = false
    ) async -> Bool {
        signInError = nil
        guard let remoteProvider else { return false }
        do {
            try await openRemoteLibrary(
                provider: remoteProvider, root: root, cache: cache,
                convention: convention, rebuilding: rebuilding
            )
            availableRoots = []
            // Recorded here and nowhere else: this is where an open is known to
            // have worked. A library written at selection time would put a
            // folder the coach could not open at the top of their list.
            let recorded = libraryStore.add(
                Library(name: root.name, kind: .drive(rootID: root.id), convention: convention)
            )
            libraryStore.markOpened(recorded.id)
            openLibraryID = recorded.id
            refreshLibraries()
            return true
        } catch {
            signInError = error.localizedDescription
            return false
        }
    }

    /// Security-scoped bookmarks are spelled differently on each platform, and
    /// the difference is not cosmetic: `.withSecurityScope` exists only on the
    /// Mac, while on iPad a bookmark taken from the document picker is
    /// security-scoped already and passing the option fails to compile.
    #if os(macOS)
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = []
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    /// Opens a library the coach has already connected.
    ///
    /// The click that replaces the whole flow: no browser, no browsing, no
    /// layout question. Sign-in comes back from the Keychain, the stored index
    /// and change cursor make it a delta rather than a re-listing, and the
    /// layout is the one this library was connected with.
    ///
    /// Returns the reason it could not, rather than throwing: every caller has
    /// the same answer to every failure, which is to say so on the row and
    /// leave the library in the list. A drive that is unreachable this morning
    /// is not a drive to forget.
    @discardableResult
    /// `provider` is supplied by the caller because building one is the view's
    /// job — on the Mac it reads a client secret off disk, on iPad it uses a
    /// compiled-in client — and a model that reached for either would be
    /// reaching across that line. Nil, with no session already open, is simply
    /// "not signed in".
    public func open(_ library: Library, cache: ClipCache,
                     provider: (any RemoteLibraryProvider)? = nil) async -> String? {
        switch library.kind {
        case let .drive(rootID):
            guard let provider = remoteProvider ?? provider else {
                return "Sign in to open \(library.name)."
            }
            // A session resumed from the Keychain, so the coach is not sent to
            // Google for a library they connected weeks ago.
            if remoteProvider == nil, await provider.resumeSession() == false {
                return "Sign in to open \(library.name)."
            }
            do {
                try await openRemoteLibrary(
                    provider: provider,
                    root: RemoteFolder(id: rootID, name: library.name),
                    cache: cache,
                    convention: library.convention
                )
                remoteProvider = provider
                libraryStore.markOpened(library.id)
                openLibraryID = library.id
                refreshLibraries()
                return nil
            } catch {
                return error.localizedDescription
            }

        case let .folder(bookmark):
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark,
                                     options: Self.bookmarkResolutionOptions,
                                     bookmarkDataIsStale: &stale) else {
                return "\(library.name) is no longer where it was."
            }
            // The scope is held for as long as the library is open. A folder
            // outside the app's own container is unreadable without it on iPad,
            // and harmless to ask for on the Mac.
            let scoped = url.startAccessingSecurityScopedResource()
            openDirectory(url)
            if scoped { url.stopAccessingSecurityScopedResource() }
            guard errorMessage == nil else { return errorMessage }
            libraryStore.markOpened(library.id)
            openLibraryID = library.id
            refreshLibraries()
            return nil
        }
    }

    // MARK: - What is open, said out loud

    /// The library the coach is looking at, when they opened one from the list.
    /// Nil for a folder handed to the app on the command line, which was never
    /// recorded as a library.
    public var openLibrary: Library? {
        guard let openLibraryID else { return nil }
        return libraries.first { $0.id == openLibraryID }
    }

    /// Where a sorted clip would go in Drive, or why nowhere. Cheap and
    /// synchronous: ask it before tagging begins, not after.
    ///
    /// The index's layout counts only when it is known — the coach's own pick,
    /// or one read off the folders. `openRemoteLibrary` falls back to
    /// athlete-then-event when the folders say nothing; that is a display
    /// default for grouping and must not decide where footage is filed.
    public func uploadDestination() throws -> UploadDestination {
        var known: FolderConvention?
        if let remoteIndex {
            known = remoteIndex.conventionWasChosen
                ? remoteIndex.convention
                : RemoteLibraryIndex.inferredConvention(from: remoteIndex.files)
        }
        return try UploadDestination.resolve(library: openLibrary, indexConvention: known)
    }

    /// What an upload batch needs from the open library — its destination,
    /// the provider as a writer, and the presenter for Google's consent screen
    /// — or the reason there is none. Asked when the sorting screen opens, so
    /// a coach learns before tagging that uploading will not be possible.
    ///
    /// The provider is handed out as `any ItemCreatable`; `UploadBatchModel`
    /// never sees `GoogleDriveProvider`, which is what lets a fake stand in.
    public func uploadTarget() throws -> UploadTarget {
        let destination = try uploadDestination()
        guard let writer = remoteProvider as? ItemCreatable else {
            throw UploadRefusal.cannotWrite(libraryName: destination.libraryName)
        }
        return UploadTarget(destination: destination, provider: writer, presenter: oauthPresenter)
    }

    /// The name for the window. A library has a name now, so the window can use
    /// it: "Remote Library" answered a question nobody asked, and a coach with
    /// two clubs' drives connected could not tell from the title which one they
    /// were looking at.
    public var libraryTitle: String {
        if let openLibrary { return openLibrary.name }
        if let directory { return directory.lastPathComponent }
        return isUsingRemoteLibrary ? "Remote Library" : "Ski Video Viewer"
    }

    /// Where the open library came from and how much is in it — the line under
    /// the title. Nil when nothing is open, so the window does not carry an
    /// empty subtitle around the landing screen.
    public var librarySummary: String? {
        var parts: [String] = []
        switch openLibrary?.kind {
        case .drive:  parts.append("Google Drive")
        case .folder: parts.append(LocalSource.name)
        case nil:     if isUsingRemoteLibrary { parts.append("Google Drive") }
        }

        // Athletes are grouped per event, so one skier with three events is
        // three groups and one athlete. Counting the groups would report a
        // library as bigger than it is.
        let athleteCount = Set(athletes.map(\.name)).count
        let clipCount = athletes.reduce(0) { $0 + $1.videos.count }
        if athleteCount > 0 {
            parts.append("\(athleteCount) athlete\(athleteCount == 1 ? "" : "s")")
        }
        if clipCount > 0 {
            parts.append("\(clipCount) clip\(clipCount == 1 ? "" : "s")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Records a folder the coach added, as a bookmark rather than a path so it
    /// survives a relaunch on iPad.
    @discardableResult
    public func rememberFolder(at url: URL, named name: String? = nil) -> Library? {
        guard let bookmark = try? url.bookmarkData(options: Self.bookmarkCreationOptions,
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else { return nil }
        let library = libraryStore.add(
            Library(name: name ?? url.lastPathComponent,
                    kind: .folder(bookmark: bookmark),
                    // The path is what says "same folder" — see `folderPath`.
                    // Standardised so /private/var and /var are one place.
                    folderPath: url.standardizedFileURL.path)
        )
        libraryStore.markOpened(library.id)
        openLibraryID = library.id
        refreshLibraries()
        return library
    }

    /// Opens a cloud library: index it, group it, show it. No bytes are
    /// fetched — a clip downloads when it is selected.
    ///
    /// `convention` is the operator's explicit pick, or nil to read the layout
    /// off the folders. **It used to apply to a fresh sweep only** — a stored
    /// index kept whatever it was built with, which was documented here as a
    /// safeguard against silently relabelling a library and was in fact the
    /// reason the layout picker "never took effect": once a drive had been
    /// indexed once, nothing the coach chose could reach it again, and the
    /// operator's drive was stored as `eventThenAthlete` while being
    /// unambiguously athlete-first. It now applies every time, and costs
    /// nothing to apply — `RemoteLibraryIndex.settingConvention` re-groups the
    /// files already in hand and fetches nothing.
    ///
    /// A pick is remembered as a pick, so the inference below never overrules
    /// it on a later open. Nil re-reads the folders on every open rather than
    /// keeping the last inference, which is what makes a library that was
    /// unreadable when small land the right way round once it has grown.
    ///
    /// `rebuilding` throws the stored index away first, so the drive is listed
    /// from scratch. The escape hatch for state no refresh can correct — a
    /// path that was never resolved, a clip the change feed never mentioned —
    /// and the reason it is a parameter rather than its own method is that
    /// everything after the discard is identical, and a second copy of this
    /// function is a second place for the two to drift apart.
    public func openRemoteLibrary(
        provider: any RemoteLibraryProvider,
        root: RemoteFolder,
        cache: ClipCache,
        convention: FolderConvention? = nil,
        rebuilding: Bool = false
    ) async throws {
        status = rebuilding ? "Rebuilding \(root.name)…" : "Listing \(root.name)…"
        if rebuilding { RemoteLibraryIndex.discard(forRoot: root.id) }

        // A stored index plus a cursor makes a relaunch a delta. Page tokens
        // never expire and Drive coalesces its change log per file, so an app
        // closed for months still resyncs in a bounded number of calls — where
        // a re-sweep would list the whole drive every time.
        var index = RemoteLibraryIndex.load(forRoot: root.id)
        if let stored = index,
           let cursor = stored.cursor,
           let incremental = provider as? IncrementallyEnumerable {
            let changes = try await incremental.changes(since: cursor, forRoot: root.id)
            // Bytes are never deleted here. A `removed` change means the clip
            // left *this library*, which Drive also reports for lost access
            // and a corpus move — evicting on it would make a coach pay to
            // re-download a clip that never went anywhere.
            index = stored.applying(changes)
        } else if index == nil {
            var files: [RemoteFile] = []
            for try await file in provider.enumerate(root) { files.append(file) }
            // No convention here: the sweep's own files are what the layout is
            // decided from, a few lines below, and passing one would make this
            // branch quietly disagree with the stored-index branch.
            var swept = RemoteLibraryIndex(
                providerIdentifier: type(of: provider).identifier,
                rootName: root.name, files: files
            )
            if let incremental = provider as? IncrementallyEnumerable {
                swept = swept.withCursor(try await incremental.startCursor(forRoot: root.id))
            }
            index = swept
        }
        guard var index, !index.athletes.isEmpty else { throw ViewerError.noVideos }

        // The layout, decided once the files are in hand and never before. An
        // explicit pick wins outright and is recorded as explicit; otherwise
        // the folders are read afresh, every open. `.athleteThenEvent` where
        // they say nothing either way.
        if let convention {
            index = index.settingConvention(convention, chosenByOperator: true)
        } else if !index.conventionWasChosen {
            index = index.settingConvention(
                RemoteLibraryIndex.inferredConvention(from: index.files) ?? .athleteThenEvent,
                chosenByOperator: false
            )
        }

        endSlowMotion()
        player.pause()
        directory = nil
        remoteIndex = index
        remoteProvider = provider
        clipCache = cache
        materialisedByFileID = [:]
        isUsingRemoteLibrary = true
        let ordered = LibraryGrouping.order(index.athletes, by: sidebarGrouping)
        athletes = ordered
        activeAthleteID = nil
        selectedAthleteID = ordered[0].id
        athleteQuery = ""
        zoom.reset()
        selectInitialAthlete(ordered[0].id)
        let clipCount = index.athletes.reduce(0) { $0 + $1.videos.count }
        status = "\(root.name) — \(clipCount) clips"
        // A failure to persist is a slower next launch, not a reason to
        // refuse the library the coach can already see.
        try? index.save(forRoot: root.id)
    }

    /// Brings the selected clip's bytes to disk, so playback and analysis have
    /// a real file. A no-op for a local library.
    public func prepareCurrentClip() async throws {
        guard let currentVideo,
              let remoteIndex, let remoteProvider, let clipCache,
              let file = remoteIndex.file(for: currentVideo)
        else { return }

        // Captured before the await, so the reload below can tell whether the
        // coach moved on while this clip was downloading.
        let videoAtRequest = currentVideo

        preparingCount += 1
        isPreparingClip = true
        defer {
            preparingCount -= 1
            isPreparingClip = preparingCount > 0
        }
        status = "Fetching \(file.name)…"
        do {
            materialisedByFileID[file.id] = try await materialise(
                file, using: remoteProvider, cache: clipCache
            )
        } catch let RemoteLibraryError.tooLargeToFetch(explanation) {
            // Not a failure to report as one: nothing broke, the app declined.
            // Guarded on the selection the same way the success path below is
            // — otherwise a refusal landing after the coach moved on would
            // pin its banner to whichever clip is now on screen.
            guard self.currentVideo == videoAtRequest else { return }
            unsupportedFormatMessage = explanation
            // Anything but the "Fetching…" `loadCurrentVideo` left behind,
            // which would otherwise sit there forever promising a download
            // that is never going to start.
            status = file.name
            return
        }
        await clipCache.recordPlayback(
            of: file.identity(inProvider: remoteIndex.providerIdentifier)
        )
        // The player was pointed at nothing while the bytes were arriving, so
        // it has to be told they landed — without this the pane stays empty
        // until the next selection change, and the clip a coach asked for
        // never appears. Guarded against the selection having moved on during
        // the download, which would otherwise load the wrong clip.
        //
        // `self.currentVideo`, deliberately not the bare `currentVideo` the
        // guard above binds: that `let` shadows the computed property for
        // the rest of this function, so `currentVideo == videoAtRequest`
        // compared a value against itself and was always true — a dead
        // guard, not a working one. Found by a test that could not make it
        // fail no matter how the race was constructed, then confirmed by
        // tracing `self.currentVideo` versus the shadowed local at this
        // exact line while a selection genuinely moved on mid-fetch.
        guard self.currentVideo == videoAtRequest else { return }
        loadCurrentVideo()
        status = file.name
    }

    /// Materialises one clip's bytes, retrying once with a freshly minted
    /// source if the cached one has gone stale.
    ///
    /// Task 3's 401-and-refresh covers `RemoteLibraryProvider`'s own API
    /// calls; the bytes are fetched by `ClipCache`'s downloader, outside the
    /// provider, and a 401 there became a plain failure with no refresh —
    /// the same "token expires mid-session and cannot be replaced" defect
    /// this whole design exists to route around, just on the path that
    /// matters most. Retried once, not in a loop: a second refusal is a real
    /// failure, and retrying it forever would hammer Drive with a bad token.
    /// `enforcingWeightLimit: false` is for the repair path and nothing else.
    /// Re-encoding a clip requires its original bytes, so the one operation
    /// that fixes an oversized clip is also the one operation that must be
    /// allowed to download it — refusing there would make the refusal
    /// permanent.
    private func materialise(
        _ file: RemoteFile, using provider: any RemoteLibraryProvider, cache: ClipCache,
        enforcingWeightLimit: Bool = true
    ) async throws -> URL {
        // The one place both screens' fetches pass through — the selected
        // clip, its prefetched neighbours, and a comparison pane's choice all
        // arrive here — so the "too heavy to fetch" rule is enforced once.
        let verdict = ClipWeight.verdict(
            width: file.width, height: file.height,
            durationMillis: file.durationMillis, size: file.size
        )
        if verdict.isTooLarge, enforcingWeightLimit {
            // Refusing to fetch is not refusing to play. Bytes already on
            // disk were paid for once, and taking the clip away at that point
            // would be a regression dressed up as a safeguard. Deliberately
            // *not* the version check `cache.materialize` performs on the
            // ordinary path: a newer revision of a still-oversized clip
            // cannot be downloaded either, so insisting on being current
            // would leave the coach with nothing rather than with slightly
            // stale footage. A clip repaired to a sane size stops being
            // flagged and takes the ordinary path, version check included.
            if let cached = await cache.cachedURL(
                for: file.identity(inProvider: type(of: provider).identifier)
            ) {
                return cached
            }
            throw RemoteLibraryError.tooLargeToFetch(
                verdict.explanation ?? "This clip is too large to download."
            )
        }

        let source = try await provider.downloadSource(for: file)
        do {
            return try await cache.materialize(file, source: source)
        } catch RemoteLibraryError.unauthorised {
            let retried = try await provider.downloadSource(for: file)
            return try await cache.materialize(file, source: retried)
        }
    }

    /// Materialises the clip a comparison pane was just given, so the pane is
    /// handed a file it can actually open rather than the library URL
    /// `comparisonLibrary` falls back to before a clip has been fetched —
    /// the gap plan 2 pinned deliberately, closed here.
    ///
    /// Falls back to the choice's own `playbackURL` on any failure to
    /// materialise, including a local library (no `remoteIndex`) and an id
    /// `remoteIndex` no longer carries: `ComparisonVideoChoice.playbackURL`
    /// is non-optional, so something has to come back, and the pane already
    /// knows how to show that URL failing to open.
    ///
    /// `public`, not merely reachable through `@testable import`: `ContentView`
    /// is the one place in the app target that captures this into the
    /// `(ComparisonVideoChoice) async -> URL?` shape
    /// `SecondaryScreenPresenter.presentComparison`'s `prepare` parameter
    /// carries — see that seam for why a closure crosses this boundary rather
    /// than the model itself.
    /// A refusal comes back as `.refused` carrying its explanation, so the
    /// pane that asked can state it where the operator is looking. An ordinary
    /// *failure* is still `.nothingToDo`: the caller falls back to the choice's
    /// own `playbackURL` and the pane shows that URL failing to open, exactly
    /// as before. The two were briefly the same `nil`, which meant a pane could
    /// not tell "there was nothing to fetch" from "I declined to fetch this",
    /// and the reason had to travel by side channel instead.
    public func prepareClip(_ choice: ComparisonVideoChoice) async -> ClipPreparer.Outcome {
        guard let remoteIndex, let remoteProvider, let clipCache,
              case let .remote(_, fileID) = choice.identity,
              let file = remoteIndex.file(forID: fileID)
        else { return .nothingToDo }
        let url: URL
        do {
            url = try await materialise(file, using: remoteProvider, cache: clipCache)
        } catch let RemoteLibraryError.tooLargeToFetch(explanation) {
            return .refused(explanation)
        } catch {
            return .nothingToDo
        }
        materialisedByFileID[file.id] = url
        await clipCache.recordPlayback(of: file.identity(inProvider: remoteIndex.providerIdentifier))
        return .ready(url)
    }

    /// Whether the selected clip is one this app has refused to fetch, and so
    /// one the coach can offer to repair. Nil when there is nothing to repair.
    ///
    /// Recomputed rather than remembered: `unsupportedFormatMessage` is also
    /// set for clips this device merely cannot decode, and offering "resize
    /// and replace" for those would promise a fix that does not apply.
    public var repairableClip: RemoteFile? {
        guard let currentVideo, let remoteIndex, remoteProvider is ContentReplaceable,
              let file = remoteIndex.file(for: currentVideo),
              ClipWeight.verdict(
                  width: file.width, height: file.height,
                  durationMillis: file.durationMillis, size: file.size
              ).isTooLarge
        else { return nil }
        return file
    }

    /// Downloads the oversized clip once, re-encodes it, and writes the result
    /// back over the same Drive file.
    ///
    /// **The order matters and is the same order `reencode_for_ios.py` uses.**
    /// The upload happens only after the re-encode has succeeded, so a failed
    /// or interrupted repair leaves the coach's footage in Drive exactly as it
    /// was. There is no point at which the original has been replaced by
    /// something unfinished.
    ///
    /// Replacing the bytes gives the file a new `headRevisionId`, which this
    /// app carries as `contentVersion`. Feeding it back into the index is what
    /// makes `ClipCache` treat its stored copy as stale — without it the cache
    /// would keep serving the 400MB original and the repair would look like it
    /// had done nothing.
    public func repairCurrentClip() async {
        // Deliberately does not bind `remoteIndex`: a `guard let` would shadow
        // the property with a `let` copy, and the version write below has to
        // reach the property itself. That exact shadowing bug has already cost
        // this file a dead guard in `prepareCurrentClip` — see its comment.
        guard let file = repairableClip,
              let provider = remoteProvider as? ContentReplaceable,
              let clipCache, remoteIndex != nil
        else { return }

        preparingCount += 1
        isPreparingClip = true
        defer {
            preparingCount -= 1
            isPreparingClip = preparingCount > 0
        }

        let resized = FileManager.default.temporaryDirectory
            .appendingPathComponent("repair-\(file.id)", isDirectory: true)
            .appendingPathComponent(file.name)
        defer { try? FileManager.default.removeItem(at: resized.deletingLastPathComponent()) }

        do {
            // Before anything else, and every time: an access token minted for
            // reading cannot write, so without this the repair does all its
            // work — a 400MB download and a full re-encode — and only then
            // discovers Drive will not accept the upload.
            status = "Asking Google for permission to replace \(file.name)…"
            try await provider.authorizeWrites(presenter: oauthPresenter)

            status = "Fetching \(file.name) to resize…"
            let original = try await materialise(
                file, using: provider, cache: clipCache, enforcingWeightLimit: false
            )

            status = "Resizing \(file.name)…"
            try await mediaPipeline.resize(
                source: original, destination: resized,
                athlete: currentAthlete?.name ?? file.path.last ?? ""
            )

            status = "Replacing \(file.name) in Drive…"
            let version = try await provider.replaceContents(
                ofFileID: file.id, withFileAt: resized
            )

            let resizedSize = (try? FileManager.default.attributesOfItem(atPath: resized.path))
                .flatMap { $0[.size] as? NSNumber }
                .map { $0.int64Value }
            remoteIndex?.recordRepair(
                ofFileID: file.id, contentVersion: version, size: resizedSize
            )
            materialisedByFileID[file.id] = nil
            unsupportedFormatMessage = nil
            status = "\(file.name) resized and replaced."
            fetchCurrentClip()
        } catch {
            // The Drive file is untouched on every path that reaches here —
            // the upload is the last step — so this reports and stops rather
            // than trying to undo anything.
            unsupportedFormatMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            status = "Could not resize \(file.name)."
        }
    }

    /// Starts fetching the newly selected clip, and prefetching its
    /// neighbours. Called after every explicit change of selection —
    /// `changeVideo`, `changeAthlete`, and a direct `selectAthlete` call from
    /// the sidebar. A no-op for a local library: `prepareCurrentClip` and
    /// `neighboursToPrefetch` both return immediately without a
    /// `remoteIndex`.
    private func fetchSelection() {
        fetchCurrentClip()
        for file in neighboursToPrefetch() {
            Task { [weak self] in
                await self?.prefetch(file)
            }
        }
    }

    /// Starts the current clip's own fetch and tracks it in `fetchTasks` —
    /// see that property for why every selection change's own fetch is
    /// tracked, including the initial auto-select's.
    private func fetchCurrentClip() {
        let task = Task { [weak self] in
            guard let self else { return }
            try? await self.prepareCurrentClip()
        }
        fetchTasks.append(task)
    }

    /// Best-effort priming of a clip nobody has asked for yet. Shares
    /// `materialise`'s one-shot retry on a stale token with the selected
    /// clip's own fetch; any other error is swallowed — a coach who actually
    /// selects this clip gets the real failure from `prepareCurrentClip`
    /// instead.
    private func prefetch(_ file: RemoteFile) async {
        guard let remoteProvider, let clipCache else { return }
        guard let url = try? await materialise(file, using: remoteProvider, cache: clipCache) else { return }
        materialisedByFileID[file.id] = url
    }

    /// The clips worth having before they are asked for: the two a coach is
    /// about to step forward onto, and the one behind them. Bounded on
    /// purpose — the library is 74 GB, and "fetch the whole athlete" is a
    /// flooded connection on a hill.
    private func neighboursToPrefetch() -> [RemoteFile] {
        guard let athlete = currentAthlete, let remoteIndex else { return [] }
        return [videoIndex - 1, videoIndex + 1, videoIndex + 2]
            .filter { athlete.videos.indices.contains($0) }
            .compactMap { remoteIndex.file(for: athlete.videos[$0]) }
    }

    /// Awaits every fetch a selection change has started, so a test can wait
    /// for `changeVideo`/`changeAthlete`/`selectAthlete` to actually land
    /// their clip without `Task.sleep`. Drains `fetchTasks` first: a task
    /// appended while this is running belongs to a later selection, and to
    /// that selection's own wait, not this one's.
    func settleFetches() async {
        let tasks = fetchTasks
        fetchTasks.removeAll()
        for task in tasks {
            await task.value
        }
    }

    public func openDirectory(_ url: URL) {
        do {
            let scannedAthletes = try VideoLibrary.scan(url)
            guard !scannedAthletes.isEmpty else { throw ViewerError.noVideos }
            endSlowMotion()
            player.pause()
            directory = url
            let ordered = LibraryGrouping.order(scannedAthletes, by: sidebarGrouping)
            athletes = ordered
            remoteIndex = nil
            remoteProvider = nil
            clipCache = nil
            materialisedByFileID = [:]
            isUsingRemoteLibrary = false
            activeAthleteID = nil
            selectedAthleteID = ordered[0].id
            zoom.reset()
            selectInitialAthlete(ordered[0].id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func selectAthlete(_ id: String?) {
        guard applySelection(id) else { return }
        fetchSelection()
    }

    /// The auto-pick `openRemoteLibrary`/`openDirectory` make when a library
    /// first opens. Same selection as `selectAthlete`, but starting only the
    /// current clip's own fetch — no prefetch of neighbours.
    ///
    /// A coach who has not navigated anywhere yet gets the one clip on
    /// screen, not an immediate flurry of prefetches for clips they may never
    /// look at. The fetch itself is still tracked in `fetchTasks`, same as
    /// every other selection change — see that property for why leaving it
    /// untracked was measured to flake `isPreparingClip`.
    private func selectInitialAthlete(_ id: String?) {
        guard applySelection(id) else { return }
        fetchCurrentClip()
    }

    @discardableResult
    private func applySelection(_ id: String?) -> Bool {
        guard let id,
              id != activeAthleteID,
              athletes.contains(where: { $0.id == id })
        else {
            return false
        }
        endSlowMotion()
        activeAthleteID = id
        selectedAthleteID = id
        videoIndex = 0
        loadCurrentVideo()
        return true
    }

    @discardableResult
    public func changeVideo(by offset: Int) -> Bool {
        guard let athlete = currentAthlete, !athlete.videos.isEmpty else {
            return false
        }
        endSlowMotion()
        videoIndex = (videoIndex + offset + athlete.videos.count) % athlete.videos.count
        loadCurrentVideo()
        fetchSelection()
        return true
    }

    @discardableResult
    func changeAthlete(by offset: Int) -> Bool {
        guard !athletes.isEmpty,
              let currentIndex = athletes.firstIndex(where: { $0.id == activeAthleteID })
        else {
            return false
        }
        let nextIndex = (currentIndex + offset + athletes.count) % athletes.count
        selectAthlete(athletes[nextIndex].id)
        return true
    }

    public func selectFirstMatchingAthlete() {
        guard let athlete = filteredAthletes.first else { return }
        selectAthlete(athlete.id)
    }

    public func togglePlayback() {
        guard currentVideo != nil else { return }
        endSlowMotion()
        if player.rate == 0 {
            rewindIfAtEnd()
            player.playImmediately(atRate: 1)
            status = "Playing"
        } else {
            player.pause()
            status = "Paused"
        }
    }

    /// The viewer's six transport actions, in one entry point mirroring
    /// `ComparisonModel.applyTransport`. One shape across both screens means
    /// one shared `TransportControls` view can drive either.
    public func applyTransport(_ action: TransportAction) {
        // Any in-flight slow-motion hold ends first. Without this the hold's
        // state survives the press — `SlowMotionHold.isActive` stays true, and
        // its `begin` refuses every later hold.
        endSlowMotion()
        switch action {
        case .back5: seek(seconds: -5)
        case .back1: seek(seconds: -1)
        case .forward1: seek(seconds: 1)
        case .forward5: seek(seconds: 5)
        case .playPause:
            // `togglePlayback` ends the hold itself, so the `endSlowMotion`
            // above is a no-op by the time this branch runs. Kept there anyway:
            // it is what makes the *seeking* actions cancel a hold, and this
            // button behaving the same as the Space key — which reaches
            // `togglePlayback` directly via `handle(.togglePlayback)` — is the
            // point. Play/Pause exits a hold rather than steering it.
            togglePlayback()
        case .slow:
            guard currentVideo != nil else { return }
            // The same dead end as `togglePlayback`, by a different door: this
            // branch has no toggle in front of it, so it never even asks
            // whether the player is stopped — it just calls `playImmediately`,
            // which at the end of a clip does nothing.
            rewindIfAtEnd()
            player.playImmediately(atRate: 0.25)
            status = "Quarter speed"
        }
    }

    /// Back to the first frame when play is asked for at the end of the clip.
    ///
    /// Called from both places that start the viewer from a stopped state, and
    /// deliberately not from `seek`/`scrub`: this is "play means play", not a
    /// bound. See `AVPlayer.isAtEndOfClip` for the measurements behind the
    /// tolerance, and for why no completion handler is needed here — the
    /// `playImmediately` that follows in the same turn starts correctly against
    /// an un-awaited seek.
    ///
    /// `currentTime` is written straight away rather than left to the periodic
    /// observer, which runs at 0.1s and would otherwise leave the scrubber thumb
    /// sitting at the end for a visible moment after the picture restarted.
    /// `scrub(to:)` writes it for the same reason.
    private func rewindIfAtEnd() {
        guard player.isAtEndOfClip else { return }
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = 0
    }

    /// Absolute seek, for the scrubber. `cancelPendingSeeks` first so a drag
    /// coalesces instead of queueing one seek per pixel.
    public func scrub(to seconds: Double) {
        guard player.currentItem != nil else { return }
        endSlowMotion()
        player.currentItem?.cancelPendingSeeks()
        var target = max(0, seconds)
        if duration > 0 { target = min(target, duration) }
        currentTime = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    // MARK: - Zoom

    /// `paneSize` is the video pane's own size, which only a view can know —
    /// it comes from `ViewerPane`'s `GeometryReader`. `videoSize` is *not* a
    /// parameter: `VideoZoom` needs the clip's dimensions to clamp the pan, and
    /// this class holds the player, so a view passing them would have to reach
    /// through the model to the player for a value the model already has.
    ///
    /// Out-of-range scales arrive here routinely — `ZoomControl`'s step buttons
    /// offer `scale ± 0.5` without checking the bounds — and are correct to
    /// pass on: `VideoZoom.setScale` clamps to `VideoZoom.range` unconditionally,
    /// so the range is enforced in exactly one place.
    public func setZoomScale(_ scale: Double, in paneSize: CGSize) {
        zoom.setScale(scale, in: paneSize, videoSize: videoSize)
    }

    public func panZoom(by translation: CGSize, in paneSize: CGSize) {
        zoom.pan(by: translation, in: paneSize, videoSize: videoSize)
    }

    public func resetZoom() {
        zoom.reset()
    }

    /// The current clip's own dimensions, or `.zero` before its tracks have
    /// loaded — which is the value `VideoZoom` documents as "no aspect to fit
    /// yet" and falls back to the pane's rect for. Read fresh on every call
    /// rather than cached, for the same reason `SinglePlayerView`'s layer host
    /// re-reads it: it arrives late, and it changes on every clip.
    ///
    /// **The pre-load window is benign, traced rather than assumed.** While
    /// this reads `.zero`, `VideoZoom`'s `fitted` falls back to the pane, so a
    /// clamp computed here uses **the pane's aspect, not the clip's** — and a
    /// stored `center` can therefore sit briefly outside the interval that is
    /// legal once the clip's real aspect is known. Nothing draws wrong in the
    /// meantime, because `layerFrame` re-clamps its own rendering copy against
    /// the real geometry on every pass, and nothing jumps afterwards, because
    /// the next `pan` clamps to the position already on screen. It self-heals
    /// invisibly; there is no correction to make here.
    private var videoSize: CGSize {
        player.currentItem?.presentationSize ?? .zero
    }

    /// The single teardown. Every library change and every transport action
    /// routes here, because a hold left running into a clip it was not started
    /// on is the defect this replaces.
    private func endSlowMotion() {
        guard hold.isActive else { return }
        hold.end()
        status = player.rate == 0 ? "Paused" : "Playing"
    }

    /// 0.1s matches the comparison screen's interval: fast enough that the
    /// scrubber thumb tracks playback without visible stepping, slow enough not
    /// to publish on every frame.
    private func startObservingTime() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
            }
        }
    }

    /// `rate`, not `timeControlStatus`. Both are KVO-observable, and
    /// `timeControlStatus` is the more informative of the two — which is exactly
    /// the problem here. It reports `.waitingToPlayAtSpecifiedRate` while the
    /// rate is still 0, so a stalled Google Drive stream would publish
    /// `isPlaying == true` with the picture frozen, and the operator's focus
    /// would be taken away for playback that never started. `rate != 0` is also
    /// the same predicate the model already branches on in `togglePlayback` and
    /// `endSlowMotion`, so the published flag cannot disagree with the decisions
    /// made from it. Reverse playback (`atRate: -0.35`) counts as playing, as it
    /// should; the reverse *fallback*, which pauses the player and steps it with
    /// a timer, does not — the player really is stopped there.
    ///
    /// The current rate is read inside the hop rather than taken from the change
    /// dictionary: `Task { @MainActor }` gives no ordering guarantee between two
    /// notifications, so a captured value could settle stale, whereas re-reading
    /// makes every hop converge on the player's present state. `observeDuration`
    /// re-reads for the same reason.
    private func startObservingRate() {
        rateObserver = player.observe(\.rate, options: [.initial, .new]) { player, _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = player.rate != 0
            }
        }
    }

    /// The periodic observer cannot carry duration: it does not fire while
    /// paused, and a freshly loaded clip is paused. `ComparisonModel` learned
    /// the same thing — the duration arrives asynchronously, after the item
    /// does.
    private func observeDuration(of item: AVPlayerItem) {
        durationObserver = item.observe(\.duration, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item else { return }
                let seconds = item.duration.seconds
                guard seconds.isFinite, seconds > 0 else { return }
                self.duration = seconds
            }
        }
    }

    /// Loads whatever `currentPlaybackURL` resolves to. For a local library
    /// that is always the current clip's own file; for a cloud library it is
    /// nil until `prepareCurrentClip` lands the bytes, and calling this again
    /// once it has is what puts the downloaded clip on screen.
    private func loadCurrentVideo() {
        guard currentVideo != nil else { return }
        // Reset before observing: the previous clip's figures would otherwise
        // drive the scrubber until the new duration arrives, which for a remote
        // Drive item can be a visible moment. Also correct for the "not yet
        // on disk" branch below, which has no clip to report a duration for.
        currentTime = 0
        duration = 0
        guard let playbackURL = currentPlaybackURL else {
            // Cloud clip not yet on disk — reachable only for a remote
            // library, since `currentPlaybackURL` always resolves for a
            // local one. Nothing to show until the fetch completes and calls
            // back in here. Not "Paused": that is the identical string a
            // normally stopped clip shows, and would make a downloading clip
            // look finished rather than in progress.
            player.replaceCurrentItem(with: nil)
            status = "Fetching…"
            // The refusal banner belongs to the clip that earned it. Only
            // `checkPlayability` clears it otherwise, and that runs on the
            // branch below — so without this, a clip refused for its size
            // would leave its message on screen over every clip selected
            // afterwards that is not yet on disk.
            unsupportedFormatMessage = nil
            return
        }
        let item = AVPlayerItem(url: playbackURL)
        player.replaceCurrentItem(with: item)
        observeDuration(of: item)
        player.pause()
        status = "Paused"
        checkPlayability(of: playbackURL)
    }

    /// Reports a clip this device cannot decode, so sound-with-no-picture
    /// reads as a known format problem rather than a broken download. See
    /// `ClipPlayability` for why the library contains such clips at all.
    ///
    /// Asynchronous because it loads a track, and the answer arrives after the
    /// player already has the item — deliberately: making playback wait on
    /// this would delay every clip that is perfectly fine to warn about the
    /// few that are not.
    private func checkPlayability(of url: URL) {
        unsupportedFormatMessage = nil
        Task { [weak self] in
            let message = await ClipPlayability.unsupportedVideoMessage(for: url)
            guard let self, let message else { return }
            // The coach may have moved on while the track loaded. Without this
            // the warning would attach to whichever clip is on screen when the
            // answer lands, which is the wrong one.
            guard self.currentPlaybackURL == url else { return }
            self.unsupportedFormatMessage = message
        }
    }

    private func seek(seconds: Double) {
        lastSeekOffset = seconds
        guard player.currentItem != nil else { return }
        let currentSeconds = player.currentTime().seconds
        let safeCurrent = currentSeconds.isFinite ? currentSeconds : 0
        var targetSeconds = max(0, safeCurrent + seconds)
        let duration = player.currentItem?.duration.seconds ?? .nan
        if duration.isFinite {
            targetSeconds = min(targetSeconds, duration)
        }
        let target = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func performArrowTap(_ direction: ScrubDirection) {
        let timestamp = now()
        let isDoubleTap = lastTapDirection == direction
            && timestamp.timeIntervalSince(lastTapTime) <= 0.38
        let seconds = isDoubleTap ? 5.0 : 1.0
        seek(seconds: Double(direction.rawValue) * seconds)
        status = "\(direction == .forward ? "Forward" : "Back") \(isDoubleTap ? 5 : 1) seconds"
        lastTapDirection = isDoubleTap ? nil : direction
        lastTapTime = isDoubleTap ? .distantPast : timestamp
    }

    private func normalizedName(_ name: String) -> String {
        name.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }
}
