import Foundation

/// Reads and writes the sidecar that sits beside a clip.
///
/// A sidecar rather than a library index or an application-support cache
/// because it travels with the footage: copy an athlete's folder to another
/// machine and the analysis goes with it, and the file stays readable and
/// correctable by hand. That is true for local clips; an identity with no
/// folder of its own — a remote clip — has nowhere to sit beside, so it
/// falls back to the keyed store under `ClipIdentity.keyedStoreRoot`.
public enum ClipAnalysisStore {
    public static let fileExtension = "skianalysis.json"

    /// Where this identity's analysis is written.
    ///
    /// A local clip's sidecar sits beside the footage, which is the whole
    /// reason this store exists in this shape: copy an athlete's folder to
    /// another machine and the analysis travels with it. An identity with no
    /// folder of its own falls back to the keyed store.
    public static func sidecarURL(for identity: ClipIdentity) -> URL {
        switch identity {
        case let .local(clip):
            return clip.deletingPathExtension().appendingPathExtension(fileExtension)
        case .remote:
            return ClipIdentity.keyedStoreRoot
                .appendingPathComponent(identity.pairKey)
                .appendingPathExtension(fileExtension)
        }
    }

    public static func sidecarURL(for clip: URL) -> URL {
        sidecarURL(for: ClipIdentity(clip))
    }

    /// The stored analysis, or nil when there is none or it cannot be read.
    ///
    /// An unreadable sidecar reads as absent rather than as an error: it may be
    /// a newer version or hand-edited, and the caller's only sensible response
    /// is to offer analysis again. `save` must never overwrite one it could not
    /// parse — see its note.
    public static func load(for identity: ClipIdentity) -> ClipAnalysis? {
        guard let data = try? Data(contentsOf: sidecarURL(for: identity)) else { return nil }
        return try? decoder.decode(ClipAnalysis.self, from: data)
    }

    public static func load(for clip: URL) -> ClipAnalysis? {
        load(for: ClipIdentity(clip))
    }

    /// Writes the sidecar, throwing if it cannot. Callers surface the failure
    /// to the operator once and carry on using the analysis in memory — an
    /// unwritable footage folder is a persistence problem, not an analysis
    /// failure.
    public static func save(_ analysis: ClipAnalysis, for identity: ClipIdentity) throws {
        let url = sidecarURL(for: identity)
        // Only the keyed store can be missing. A local clip's folder exists by
        // definition — the clip is in it — and creating directories under a
        // footage folder is not this store's business.
        if identity.storeKey != nil {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        }
        try encoder.encode(analysis).write(to: url, options: .atomic)
    }

    public static func save(_ analysis: ClipAnalysis, for clip: URL) throws {
        try save(analysis, for: ClipIdentity(clip))
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
