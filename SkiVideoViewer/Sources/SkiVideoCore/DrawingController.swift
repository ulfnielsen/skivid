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
    private var identity: ClipIdentity?
    private var isDirty = false
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
        isDrawing = false
        observation = nil
        session = nil
        notice = nil
        isDirty = false
        self.identity = identity
        guard let identity else { return }
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
        guard isDirty, let identity, let session else { return }
        do {
            try ClipDrawingsStore.save(session.drawings, for: identity)
            isDirty = false
            if notice?.hasPrefix("Couldn't save") == true { notice = nil }
        } catch {
            // Kept in memory and on screen; the next change retries.
            notice = "Couldn't save drawings: \(error.localizedDescription)"
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
