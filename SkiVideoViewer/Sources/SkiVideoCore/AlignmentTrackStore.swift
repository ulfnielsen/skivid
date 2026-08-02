import Foundation

/// Reads and writes the sidecar that stores how a pair of clips align.
///
/// A track describes a *pair*, so it cannot live in either clip's own
/// sidecar — the way `ClipAnalysisStore` shapes a single clip's sidecar.
/// Instead it sits beside the **left** clip, named after both stems so it
/// cannot collide with another pair that happens to share a left clip.
public enum AlignmentTrackStore {
    public static let fileExtension = "skialignment.json"

    /// `<leftStem>--<rightStem>.skialignment.json`, beside `left`.
    public static func sidecarURL(left: URL, right: URL) -> URL {
        let leftStem = left.deletingPathExtension().lastPathComponent
        let rightStem = right.deletingPathExtension().lastPathComponent
        return left.deletingLastPathComponent()
            .appendingPathComponent("\(leftStem)--\(rightStem)")
            .appendingPathExtension(fileExtension)
    }

    /// The stored track, or nil when there is none or it cannot be read.
    ///
    /// An unreadable sidecar reads as absent rather than as an error, exactly
    /// as `ClipAnalysisStore.load` does: it may be a newer version or
    /// hand-edited, and the caller's only sensible response is to offer to
    /// compute alignment again. `save` must never overwrite one it could not
    /// parse — see its note.
    public static func load(left: URL, right: URL) -> AlignmentTrack? {
        guard let data = try? Data(contentsOf: sidecarURL(left: left, right: right))
        else { return nil }
        return try? decoder.decode(AlignmentTrack.self, from: data)
    }

    /// Writes the sidecar, throwing if it cannot. Callers surface the failure
    /// to the operator once and carry on using the track in memory — an
    /// unwritable footage folder is a persistence problem, not an alignment
    /// failure.
    public static func save(_ track: AlignmentTrack, left: URL, right: URL) throws {
        try encoder.encode(track).write(
            to: sidecarURL(left: left, right: right), options: .atomic
        )
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
