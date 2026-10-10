import Foundation

/// Everything a batch needs from the open library: where clips go, what writes
/// them there, and what can show Google's consent screen.
///
/// `provider` is `any ItemCreatable`, never `GoogleDriveProvider`, so a test —
/// or a UI test's launch-argument fake — can stand in for Drive. Built by
/// `ViewerModel.uploadTarget()` in the app.
public struct UploadTarget {
    public let destination: UploadDestination
    public let provider: any ItemCreatable
    public let presenter: OAuthPresenter

    public init(destination: UploadDestination, provider: any ItemCreatable, presenter: OAuthPresenter) {
        self.destination = destination
        self.provider = provider
        self.presenter = presenter
    }
}

/// The upload tray: the sorted clips waiting on this device, and the batch
/// that sends them to the club's Drive.
///
/// **What is waiting is never remembered.** The list is read from the sorted
/// output on disk (`SortedOutput.clips(in:)`), and whether a clip is already
/// in Drive is asked of Drive (`findFile` in the clip's own destination
/// folder, by name *and size* — see `placement(of:in:)`). Being killed mid-batch is normal on a hill — a phone pocketed, a
/// battery gone cold — so a tray rebuilt from nothing has to arrive at the
/// same answer, and it can only do that if it never relied on memory.
///
/// Drive is asked twice: once when the tray is refreshed, with lookups only
/// (no folder is created to answer "is it there?"), so the coach sees what is
/// actually still waiting; and again immediately before each upload, which is
/// the check the "nothing uploads twice" rule rests on. The first is a
/// courtesy and may fail (no signal); the second is not optional.
///
/// Errors sort three ways, and the split is the coach's experience:
///  - `RemoteUploadError.stopBatch` and `RemoteLibraryError.notSignedIn` stop
///    the batch. Every further clip would fail the same way, so the rest stay
///    waiting and `stopReason` says why.
///  - Cancellation returns the clip in flight to waiting. The coach chose it;
///    it is not a failure.
///  - Anything else — `.retryClip`, and every untyped error, including a
///    folder the find path could not see (Drive's 403 there arrives as
///    `.api`) — fails that clip alone, with its reason, and the batch goes on.
@MainActor
public final class UploadBatchModel: ObservableObject {
    public enum ClipState: Equatable, Hashable, Sendable {
        case waiting
        case uploading
        case uploaded
        /// Drive already had this clip in its folder: a file of its name — or
        /// of one of its numbered names, see `Entry.driveName` — and its size.
        case alreadyInDrive
        case failed(String)
    }

    public struct Entry: Identifiable, Equatable {
        public let clip: SortedClip
        /// Bytes on disk.
        public let size: Int64
        public internal(set) var state: ClipState
        /// The name the clip has in Drive, when that is not its own name: it
        /// shared a name with a different clip there, so it went up as
        /// "<stem> 2.<ext>" (or 3, …). Nil when it is its own name, or not
        /// yet known.
        public internal(set) var driveName: String?
        public var id: URL { clip.file }
    }

    @Published public private(set) var entries: [Entry] = []
    @Published public private(set) var isUploading = false
    @Published public private(set) var isCheckingDrive = false
    /// Why the last batch stopped before its end. Nil after a clean run or a
    /// cancel.
    @Published public private(set) var stopReason: String?
    /// Why the sorted output could not be read. Kept apart from
    /// `checkProblem` so the Drive check that follows a refresh cannot clear
    /// it: an unreadable folder must not look like "nothing sorted yet".
    @Published public private(set) var readProblem: String?
    /// Why the tray could not ask Drive what it already has. Clips then show
    /// as waiting; the per-upload check still skips any already there.
    @Published public private(set) var checkProblem: String?
    /// Clips the running batch set out to send, and how many it has dealt
    /// with — uploaded, skipped or failed. The progress view's numbers.
    @Published public private(set) var runTotal = 0
    @Published public private(set) var runDone = 0

    /// Which sorted clips this tray is about.
    public enum Source: Equatable {
        /// Every event under a sorted output root — the whole history on
        /// this device. The setup screen's "Clips waiting to upload…".
        case outputRoot(URL)
        /// One event folder, `<outputRoot>/<event>` — the session just
        /// tagged. The finished-tagging screen uses this, so it neither lists
        /// nor asks Drive about last season.
        case eventFolder(URL)

        public var directory: URL {
            switch self {
            case let .outputRoot(url), let .eventFolder(url): return url
            }
        }

        func clips() throws -> [SortedClip] {
            switch self {
            case let .outputRoot(url): return try SortedOutput.clips(in: url)
            case let .eventFolder(url): return try SortedOutput.clips(inEventFolder: url)
            }
        }
    }

    public let source: Source
    private let target: UploadTarget
    private var batchTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?

    public init(source: Source, target: UploadTarget) {
        self.source = source
        self.target = target
    }

    /// The whole sorted output root — `<root>/<event>/<athlete>/<clip>`.
    public convenience init(root: URL, target: UploadTarget) {
        self.init(source: .outputRoot(root), target: target)
    }

    public var libraryName: String { target.destination.libraryName }
    public var waitingCount: Int { entries.filter { $0.state == .waiting }.count }
    public var failedCount: Int {
        entries.filter { if case .failed = $0.state { return true } else { return false } }.count
    }

    // MARK: - The tray

    /// Re-reads the sorted output and asks Drive which clips it already has.
    /// A clip whose state this tray already knows keeps it. Does nothing while
    /// a batch runs: the batch owns the states then.
    @discardableResult
    public func refresh() -> Task<Void, Never> {
        guard !isUploading else { return Task {} }
        checkTask?.cancel()
        reloadFromDisk()
        let task = Task { await self.checkDrive() }
        checkTask = task
        return task
    }

    private func reloadFromDisk() {
        let known = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, ($0.state, $0.driveName)) })
        let clips: [SortedClip]
        do {
            clips = try source.clips()
            readProblem = nil
        } catch {
            readProblem = "Could not read the sorted clips: \(error.localizedDescription)"
            clips = []
        }
        entries = clips.map { clip in
            let size = (try? clip.file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            var (state, driveName) = known[clip.file] ?? (.waiting, nil)
            if state == .uploading { state = .waiting }
            return Entry(clip: clip, size: Int64(size), state: state, driveName: driveName)
        }
    }

    /// Lookups only. A missing folder means nothing below it is there, so it
    /// is answered without creating anything — refreshing the tray must not
    /// leave empty folders in the club's drive.
    private func checkDrive() async {
        checkProblem = nil
        isCheckingDrive = true
        defer { isCheckingDrive = false }
        var folders: [[String]: String?] = [:]
        for id in entries.filter({ $0.state == .waiting }).map(\.id) {
            guard !Task.isCancelled, let clip = entry(id)?.clip else { return }
            do {
                guard let parent = try await existingFolder(for: clip, memo: &folders) else { continue }
                if case let .alreadyThere(name) = try await placement(of: clip, in: parent),
                   let index = index(of: id), entries[index].state == .waiting {
                    entries[index].state = .alreadyInDrive
                    entries[index].driveName = Self.driveName(name, for: clip)
                }
            } catch {
                if Self.isCancellation(error) { return }
                checkProblem = "Could not check \(libraryName) for clips already there "
                    + "(\(error.localizedDescription)). Uploading still skips any that are."
                return
            }
        }
    }

    private func existingFolder(for clip: SortedClip, memo: inout [[String]: String?]) async throws -> String? {
        var parent = target.destination.rootID
        var path: [String] = []
        for name in target.destination.folderNames(for: clip) {
            path.append(name)
            if let known = memo[path] {
                guard let known else { return nil }
                parent = known
                continue
            }
            let found = try await target.provider.findFolder(named: name, parent: parent)
            memo[path] = .some(found?.id)
            guard let found else { return nil }
            parent = found.id
        }
        return parent
    }

    // MARK: - The batch

    /// Uploads every waiting clip, in tray order.
    @discardableResult
    public func uploadWaiting() -> Task<Void, Never> {
        start(entries.filter { $0.state == .waiting }.map(\.id))
    }

    /// Tries one failed clip again, without re-tagging anything.
    @discardableResult
    public func retry(_ id: Entry.ID) -> Task<Void, Never> {
        guard let entry = entry(id), case .failed = entry.state else { return Task {} }
        return start([id])
    }

    @discardableResult
    public func retryFailed() -> Task<Void, Never> {
        start(entries.filter { if case .failed = $0.state { return true } else { return false } }.map(\.id))
    }

    /// Stops after, or within, the current clip. That clip goes back to
    /// waiting; nothing is marked failed for it.
    public func cancel() {
        checkTask?.cancel()
        batchTask?.cancel()
    }

    private func start(_ ids: [Entry.ID]) -> Task<Void, Never> {
        guard !isUploading, !ids.isEmpty else { return Task {} }
        // A slow courtesy check must not hold the batch up; the batch makes
        // its own check before every upload.
        checkTask?.cancel()
        isUploading = true
        stopReason = nil
        runTotal = ids.count
        runDone = 0
        let task = Task { await self.run(ids) }
        batchTask = task
        return task
    }

    private func run(_ ids: [Entry.ID]) async {
        defer { isUploading = false }
        do {
            // Once per batch, before anything: a token minted for reading
            // cannot write, and finding that out at the first upload would
            // waste the folder walk.
            try await target.provider.authorizeWrites(presenter: target.presenter)
        } catch {
            if !Self.isCancellation(error) { stopReason = error.localizedDescription }
            return
        }

        // Folder ids for this run only. The next run walks again, so a folder
        // someone deleted or renamed in between is found or recreated rather
        // than written into from memory.
        var folders: [[String]: String] = [:]
        for id in ids {
            if Task.isCancelled { return }
            guard let index = index(of: id) else { continue }
            let clip = entries[index].clip
            entries[index].state = .uploading
            let outcome: ClipState
            var driveName: String?
            do {
                let parent = try await folderCreatingAsNeeded(for: clip, memo: &folders)
                switch try await placement(of: clip, in: parent) {
                case let .alreadyThere(name):
                    outcome = .alreadyInDrive
                    driveName = Self.driveName(name, for: clip)
                case let .free(name):
                    _ = try await target.provider.upload(fileAt: clip.file, named: name, parent: parent)
                    outcome = .uploaded
                    driveName = Self.driveName(name, for: clip)
                }
            } catch {
                if Self.isCancellation(error) {
                    setState(.waiting, for: id)
                    return
                }
                if Self.stopsTheBatch(error) {
                    setState(.waiting, for: id)
                    stopReason = "Stopped at \(clip.file.lastPathComponent): \(error.localizedDescription)"
                    return
                }
                outcome = .failed(error.localizedDescription)
            }
            setState(outcome, for: id)
            if let current = self.index(of: id) { entries[current].driveName = driveName }
            runDone += 1
        }
    }

    private func folderCreatingAsNeeded(for clip: SortedClip, memo: inout [[String]: String]) async throws -> String {
        var parent = target.destination.rootID
        var path: [String] = []
        for name in target.destination.folderNames(for: clip) {
            path.append(name)
            if let known = memo[path] {
                parent = known
                continue
            }
            parent = try await target.provider.findOrCreateFolder(named: name, parent: parent).id
            memo[path] = parent
        }
        return parent
    }

    // MARK: - Same name, different clip

    /// Where a clip stands in its Drive folder.
    enum Placement: Equatable {
        /// This name holds this clip already: skip it.
        case alreadyThere(String)
        /// Nothing has this name: upload the clip under it.
        case free(String)
    }

    /// How many names `placement` tries — the clip's own, then " 2" up to this
    /// — before giving up on the clip. Far beyond any real collision (it takes
    /// that many *different* same-named clips for one athlete on one day); it
    /// exists so a Drive that answered every lookup with a mismatch could not
    /// keep the batch asking forever.
    static let maxNumberedName = 50

    /// Finds the name a clip has, or should have, in its folder.
    ///
    /// A name match alone is not proof the clip is there: two iPhones both
    /// number their clips IMG_0001…, so the second coach's IMG_0413 would
    /// read as "In Drive" and silently never upload. So a match must also
    /// agree on size (Drive's `size` against the bytes on disk). Same name and
    /// size: this clip, skip. Same name, other size: a different clip, try
    /// "<stem> 2.<ext>", then 3, … and stop at the first name that is either
    /// free (upload there) or holds this clip (a previous run already put it
    /// there — skip).
    ///
    /// Idempotent across kills because it is recomputed from Drive every
    /// time: the renamed upload is found again by the same walk, with the same
    /// size, and nothing remembered is needed. Size is a heuristic, not a
    /// checksum — two different clips of identical byte count would read as
    /// one; for re-encoded camera footage that is not expected, but it is not
    /// proven impossible.
    ///
    /// A match whose size Drive does not report is treated as this clip. Per
    /// Drive's documentation `size` is populated for every uploaded binary
    /// file and missing only for folders, shortcuts and Google-native
    /// documents (not verified against the live API), so this should not
    /// arise for a clip; if it did, skipping is the failure that fills the
    /// club Drive with nothing, where uploading would add a copy on every run.
    func placement(of clip: SortedClip, in parent: String) async throws -> Placement {
        let size = Self.localSize(of: clip.file)
        let own = clip.file.lastPathComponent
        for number in 1...Self.maxNumberedName {
            let name = Self.numberedName(own, number)
            guard let found = try await target.provider.findFile(named: name, parent: parent) else {
                return .free(name)
            }
            if found.size == nil || found.size == size { return .alreadyThere(name) }
        }
        throw RemoteUploadError.retryClip(
            "\(Self.numberedName(own, 2)) to \(Self.numberedName(own, Self.maxNumberedName)) are all other clips in Drive.")
    }

    /// "IMG_0413.mov" for 1, "IMG_0413 2.mov" for 2 — the form the user chose
    /// for the final-review fix.
    static func numberedName(_ name: String, _ number: Int) -> String {
        guard number > 1 else { return name }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
    }

    /// The size `GoogleDriveProvider.upload` sends, read the same way, so the
    /// number compared is the number that went up.
    private static func localSize(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private static func driveName(_ name: String, for clip: SortedClip) -> String? {
        name == clip.file.lastPathComponent ? nil : name
    }

    // MARK: - Helpers

    private func index(of id: Entry.ID) -> Int? { entries.firstIndex { $0.id == id } }
    private func entry(_ id: Entry.ID) -> Entry? { index(of: id).map { entries[$0] } }

    private func setState(_ state: ClipState, for id: Entry.ID) {
        guard let index = index(of: id) else { return }
        entries[index].state = state
    }

    private static func stopsTheBatch(_ error: Error) -> Bool {
        if case .stopBatch = error as? RemoteUploadError { return true }
        return (error as? RemoteLibraryError) == .notSignedIn
    }

    /// A cancelled `Task` can surface as any of these depending on which layer
    /// noticed first; any of them, or the task itself being cancelled, means
    /// the coach stopped it rather than Drive refusing.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError || Task.isCancelled { return true }
        if (error as? URLError)?.code == .cancelled { return true }
        return (error as? RemoteLibraryError) == .cancelled
    }
}
