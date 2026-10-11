import Combine
import Foundation

/// The current clip's drawings: which session is live, whether the coach is
/// drawing, whether saved marks are shown, and getting them to disk.
///
/// Owned by `ViewerModel`, which tells it when the clip changes and when the
/// coach steps; a separate object so the viewer's 1,700-line model gains a
/// handful of calls rather than this whole lifecycle.
@MainActor
public final class DrawingController: ObservableObject {
    public static let unreadableNotice = "Drawings for this clip couldn't be read."
    private static let showKey = "ShowDrawings"

    @Published public private(set) var isDrawing = false
    @Published public var showsDrawings: Bool {
        didSet { defaults.set(showsDrawings, forKey: Self.showKey) }
    }
    /// Nil with no clip, and for a clip whose drawings file is unreadable —
    /// which is what refuses drawing there.
    @Published public private(set) var session: DrawingSession?
    @Published public private(set) var notice: String?

    private let defaults: UserDefaults
    private let saveDelay: TimeInterval
    /// The clip whose session is live; `ViewerModel` compares against it to
    /// tell a real clip change from a reload of the same clip.
    public private(set) var identity: ClipIdentity?
    private var isDirty = false
    /// Drawings whose save failed, by clip. A failed save must not lose the
    /// marks when the coach moves on (read-only or ejected volume, or an event
    /// rename inside the debounce that leaves the stored identity's folder
    /// gone): they stay here, are restored if the clip reopens, and are retried
    /// by every later `saveNow`. An entry leaves only when its save succeeds.
    private var unsaved: [ClipIdentity: ClipDrawings] = [:]
    private static let failurePrefix = "Couldn't save"
    private var saveTask: Task<Void, Never>?
    private var observation: AnyCancellable?

    public init(defaults: UserDefaults = .standard, saveDelay: TimeInterval = 1) {
        self.defaults = defaults
        self.saveDelay = saveDelay
        showsDrawings = defaults.object(forKey: Self.showKey) as? Bool ?? true
    }

    /// Saves the previous clip's marks, then reads this one's. The same
    /// identity again is a no-op: a Drive clip's `loadCurrentVideo` runs twice
    /// (selected, then bytes landed), and reloading would discard the session.
    public func load(for identity: ClipIdentity?) {
        if let identity, identity == self.identity { return }
        session?.cancelInProgress()
        saveNow()
        if isDirty, let old = self.identity, let session { unsaved[old] = session.drawings }
        isDrawing = false
        observation = nil
        session = nil
        // The failure notice outlives the switch while anything is unsaved.
        if unsaved.isEmpty || notice?.hasPrefix(Self.failurePrefix) != true { notice = nil }
        isDirty = false
        self.identity = identity
        guard let identity else { return }
        if let pending = unsaved[identity] {
            // Memory is newer than disk: a save of this clip failed earlier.
            attach(DrawingSession(drawings: pending))
            isDirty = true
            return
        }
        switch ClipDrawingsStore.load(for: identity) {
        case .none: attach(DrawingSession())
        case let .drawings(drawings): attach(DrawingSession(drawings: drawings))
        case .unreadable: notice = Self.unreadableNotice
        }
    }

    func enter() { isDrawing = true }

    func leave() {
        session?.cancelInProgress()
        isDrawing = false
        saveNow()
    }

    public func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        var failure: Error?
        if isDirty, let identity, let session {
            do {
                try ClipDrawingsStore.save(session.drawings, for: identity)
                isDirty = false
                unsaved[identity] = nil
            } catch {
                // Kept in memory and on screen; the next change retries.
                failure = error
            }
        }
        // Other clips whose save failed earlier. The store refuses a file
        // that has become unreadable, so those simply stay pending.
        for (other, drawings) in unsaved where other != identity {
            do {
                try ClipDrawingsStore.save(drawings, for: other)
                unsaved[other] = nil
            } catch {
                failure = failure ?? error
            }
        }
        if let failure {
            notice = "\(Self.failurePrefix) drawings: \(failure.localizedDescription)"
        } else if unsaved.isEmpty, !isDirty, notice?.hasPrefix(Self.failurePrefix) == true {
            notice = nil
        }
    }

    private func attach(_ session: DrawingSession) {
        self.session = session
        observation = session.$drawings.dropFirst().sink { [weak self] _ in
            self?.isDirty = true
            self?.scheduleSave()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let delay = UInt64(saveDelay * 1_000_000_000)
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }
}
