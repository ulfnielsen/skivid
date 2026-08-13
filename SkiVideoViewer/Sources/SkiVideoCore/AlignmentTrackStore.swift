import Foundation

/// Reads and writes the sidecar that stores how a pair of clips align.
///
/// A track describes a *pair*, so it cannot live in either clip's own
/// sidecar — the way `ClipAnalysisStore` shapes a single clip's sidecar.
/// Instead it sits beside the **left** clip, named after both stems so it
/// cannot collide with another pair that happens to share a left clip.
public enum AlignmentTrackStore {
    public static let fileExtension = "skialignment.json"

    /// `<leftStem>--<rightStem>.skialignment.json`, beside `left` — but only
    /// when both sides are local.
    ///
    /// A pair with a remote side has no shared folder to sit in. Putting it
    /// beside the local half would orphan the track the moment that folder
    /// moved, and would file a record half of which describes a clip the
    /// folder never held. Such pairs go to the keyed store, named from both
    /// identities so the two spellings cannot collide.
    public static func sidecarURL(left: ClipIdentity, right: ClipIdentity) -> URL {
        if case let .local(leftClip) = left, case let .local(rightClip) = right {
            let leftStem = leftClip.deletingPathExtension().lastPathComponent
            let rightStem = rightClip.deletingPathExtension().lastPathComponent
            return leftClip.deletingLastPathComponent()
                .appendingPathComponent("\(leftStem)--\(rightStem)")
                .appendingPathExtension(fileExtension)
        }
        return ClipIdentity.keyedStoreRoot
            .appendingPathComponent("\(pairKey(left))--\(pairKey(right))")
            .appendingPathExtension(fileExtension)
    }

    /// Whether this pair belongs in the keyed store rather than beside the
    /// left clip. The rule lives here alone — `sidecarURL` and `save` both ask
    /// it, so neither can drift from the other.
    private static func isKeyed(left: ClipIdentity, right: ClipIdentity) -> Bool {
        if case .local = left, case .local = right { return false }
        return true
    }

    public static func sidecarURL(left: URL, right: URL) -> URL {
        sidecarURL(left: ClipIdentity(left), right: ClipIdentity(right))
    }

    /// A local half of a mixed pair still needs a name in the keyed store, and
    /// its stem alone is not unique across a library. The full path, escaped
    /// by the same rule `ClipIdentity` uses for ids, is.
    private static func pairKey(_ identity: ClipIdentity) -> String {
        if let key = identity.storeKey { return key }
        guard case let .local(clip) = identity else { return "unkeyed" }
        return "local-" + String(clip.path.map { character in
            character.isLetter || character.isNumber || character == "-"
                ? character
                : "_"
        })
    }

    /// The stored track, or nil when there is none or it cannot be read.
    ///
    /// An unreadable sidecar reads as absent, exactly as
    /// `ClipAnalysisStore.load` does. A track written in an older convention is
    /// refused, not adapted — see the version note below.
    public static func load(left: ClipIdentity, right: ClipIdentity) -> AlignmentTrack? {
        guard let data = try? Data(contentsOf: sidecarURL(left: left, right: right))
        else { return nil }
        guard let track = try? decoder.decode(AlignmentTrack.self, from: data)
        else { return nil }
        // A track written in an older convention is refused, not adapted. Only
        // one older version exists — version 1 stored `dy` in Vision's y-up
        // space — and a reader applying it would push the two clips apart by
        // exactly the amount it should have brought them together, with nothing
        // on screen to say so. Refusing costs one recomputation; using it costs
        // the operator's trust in every alignment they look at afterwards.
        guard track.version >= AlignmentTrack.currentVersion else { return nil }
        return track
    }

    public static func load(left: URL, right: URL) -> AlignmentTrack? {
        load(left: ClipIdentity(left), right: ClipIdentity(right))
    }

    /// Writes the sidecar, throwing if it cannot. Callers surface the failure
    /// to the operator once and carry on using the track in memory — an
    /// unwritable footage folder is a persistence problem, not an alignment
    /// failure.
    public static func save(
        _ track: AlignmentTrack, left: ClipIdentity, right: ClipIdentity
    ) throws {
        let url = sidecarURL(left: left, right: right)
        // Only the keyed store can be missing. A footage folder exists by
        // definition — the clip is in it.
        if isKeyed(left: left, right: right) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        }
        try encoder.encode(track).write(to: url, options: .atomic)
    }

    public static func save(_ track: AlignmentTrack, left: URL, right: URL) throws {
        try save(track, left: ClipIdentity(left), right: ClipIdentity(right))
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
