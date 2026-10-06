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
/// folder). Being killed mid-batch is normal on a hill — a phone pocketed, a
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
        /// Drive already had a file of this name in the clip's folder.
        case alreadyInDrive
        case failed(String)
    }

    public struct Entry: Identifiable, Equatable {
        public let clip: SortedClip
        /// Bytes on disk.
        public let size: Int64
        public internal(set) var state: ClipState
        public var id: URL { clip.file }
    }

    @Published public private(set) var entries: [Entry] = []
    @Published public private(set) var isUploading = false
    @Published public private(set) var isCheckingDrive = false
    /// Why the last batch stopped before its end. Nil after a clean run or a
    /// cancel.
    @Published public private(set) var stopReason: String?
    /// Why the tray could not ask Drive what it already has. Clips then show
    /// as waiting; the per-upload check still skips any already there.
    @Published public private(set) var checkProblem: String?
    /// Clips the running batch set out to send, and how many it has dealt
    /// with — uploaded, skipped or failed. The progress view's numbers.
    @Published public private(set) var runTotal = 0
    @Published public private(set) var runDone = 0

    public let root: URL
    private let target: UploadTarget
    private var batchTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?

    /// `root` is the sorted output directory — `<root>/<event>/<athlete>/<clip>`.
    public init(root: URL, target: UploadTarget) {
        self.root = root
        self.target = target
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
        let known = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.state) })
        let clips: [SortedClip]
        do {
            clips = try SortedOutput.clips(in: root)
        } catch {
            checkProblem = "Could not read the sorted clips: \(error.localizedDescription)"
            clips = []
        }
        entries = clips.map { clip in
            let size = (try? clip.file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            var state = known[clip.file] ?? .waiting
            if state == .uploading { state = .waiting }
            return Entry(clip: clip, size: Int64(size), state: state)
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
                let found = try await target.provider.findFile(named: clip.file.lastPathComponent, parent: parent)
                if found != nil, let index = index(of: id), entries[index].state == .waiting {
                    entries[index].state = .alreadyInDrive
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
            do {
                let parent = try await folderCreatingAsNeeded(for: clip, memo: &folders)
                let name = clip.file.lastPathComponent
                if try await target.provider.findFile(named: name, parent: parent) != nil {
                    outcome = .alreadyInDrive
                } else {
                    _ = try await target.provider.upload(fileAt: clip.file, named: name, parent: parent)
                    outcome = .uploaded
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
