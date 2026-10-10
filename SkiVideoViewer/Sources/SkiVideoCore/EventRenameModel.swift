import Foundation

/// What an event holds, for the "Merge?" question.
public struct EventClipCount: Equatable, Sendable {
    public let clips: Int
    public let athletes: Int

    public init(clips: Int, athletes: Int) {
        self.clips = clips
        self.athletes = athletes
    }
}

/// Runs one event's rename: plans from the live folders, executes step by
/// step with progress, and stops with a reason the coach can act on. Running
/// it again re-plans, so a rename stopped partway finishes instead of
/// repeating what already happened.
@MainActor
public final class EventRenameModel: ObservableObject {
    public let oldName: String
    private let eventFolders: [[String]]
    private let folders: any EventFolderWriting

    @Published public private(set) var done = 0
    @Published public private(set) var total = 0
    @Published public private(set) var isRunning = false
    @Published public private(set) var stopReason: String?
    @Published public private(set) var leftInPlace: [[String]] = []

    public init(oldName: String, eventFolders: [[String]], folders: any EventFolderWriting) {
        self.oldName = oldName
        self.eventFolders = eventFolders
        self.folders = folders
    }

    /// Whether `newName` already exists where this rename would put it — the
    /// moment to ask "Merge?", before anything moves.
    public func targetExists(newName: String) async throws -> Bool {
        try await EventRenamePlanner.plan(eventFolders: eventFolders, newName: newName, in: folders)
            .mergesIntoExisting
    }

    @discardableResult
    public func run(newName: String, allowMerge: Bool = false) async -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        defer { isRunning = false }
        stopReason = nil
        done = 0
        total = 0
        leftInPlace = []
        do {
            try await folders.prepareToWrite()
            let plan = try await EventRenamePlanner.plan(eventFolders: eventFolders, newName: newName, in: folders)
            // targetExists and this plan are separate reads, and prepareToWrite
            // (Drive's consent sheet) can sit between them for as long as the
            // coach takes. If the target appeared meanwhile, the coach was never
            // asked about merging, so stop before anything moves.
            if plan.mergesIntoExisting && !allowMerge {
                stopReason = "\u{201C}\(newName)\u{201D} now exists \u{2014} choose Merge or another name."
                return false
            }
            total = plan.steps.count
            for step in plan.steps {
                switch step {
                case let .rename(path, newName):
                    try await folders.rename(path, to: newName)
                case let .move(name, source, destination):
                    try await folders.move(name, from: source, to: destination)
                case let .removeIfEmpty(path):
                    _ = try await folders.removeIfEmpty(path)
                }
                done += 1
            }
            leftInPlace = plan.leftInPlace
            return true
        } catch {
            stopReason = Self.reason(for: error, done: done, total: total)
            return false
        }
    }

    /// The upload's split: no access or signed out stops outright; anything
    /// else is worth another try, and says how far it got.
    private static func reason(for error: Error, done: Int, total: Int) -> String {
        if case let RemoteUploadError.stopBatch(message) = error { return message }
        // A stop, not a retry: every further write would be refused the same way.
        if case RemoteUploadError.noWriteAccess = error {
            return "You don't have permission to change folders in this library."
        }
        if case RemoteLibraryError.notSignedIn = error { return "Sign in to Google Drive again, then try again." }
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return "Stopped after \(done) of \(total). Rename again to finish."
        }
        var detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        // Messages from Drive usually end in a full stop already; add one only
        // when missing so the sentence never doubles it.
        if !detail.hasSuffix(".") { detail += "." }
        return "Renamed \(done) of \(total). \(detail) Try again."
    }
}
