import CryptoKit
import Foundation

/// What a clip *is*, independent of where its bytes currently sit.
///
/// A local clip is its standardised file URL, which is what every store in
/// this module keyed on before cloud libraries existed. A remote clip has no
/// path at all — only the provider that owns it and that provider's stable
/// file id — so anything derived from it has to be keyed rather than placed.
public enum ClipIdentity: Hashable, Sendable {
    /// Always standardised — construct through `init(_:)` rather than writing
    /// `.local(url)`, or two spellings of one path become two identities with
    /// two sidecars.
    case local(URL)
    case remote(provider: String, fileID: String)

    /// The identity of a clip the app already holds as a file.
    ///
    /// Standardised, so `/a/./b.mp4` and `/a/b.mp4` are one identity rather
    /// than two sidecars. Standardising consults the filesystem, not just the
    /// text of the URL — `/private/tmp/X` resolves to `/tmp/X` when `X`
    /// exists on disk and stays unchanged when it does not — so this type is
    /// not a pure function of the URL alone. Local placement does not care
    /// (same inode either way), but a future index that persists this type
    /// across launches would see the difference.
    public init(_ clip: URL) {
        self = .local(clip.standardizedFileURL)
    }

    /// A filesystem-safe name for this identity in the keyed store, or nil
    /// when the identity has a folder of its own and needs no key.
    ///
    /// Nil for `.local` is deliberate and load-bearing: it is how the stores
    /// tell "put this beside the footage" from "put this in the keyed store",
    /// rather than each of them re-matching on the case.
    public var storeKey: String? {
        switch self {
        case .local: return nil
        case .remote: return pairKey
        }
    }

    /// A filesystem-safe name for this identity that is safe to *combine* with
    /// another into one filename.
    ///
    /// Defined for local identities too, unlike `storeKey`, because a pair can
    /// straddle the two: comparing a cloud clip against one on disk files the
    /// track under both halves.
    ///
    /// The local half is a digest of the path, not an escaped copy of it.
    /// Escaping is lossy — distinct paths can fold to one name, since
    /// `escape` maps every character it does not pass through to the same
    /// `_` — so `/Ski Team 2026/run.mp4` and `/Ski_Team_2026/run.mp4` would
    /// name the same file and one alignment track would silently overwrite
    /// the other's. A digest also bounds the length, which an escaped
    /// absolute path does not: a deep path can exceed a filesystem's
    /// 255-byte name limit.
    ///
    /// The remote half's join relies on an invariant `pairKey` cannot check:
    /// `provider` is a compile-time constant under this project's control,
    /// not user input, and must never be the literal `"local"` (or its key
    /// would be indistinguishable from a local digest) and must never
    /// contain `-` (joining with `-` is not injective — `("gdrive","AB-C")`
    /// and `("gdrive-AB","C")` both key `gdrive-AB-C`). `fileID` may contain
    /// `-` freely; only `provider` carries this restriction.
    public var pairKey: String {
        switch self {
        case let .local(clip):
            let digest = SHA256.hash(data: Data(clip.path.utf8))
            return "local-" + digest.prefix(8)
                .map { String(format: "%02x", $0) }
                .joined()
        case let .remote(provider, fileID):
            return "\(Self.escape(provider))-\(Self.escape(fileID))"
        }
    }

    /// Anything that is not a letter, a number, or `-` becomes an underscore.
    ///
    /// "Letter" and "number" mean `Character.isLetter`/`.isNumber`, which are
    /// Unicode-wide — not `[A-Za-z0-9]` — so this is not unreserved-URL-safe:
    /// `escape("café été")` is `café_été`, with the accented letters passing
    /// through untouched. That is fine for this use: the goal is only to keep
    /// path-breaking characters out of a filename, not to produce an ASCII or
    /// URL-safe string. Drive's file ids are URL-safe base64 today and would
    /// survive unescaped, but a key is a *filename*: one "/" in an id that a
    /// future provider hands back would write outside the store, and ".."
    /// would climb out of it. Escaping here costs nothing and removes the
    /// question.
    private static func escape(_ value: String) -> String {
        String(value.map { character in
            character.isLetter || character.isNumber || character == "-"
                ? character
                : "_"
        })
    }

    /// Where keyed sidecars live.
    ///
    /// A `var` so tests can point it at a temporary directory; nothing in the
    /// app writes to it. Application Support rather than Caches because an
    /// analysis is minutes of computation over a clip that may no longer be
    /// cached, and losing it to a cache purge would be a bad trade.
    public static var keyedStoreRoot: URL = defaultKeyedStoreRoot()

    private static func defaultKeyedStoreRoot() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("SkiVideoViewer", isDirectory: true)
            .appendingPathComponent("ClipAnalysis", isDirectory: true)
    }
}
