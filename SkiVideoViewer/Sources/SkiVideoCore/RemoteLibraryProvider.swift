import CryptoKit
import Foundation

/// A filesystem-safe, length-bounded name for an arbitrary identifier.
///
/// Names the files this module writes: one index per Shared Drive, one cached
/// clip per file id. A digest rather than an escaped copy, because an
/// identifier is not a filename — escaping is lossy, so two distinct ids can
/// fold to one name and silently overwrite each other, and an escaped
/// identifier is unbounded where a filename component is capped at 255 bytes.
///
/// Deliberately *not* `ClipIdentity.pairKey`. That answers "what is this
/// clip's analysis filed under" and is half of a stored format; borrowing it
/// to name an unrelated file would tie two things that must stay free to
/// change apart.
enum StorageName {
    static func forIdentifier(_ identifier: String) -> String {
        SHA256.hash(data: Data(identifier.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// A cloud source of clips: what the app needs from Drive, and what it would
/// need from anything else.
///
/// Five methods, because five are what a library that only *reads* requires.
/// Deliberately absent: writes, thumbnails, quota, search, and a change feed.
/// A usable change feed exists for only some providers, so when a second one
/// arrives, delta belongs in its own optional protocol rather than as a stub
/// three implementations have to carry.
public protocol RemoteLibraryProvider: Sendable {
    /// Namespaces this provider's file ids. Becomes the scheme of a library
    /// URL and half of a `ClipIdentity`, so it must not change once anything
    /// has been indexed or cached.
    static var identifier: String { get }

    /// Interactive sign-in. Implementations persist their own refresh token.
    func connect(presenter: OAuthPresenter) async throws

    /// Non-interactive sign-in from whatever a previous session persisted.
    /// True when the provider can now authorize requests; false when it
    /// cannot, and a caller that can present UI should then `connect`.
    ///
    /// Not `throws`, and that is the design: there is exactly one thing a
    /// caller can do with any failure here, which is offer the ordinary
    /// sign-in prompt. A thrown error would invite showing the coach a message
    /// about a network call they never asked for — "Google Drive could not
    /// complete the Google sign-in (HTTP 400)" in place of a sign-in button —
    /// when the honest reading of every failure is simply "not signed in yet".
    /// The one thing a caller *must* do is offer that prompt: a resume that
    /// answers false and is met with an empty library looks like a bug, and is
    /// worse than being asked to sign in.
    ///
    /// An implementation that answers true must leave itself able to authorize
    /// requests, and one that discovers its stored credential was refused
    /// should discard it — but only when it was refused, never when the
    /// attempt merely failed to complete.
    func resumeSession() async -> Bool

    /// The top-level containers this provider can enumerate. One element is a
    /// fine answer.
    ///
    /// For Google Drive that means the account's Shared Drives, and
    /// deliberately not My Drive: a Shared Drive lists in one flat
    /// `corpora=drive` sweep, My Drive needs a different query shape
    /// altogether, and the club's footage lives in a Shared Drive. An
    /// implementation that cannot enumerate a container must not list it —
    /// a root that yields nothing is worse than a root that is absent.
    func roots() async throws -> [RemoteFolder]

    /// Every descendant *file* of `folder`, as an `AsyncThrowingStream`. For
    /// `GoogleDriveProvider` this does not yet show results before the sweep
    /// finishes — `sweep()` collects every page first, and the yield loop
    /// only replays what it already has — but the stream shape is worth
    /// keeping regardless: it is what lets a failure part-way through finish
    /// the stream by throwing rather than silently, which would show a half
    /// library as if it were whole, and it is what a future implementation
    /// that yields per-page would slot into without a signature change.
    func enumerate(_ folder: RemoteFolder) -> AsyncThrowingStream<RemoteFile, Error>

    /// Where to fetch this file's bytes. Minted per download and never stored
    /// in the index: any credential in it is short-lived.
    func downloadSource(for file: RemoteFile) async throws -> DownloadSource
}

public extension RemoteLibraryProvider {
    /// A provider that persists nothing has no previous session to resume.
    /// The default is false rather than absent so such a provider states that
    /// by saying nothing, instead of carrying a stub — and false is the safe
    /// answer either way: it costs one interactive sign-in, where a wrong true
    /// would leave a caller believing it can authorize requests it cannot.
    func resumeSession() async -> Bool { false }
}

public struct RemoteFolder: Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// What a provider offers when it has a change feed a client can use.
///
/// Separate from `RemoteLibraryProvider` because only some providers have one:
/// Drive and Dropbox do, an object store does not. A core method would make
/// three implementations carry a stub that just re-enumerates, which reads as
/// support for something that is not there. `ViewerModel.openRemoteLibrary`
/// is the one call site, and reaches this with exactly the cast this comment
/// used to only propose: `if let incremental = provider as? IncrementallyEnumerable`.
public protocol IncrementallyEnumerable: RemoteLibraryProvider {
    /// The cursor to start from, obtained once when the library is first swept.
    func startCursor(forRoot rootID: String) async throws -> String

    /// Everything that changed since `cursor`, and the cursor to use next.
    func changes(since cursor: String, forRoot rootID: String) async throws -> RemoteLibraryChanges
}

/// What a provider offers when a client may replace a file's contents.
///
/// Its own protocol for the same reason `IncrementallyEnumerable` is: writes
/// are deliberately absent from `RemoteLibraryProvider`, which describes a
/// library that only reads, and a core method would make every read-only
/// implementation carry a stub that throws. It is also the honest shape — the
/// permission to write is granted separately (see `GoogleOAuth.DriveScope`)
/// and can be refused independently of the ability to read.
///
/// One method, because repairing an oversized clip is the only write this app
/// performs. `ViewerModel.repairCurrentClip` is the one call site, and reaches
/// it with `as? ContentReplaceable`.
public protocol ContentReplaceable: RemoteLibraryProvider {
    /// Obtains permission to write, if this provider needs asking.
    ///
    /// Separate from `replaceContents` because consent and permission are
    /// different things and fail differently: this is the coach agreeing to
    /// let the app write, while the 403 that may still follow is the club's
    /// drive saying they may not. Called immediately before a repair rather
    /// than at sign-in, so a coach who never repairs a clip is never asked.
    func authorizeWrites(presenter: OAuthPresenter) async throws

    /// Replaces the file's bytes, keeping its id, and answers the new content
    /// version — the value the app stores as `RemoteFile.contentVersion`, and
    /// the thing that lets a cache tell the repaired clip from the original.
    ///
    /// **The id must be preserved.** Clip identity, analysis sidecars, sync
    /// points and the on-disk cache are all keyed on it.
    func replaceContents(ofFileID fileID: String, withFileAt url: URL) async throws -> String?
}

/// A folder or file this app created, or found already there.
public struct RemoteItem: Equatable, Sendable {
    public let id: String
    public let name: String
    /// Bytes, as Drive reports them. Only `findFile` asks for it — the upload
    /// batch compares it with the local clip to tell a re-run of the same clip
    /// from a different clip that shares its name. Nil where Drive gives none
    /// (folders, Google Docs) or where the caller did not ask.
    public let size: Int64?

    public init(id: String, name: String, size: Int64? = nil) {
        self.id = id
        self.name = name
        self.size = size
    }
}

/// How a failed upload should be handled by whoever is running a batch.
/// Not-signed-in still arrives as `RemoteLibraryError.notSignedIn`, which is
/// also "stop"; anything else untyped is a `RemoteLibraryError.api`.
public enum RemoteUploadError: LocalizedError, Equatable {
    /// Worth trying this clip again: the connection kept dropping, or the
    /// upload session expired (a retry opens a fresh one). The batch goes on.
    case retryClip(String)
    /// Every further clip would fail the same way — e.g. no edit access to
    /// the club's drive. Stop the batch.
    case stopBatch(String)
    /// Drive refused the write for want of edit access. Stops the batch like
    /// `.stopBatch`, but typed so the batch — which knows the folder the clip
    /// was going into, where the provider knows only its id — can say where.
    case noWriteAccess

    public var errorDescription: String? {
        switch self {
        case .retryClip(let message), .stopBatch(let message): return message
        case .noWriteAccess:
            return "You don't have permission to add clips to this folder in Google Drive."
        }
    }
}

/// What a provider offers when a client may create folders and upload new
/// files — the club-Drive upload, as opposed to `ContentReplaceable`'s repair
/// of a file that already exists.
///
/// Its own protocol for the reasons `ContentReplaceable` is: writes are absent
/// from `RemoteLibraryProvider`, and the upload code (and a test fake) should
/// depend on this shape rather than on `GoogleDriveProvider`. Reached with
/// `as? ItemCreatable`. It restates `authorizeWrites(presenter:)` rather than
/// inheriting `ContentReplaceable`, so a provider that can upload but not
/// replace does not have to stub `replaceContents`; `GoogleDriveProvider`
/// satisfies both with the one method, so there is a single consent path.
///
/// The `find…` lookups ask the provider itself, never anything the app
/// remembers: the app can be killed mid-batch, and "nothing uploads twice"
/// has to hold across that.
public protocol ItemCreatable: RemoteLibraryProvider {
    /// Same contract as `ContentReplaceable.authorizeWrites`.
    func authorizeWrites(presenter: OAuthPresenter) async throws

    /// A non-trashed folder called `name` directly inside `parentID`, or nil.
    func findFolder(named name: String, parent parentID: String) async throws -> RemoteItem?

    /// A non-trashed file (not a folder) called `name` directly inside
    /// `parentID`, or nil. What the upload's skip rule asks.
    func findFile(named name: String, parent parentID: String) async throws -> RemoteItem?

    /// Creates a folder. Does not look first — see `findOrCreateFolder`.
    func createFolder(named name: String, parent parentID: String) async throws -> RemoteItem

    /// `findFolder`, else `createFolder`, in that order, so two coaches
    /// filing the same event do not make two folders (barring a true race).
    func findOrCreateFolder(named name: String, parent parentID: String) async throws -> RemoteItem

    /// Uploads the file at `url` as a new file called `name` in `parentID`.
    /// Does not check for an existing file of that name; the caller does,
    /// with `findFile`. Retries within a bound and resumes from the server's
    /// offset; past that bound it throws `RemoteUploadError.retryClip`. A 403
    /// throws by its reason — `.retryClip` for a rate limit, `.stopBatch` for
    /// a full drive, `.noWriteAccess` otherwise; an expired session throws
    /// `.retryClip`.
    func upload(fileAt url: URL, named name: String, parent parentID: String) async throws -> RemoteItem
}

/// One entry in a Drive folder, as a rename needs to see it.
public struct RemoteChild: Equatable, Sendable {
    public let id: String
    public let name: String
    public let isFolder: Bool

    public init(id: String, name: String, isFolder: Bool) {
        self.id = id
        self.name = name
        self.isFolder = isFolder
    }
}

/// What a provider offers when a client may rename, move and bin what is
/// already there — the event rename's writes. Its own protocol for the same
/// reason `ItemCreatable` is: a read-only provider must not carry stubs.
///
/// Ids are preserved by every operation, so clip identity, analysis and the
/// cache survive (`RemoteFile.identity(inProvider:)` is the file id).
public protocol ItemUpdatable: ItemCreatable {
    /// Everything directly in the folder, not trashed. An incomplete listing
    /// throws rather than reading as fewer children.
    func listChildren(of folderID: String) async throws -> [RemoteChild]
    func rename(itemID: String, to newName: String) async throws
    func move(itemID: String, from oldParentID: String, to newParentID: String) async throws
    /// To the bin, recoverable for 30 days — never a permanent delete.
    func trash(itemID: String) async throws
}

public struct RemoteLibraryChanges: Sendable {
    public let changed: [RemoteFile]
    /// File ids that left the library. **Not a licence to delete cached
    /// bytes:** Drive reports "you lost access" and "moved to another corpus"
    /// the same way it reports a deletion, and a coach who regains access
    /// should not pay to download the clip again.
    public let removed: [String]
    public let cursor: String
    /// A folder in the library was renamed, moved or otherwise changed. Its
    /// clips are not in `changed` — Drive logs the folder, not what is under
    /// it — so their stored paths are stale and only a re-list corrects them.
    public let foldersChanged: Bool

    public init(changed: [RemoteFile], removed: [String], cursor: String, foldersChanged: Bool = false) {
        self.changed = changed
        self.removed = removed
        self.cursor = cursor
        self.foldersChanged = foldersChanged
    }
}

public struct RemoteFile: Hashable, Sendable, Codable {
    public let id: String
    public let name: String
    /// Folder names from the enumerated root down to this file's parent.
    /// The grouping rule reads the last two; nothing may parse `id`.
    public let path: [String]
    public let size: Int64
    /// Opaque. Equal means the bytes are unchanged — Drive's `headRevisionId`.
    /// Nil means never reuse a cached copy, because nothing can confirm it is
    /// still current.
    public let contentVersion: String?
    /// For checking the bytes after a download. Absent for some files, so a
    /// cache cannot depend on having it.
    public let md5: String?
    /// Pixel dimensions and duration as Drive reports them, or nil when it has
    /// not said. Drive fills `videoMediaMetadata` in asynchronously after an
    /// upload, so a clip added minutes ago legitimately carries none — see
    /// `ClipWeight`, which treats absent metadata as "do not judge" rather than
    /// as a zero.
    public let width: Int?
    public let height: Int?
    public let durationMillis: Int?

    /// The three metadata values default to nil so every existing construction
    /// site — the index, the change feed, the tests written before this
    /// existed — keeps compiling and keeps meaning what it meant.
    public init(
        id: String, name: String, path: [String],
        size: Int64, contentVersion: String?, md5: String?,
        width: Int? = nil, height: Int? = nil, durationMillis: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.contentVersion = contentVersion
        self.md5 = md5
        self.width = width
        self.height = height
        self.durationMillis = durationMillis
    }

    /// What this clip's analysis is keyed on.
    ///
    /// The file id alone, so a clip renamed or moved in Drive keeps the
    /// alignment and pose work already done on it — the thing a path-keyed
    /// sidecar could never manage.
    public func identity(inProvider provider: String) -> ClipIdentity {
        .remote(provider: provider, fileID: id)
    }
}

/// A URL plus the headers that must accompany every request to it.
///
/// Headers rather than a signed URL because Google Drive has no
/// pre-authenticated download link: measured 2026-08-13, a query-string
/// `access_token` on `alt=media` is refused with a 403 HTML anti-abuse page
/// while the same request with `Authorization: Bearer` returns 206 and bytes.
/// That is workable only because `URLSession` fetches these bytes — `AVPlayer`
/// never sees this URL.
public struct DownloadSource: Sendable {
    public let url: URL
    public let headers: [String: String]

    public init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }
}

public enum RemoteLibraryError: LocalizedError, Equatable {
    case notSignedIn
    case api(String)
    case cancelled
    /// Drive answers an unauthenticated media request with an HTML block page
    /// rather than JSON. Its own case so a caller cannot mistake the body for
    /// an API error object.
    case unexpectedResponseBody(String)
    /// A download refused for credentials — Drive answered 401. Task 3's
    /// provider-side refresh covers `RemoteLibraryProvider`'s own API calls;
    /// this is the byte path, which goes through `ClipCache`'s downloader and
    /// has no provider to ask mid-request. Its own case, distinct from
    /// `.api`, so `ViewerModel.prepareCurrentClip` can tell "the token is
    /// stale, mint a fresh one and retry" apart from an ordinary failure.
    case unauthorised
    /// Refused before any bytes moved, because `ClipWeight` judged the clip
    /// too heavy to be worth fetching. Carries the explanation rather than a
    /// fixed string: the coach is being denied a clip they can see in the
    /// sidebar, and "too large" alone gives them nothing to act on. Its own
    /// case, not `.api`, because nothing failed — this is the app's own
    /// decision, and a caller must be able to tell a refusal it made from a
    /// refusal Drive made.
    case tooLargeToFetch(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to your club's Google account to browse the shared library."
        case let .api(message), let .unexpectedResponseBody(message):
            return message
        case .cancelled:
            return "The request was cancelled."
        case .unauthorised:
            return "Your session expired. Try again."
        case let .tooLargeToFetch(explanation):
            return explanation
        }
    }
}
