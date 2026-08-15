import Foundation

/// Where a tagged clip's bytes come from and go to.
public struct PublishTargets: Sendable {
    /// What the resizer reads. For a local session this is the original's new
    /// home after the move; for a read-only source it is the source itself.
    public let resizeSource: URL
    public let resizeDestination: URL

    public init(resizeSource: URL, resizeDestination: URL) {
        self.resizeSource = resizeSource
        self.resizeDestination = resizeDestination
    }
}

/// The end-stage of a sorting session: what happens to a clip once a coach has
/// named the athlete in it.
///
/// It exists because that stage is the only part of sorting that differs
/// between a Mac pointed at a working folder and an iPad pointed at the SD
/// card still in the camera bag. Everything before it — the athlete search,
/// playback, the resize queue — is identical, and duplicating it for a second
/// platform would have been the alternative.
public protocol ClipPublisher: Sendable {
    /// True when the original must not be written to.
    ///
    /// `SortingModel` writes an athlete tag into the original before resizing
    /// it. That is a *write*, and on an SD card the card is the only archive of
    /// a training session, so it is skipped rather than attempted-and-failed:
    /// a failure there would abort a clip that is otherwise perfectly
    /// processable.
    var maySkipSourceMetadata: Bool { get }

    /// Prepares the filesystem for one clip and reports where the resize reads
    /// from and writes to. Throws rather than overwriting anything.
    func prepare(source: URL, athlete: String, event: String) throws -> PublishTargets
}

/// Today's Mac behaviour: the original is moved into
/// `<organizedRoot>/<event>/<athlete>/`, and the resize is written to the same
/// tail under `<resizedRoot>`.
public struct LocalFolderPublisher: ClipPublisher {
    public let maySkipSourceMetadata = false

    private let organizedRoot: URL
    private let resizedRoot: URL

    public init(organizedRoot: URL, resizedRoot: URL) {
        self.organizedRoot = organizedRoot
        self.resizedRoot = resizedRoot
    }

    public func prepare(source: URL, athlete: String, event: String) throws -> PublishTargets {
        let tail = "\(event)/\(athlete)/\(source.lastPathComponent)"
        let organized = organizedRoot.appendingPathComponent(tail)
        let resized = resizedRoot.appendingPathComponent(tail)

        // Both are checked before either is created, so a half-published clip
        // cannot be left behind by a collision on the second path.
        guard !FileManager.default.fileExists(atPath: organized.path),
              !FileManager.default.fileExists(atPath: resized.path) else {
            throw SortingError.outputExists(organized.path)
        }
        try FileManager.default.createDirectory(
            at: organized.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: source, to: organized)
        return PublishTargets(resizeSource: organized, resizeDestination: resized)
    }
}

/// For a source that must not be touched — an SD card still holding the only
/// copy of a session. The original stays exactly where it is and the resizer
/// reads it in place; only the resize is written, under `resizedRoot`.
public struct ReadOnlySourcePublisher: ClipPublisher {
    public let maySkipSourceMetadata = true

    private let resizedRoot: URL

    public init(resizedRoot: URL) {
        self.resizedRoot = resizedRoot
    }

    public func prepare(source: URL, athlete: String, event: String) throws -> PublishTargets {
        let resized = resizedRoot
            .appendingPathComponent("\(event)/\(athlete)/\(source.lastPathComponent)")
        guard !FileManager.default.fileExists(atPath: resized.path) else {
            throw SortingError.outputExists(resized.path)
        }
        try FileManager.default.createDirectory(
            at: resized.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        return PublishTargets(resizeSource: source, resizeDestination: resized)
    }
}
