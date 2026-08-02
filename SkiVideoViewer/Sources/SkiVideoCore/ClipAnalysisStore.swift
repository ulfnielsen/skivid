import Foundation

/// Reads and writes the sidecar that sits beside a clip.
///
/// A sidecar rather than a library index or an application-support cache
/// because it travels with the footage: copy an athlete's folder to another
/// machine and the analysis goes with it, and the file stays readable and
/// correctable by hand.
public enum ClipAnalysisStore {
    public static let fileExtension = "skianalysis.json"

    public static func sidecarURL(for clip: URL) -> URL {
        clip.deletingPathExtension().appendingPathExtension(fileExtension)
    }

    /// The stored analysis, or nil when there is none or it cannot be read.
    ///
    /// An unreadable sidecar reads as absent rather than as an error: it may be
    /// a newer version or hand-edited, and the caller's only sensible response
    /// is to offer analysis again. `save` must never overwrite one it could not
    /// parse — see its note.
    public static func load(for clip: URL) -> ClipAnalysis? {
        guard let data = try? Data(contentsOf: sidecarURL(for: clip)) else { return nil }
        return try? decoder.decode(ClipAnalysis.self, from: data)
    }

    /// Writes the sidecar, throwing if it cannot. Callers surface the failure
    /// to the operator once and carry on using the analysis in memory — an
    /// unwritable footage folder is a persistence problem, not an analysis
    /// failure.
    public static func save(_ analysis: ClipAnalysis, for clip: URL) throws {
        try encoder.encode(analysis).write(to: sidecarURL(for: clip), options: .atomic)
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
