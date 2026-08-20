import Foundation

/// Google Drive as a remote library.
///
/// One flat paged sweep per Shared Drive, not a folder-by-folder walk: Drive
/// can list a whole drive with `corpora=drive`, so a 1,000-clip library is two
/// round trips rather than one per folder. The folder tree is rebuilt here
/// from each file's `parents`.
public struct GoogleDriveProvider: RemoteLibraryProvider {
    public static let identifier = "gdrive"

    static let folderMimeType = "application/vnd.google-apps.folder"
    /// Drive returns a minimal field set unless asked. Every field here is
    /// used: `headRevisionId` is the cache-validity key, `md5Checksum` the
    /// post-download check, `parents` the tree, `size` the progress bar.
    private static let fileFields =
        "nextPageToken,incompleteSearch,files(id,name,mimeType,size,md5Checksum,headRevisionId,parents,videoMediaMetadata(width,height,durationMillis))"

    private let transport: HTTPTransport
    private let token: @Sendable () -> String?
    /// Present only when this provider was built from a `GoogleOAuthConfiguration`
    /// — `connect` uses it to run the flow and cache what it returns; the
    /// `token:`-closure initialiser leaves it nil and supplies credentials
    /// entirely on its own.
    private let signIn: SignIn?

    /// Bundles what `connect` needs, boxes the access token it obtains so
    /// `token` can read it back on every later request without another round
    /// trip, and refreshes that token on demand when a request finds it
    /// stale. A class, not a struct, because the struct around it (`Sendable`,
    /// so it can cross actors) must stay immutable while this still gets
    /// written from `connect` and from a mid-session refresh.
    private final class SignIn: @unchecked Sendable {
        let configuration: GoogleOAuthConfiguration
        let transport: HTTPTransport
        let tokenStore: OAuthTokenStore
        private let lock = NSLock()
        private var accessToken: String?
        /// An in-flight refresh, shared so several requests that all find
        /// the same stale token trigger exactly one refresh rather than one
        /// each — a coach with more than one pane open must not turn a
        /// single expired token into a stampede of refresh calls.
        private var refreshTask: Task<String, Error>?

        init(configuration: GoogleOAuthConfiguration, transport: HTTPTransport, tokenStore: OAuthTokenStore) {
            self.configuration = configuration
            self.transport = transport
            self.tokenStore = tokenStore
        }

        /// `NSLock.lock`/`.unlock` are flagged when called directly inside an
        /// `async` function — a suspension point could sneak in between them,
        /// holding the lock across an `await`. Wrapping both in a synchronous
        /// closure keeps every lock/unlock pair inside one non-async call,
        /// even where it's invoked from `refreshedAccessToken` below.
        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        func currentAccessToken() -> String? {
            withLock { accessToken }
        }

        func store(_ newAccessToken: String) {
            withLock { accessToken = newAccessToken }
        }

        /// Exchanges the stored refresh token for a new access token — the
        /// same non-interactive call `GoogleOAuth.accessToken` exists for —
        /// and caches the result. Concurrent callers that arrive while one
        /// refresh is already running await that same attempt instead of
        /// starting their own.
        func refreshedAccessToken() async throws -> String {
            let (task, isCreator): (Task<String, Error>, Bool) = withLock {
                if let inFlight = refreshTask {
                    return (inFlight, false)
                }
                let created = Task<String, Error> { [configuration, transport, tokenStore] in
                    try await GoogleOAuth.accessToken(
                        configuration: configuration, transport: transport, tokenStore: tokenStore
                    )
                }
                refreshTask = created
                return (created, true)
            }

            // A joiner just awaits the shared task; only its creator clears
            // the slot and caches the result, so it happens exactly once.
            guard isCreator else {
                return try await task.value
            }
            let result = await task.result
            withLock {
                refreshTask = nil
                if case let .success(newAccessToken) = result {
                    accessToken = newAccessToken
                }
            }
            return try result.get()
        }
    }

    /// `token` is read per request rather than captured once, so a refresh
    /// between calls is picked up without rebuilding the provider. Plan 2's
    /// tests build a provider this way, with a token available from the
    /// start; `connect` on a provider built this way has nothing to run and
    /// refuses.
    public init(transport: HTTPTransport = URLSessionTransport(), token: @escaping @Sendable () -> String?) {
        self.transport = transport
        self.token = token
        self.signIn = nil
    }

    /// The production path: `connect` runs the real Google sign-in flow and
    /// every request after it authorizes with what that flow obtained,
    /// refreshing silently in between as needed. `tokenStore` stays internal
    /// — the real Keychain by default — rather than a parameter here, so
    /// `SkiVideoCore` does not have to expose it; a test reaches the
    /// `tokenStore:` initialiser below through `@testable import`.
    public init(configuration: GoogleOAuthConfiguration, transport: HTTPTransport = URLSessionTransport()) {
        self.init(configuration: configuration, transport: transport, tokenStore: KeychainTokenStore())
    }

    /// The same initialiser, with the Keychain-backed default made explicit
    /// so a test can supply its own in-memory `OAuthTokenStore` instead.
    init(configuration: GoogleOAuthConfiguration, transport: HTTPTransport, tokenStore: OAuthTokenStore) {
        let signIn = SignIn(configuration: configuration, transport: transport, tokenStore: tokenStore)
        self.transport = transport
        self.token = { signIn.currentAccessToken() }
        self.signIn = signIn
    }

    public func connect(presenter: OAuthPresenter) async throws {
        guard let signIn else {
            // Built from the `token:` closure, which already supplies
            // credentials obtained elsewhere — there is no flow for this
            // initialiser to run.
            throw RemoteLibraryError.notSignedIn
        }
        let accessToken = try await GoogleOAuth.authorize(
            configuration: signIn.configuration,
            presenter: presenter,
            transport: signIn.transport,
            tokenStore: signIn.tokenStore
        )
        signIn.store(accessToken)
    }

    /// Picks the previous session back up with no browser: the refresh token
    /// the last sign-in put in the Keychain, exchanged for a fresh access
    /// token. This is what stops a coach being sent to Google on every launch
    /// — the credential to avoid it was already on disk, and until this existed
    /// nothing reached it from a cold start. `get`'s 401 retry refreshes too,
    /// but only mid-session: at launch the in-memory access token is nil, so
    /// the first request throws `.notSignedIn` before any response can arrive
    /// to be retried.
    ///
    /// Returns rather than throws — see the protocol. A caller has one useful
    /// response to every failure here, which is to offer the ordinary sign-in.
    public func resumeSession() async -> Bool {
        guard let signIn else {
            // Built from the `token:` closure: it supplies credentials on its
            // own and has no refresh token to exchange, the same reason
            // `connect` refuses. Nothing to resume, and nothing to unwrap.
            return false
        }
        do {
            _ = try await signIn.refreshedAccessToken()
            return true
        } catch {
            // Only a refusal justifies deleting the coach's stored sign-in.
            // A dropped connection or a 503 leaves it exactly where it was, so
            // the next attempt — on better wifi, tomorrow — still resumes; the
            // cost of being wrong the other way is a session lost for a reason
            // the coach cannot see. `GoogleOAuth.isRejection` is the same
            // judgement `authorize` makes, deliberately shared so the silent
            // and interactive paths cannot drift apart.
            if GoogleOAuth.isRejection(error) {
                signIn.tokenStore.remove(account: signIn.configuration.clientID)
            }
            return false
        }
    }

    public func roots() async throws -> [RemoteFolder] {
        var found: [RemoteFolder] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/drives")!
            components.queryItems = [
                // The default is 10, which would silently truncate the picker
                // for an account in more drives than that. 100 is the maximum,
                // so the paging below is what actually removes the ceiling.
                URLQueryItem(name: "pageSize", value: "100"),
            ]
            if let pageToken {
                components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            let page: DriveListOfDrives = try await get(components)
            found.append(contentsOf: page.drives.map { RemoteFolder(id: $0.id, name: $0.name) })
            pageToken = page.nextPageToken
        } while pageToken != nil
        return found
    }

    /// Every video in one Shared Drive.
    ///
    /// `folder` must be a root from `roots()` — its id is used as `driveId`,
    /// so a subfolder would be rejected by the API. Filtering to a subtree is
    /// the index's job, done in memory against the parents graph, because
    /// Drive has no recursive-subtree query and one whole-drive sweep costs
    /// the same as one folder listing.
    public func enumerate(_ folder: RemoteFolder) -> AsyncThrowingStream<RemoteFile, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let records = try await sweep(driveID: folder.id)
                    let folders = Dictionary(
                        records.filter { $0.mimeType == Self.folderMimeType }.map { ($0.id, $0) },
                        // Drive can report one record twice — results shift
                        // mid-pagination, and a multi-page change drain can
                        // repeat a file. `uniqueKeysWithValues` traps on that,
                        // which would crash the app on a routine refresh.
                        uniquingKeysWith: { first, _ in first }
                    )
                    for record in records where record.mimeType != Self.folderMimeType {
                        // Cosmetic by the time execution reaches here: `sweep`
                        // has already paged through the whole drive and
                        // `records` is fully in memory, so a cancellation
                        // caught in this loop only skips a few in-memory
                        // yields. The check that actually matters — the one
                        // that stops an abandoned browse from paging on to
                        // the end of a thousand-clip drive — is the one
                        // inside `sweep`'s own page loop, below.
                        try Task.checkCancellation()
                        continuation.yield(
                            RemoteFile(
                                id: record.id,
                                name: record.name,
                                path: Self.folderPath(of: record, in: folders, rootID: folder.id),
                                size: Int64(record.size ?? "") ?? 0,
                                contentVersion: record.headRevisionId,
                                md5: record.md5Checksum,
                                width: record.videoMediaMetadata?.width,
                                height: record.videoMediaMetadata?.height,
                                durationMillis: record.videoMediaMetadata?.durationMillis
                                    .flatMap(Int.init)
                            )
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // A consumer that stops iterating — the view torn down, the coach
            // picking a different drive — must stop the sweep with it.
            // Without this the task pages on to the end of a thousand-clip
            // drive, spending the operator's bandwidth on a stream nobody is
            // listening to.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func downloadSource(for file: RemoteFile) async throws -> DownloadSource {
        guard let token = token() else { throw RemoteLibraryError.notSignedIn }
        var components = URLComponents(
            string: "https://www.googleapis.com/drive/v3/files"
        )!
        // Appended through `path` so an id that is not URL-safe is encoded
        // rather than reshaping the request.
        components.path += "/\(file.id)"
        components.queryItems = [
            URLQueryItem(name: "alt", value: "media"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
        ]
        guard let url = components.url else {
            throw RemoteLibraryError.api("That Drive file id cannot be used in a request.")
        }
        return DownloadSource(url: url, headers: ["Authorization": "Bearer \(token)"])
    }

    // MARK: - The sweep

    private func sweep(driveID: String) async throws -> [DriveRecord] {
        var records: [DriveRecord] = []
        var pageToken: String?
        repeat {
            // Checked per page, so abandoning a browse stops the sweep at the
            // next page boundary rather than at the end of the drive.
            try Task.checkCancellation()
            var components = URLComponents(
                string: "https://www.googleapis.com/drive/v3/files"
            )!
            components.queryItems = [
                URLQueryItem(name: "corpora", value: "drive"),
                URLQueryItem(name: "driveId", value: driveID),
                // Omitting either excludes shared-drive items *silently*,
                // which reads as an empty library rather than as an error.
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
                // Defaults to 100 for a shared drive; 1000 makes a
                // 1,000-clip library two requests instead of eleven.
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "q", value: "trashed = false"),
                URLQueryItem(name: "fields", value: Self.fileFields),
            ]
            if let pageToken {
                components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            let page: DriveFileList = try await get(components)
            // Drive can drop files from a result without erroring. Reporting a
            // partial library as whole is the one outcome worth failing over.
            if page.incompleteSearch == true {
                throw RemoteLibraryError.api(
                    "Google Drive returned an incomplete listing for this drive. Try again."
                )
            }
            records.append(contentsOf: page.files)
            pageToken = page.nextPageToken
        } while pageToken != nil
        return records
    }

    /// The folder names from the drive root down to this record's parent.
    ///
    /// Bounded by the number of known folders, not by trust in the data: a
    /// parent cycle would otherwise spin forever, and nothing in production
    /// would catch it because Drive should never produce one. A record whose
    /// parent is missing — trashed folder, lost access — keeps the path that
    /// could be resolved rather than being dropped, because losing a clip is
    /// worse than filing it one level shallow.
    static func folderPath(
        of record: DriveRecord, in folders: [String: DriveRecord], rootID: String
    ) -> [String] {
        walkFolders(from: record.parents?.first, in: folders, rootID: rootID).names
    }

    /// The same walk, also saying *which* parent it could not resolve.
    ///
    /// The sweep never needs that — one `corpora=drive` listing carries every
    /// folder in the drive, so anything missing from it is missing from Drive.
    /// The change feed does: it carries only the folders that changed, so a
    /// walk that stops early there is usually a folder that simply did not
    /// change, and knowing its id is what lets `resolvedFolderPaths` go and
    /// fetch it. Returning it costs the sweep nothing.
    static func walkFolders(
        from parent: String?, in folders: [String: DriveRecord], rootID: String
    ) -> (names: [String], unresolved: String?) {
        var names: [String] = []
        // `seen` is what terminates this: each folder id can be consumed once,
        // so the walk is bounded by the number of known folders whether or not
        // the parent links form a cycle.
        var seen: Set<String> = []
        var current = parent
        while let id = current, id != rootID, !seen.contains(id) {
            seen.insert(id)
            guard let folder = folders[id] else { return (names.reversed(), id) }
            names.append(folder.name)
            current = folder.parents?.first
        }
        return (names.reversed(), nil)
    }

    /// The folder path of each record, fetching by id any parent folder the
    /// caller does not already have.
    ///
    /// **The change feed cannot resolve a path on its own, and assuming it
    /// could is what emptied 63 of this operator's 407 paths.** A change page
    /// carries the records that changed and nothing else, so a clip whose
    /// *bytes* changed while its folders did not — every clip the re-encode
    /// pass rewrote, `Nora1_resized.MP4` and 62 others — arrived with parent
    /// ids that were nowhere in the page. The walk stopped at the first of
    /// them and the clip was filed under no folder at all, which
    /// `RemoteLibraryIndex` groups under the root's own name: an athlete
    /// called "Videos" holding 63 clips.
    ///
    /// The index cannot supply the missing names either — `RemoteFile` stores
    /// resolved folder *names*, never parent ids, so there is no chain in it
    /// to walk. Drive is the only source, so Drive is asked.
    ///
    /// Bounded by the number of *distinct* unknown folders, not by the number
    /// of changed clips: every fetch is remembered for the rest of the drain,
    /// as is every id Drive would not show, so a hundred re-encoded clips in
    /// one folder cost one extra request in total.
    private func resolvedFolderPaths(
        of records: [DriveRecord], knownFolders: [String: DriveRecord], rootID: String
    ) async throws -> [[String]] {
        var folders = knownFolders
        /// Ids Drive answered 404 for. Cached as firmly as the successes: a
        /// trashed folder shared by many clips must cost one request, not one
        /// per clip.
        var invisible: Set<String> = []
        var paths: [[String]] = []
        for record in records {
            // Terminates because each turn either finishes the walk or adds a
            // key to `folders`/`invisible` that the next walk cannot ask for
            // again.
            while true {
                let walk = Self.walkFolders(
                    from: record.parents?.first, in: folders, rootID: rootID
                )
                guard let missing = walk.unresolved, !invisible.contains(missing) else {
                    paths.append(walk.names)
                    break
                }
                guard let fetched = try await folderRecord(id: missing) else {
                    invisible.insert(missing)
                    paths.append(walk.names)
                    break
                }
                folders[missing] = fetched
            }
        }
        return paths
    }

    /// One folder, by id, or nil when Drive will not show it to this account.
    ///
    /// Only `parents` and `name` are asked for — this record exists to be
    /// walked, never to become a `RemoteFile`. A record that is not a folder
    /// answers nil too: a file cannot be a parent, so treating one as a path
    /// component would invent a folder that does not exist.
    private func folderRecord(id: String) async throws -> DriveRecord? {
        var components = URLComponents(
            string: "https://www.googleapis.com/drive/v3/files"
        )!
        // Appended through `path` so an id that is not URL-safe is encoded
        // rather than reshaping the request.
        components.path += "/\(id)"
        components.queryItems = [
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "fields", value: "id,name,mimeType,parents"),
        ]
        guard let record: DriveRecord = try await getIfVisible(components) else { return nil }
        return record.mimeType == Self.folderMimeType ? record : nil
    }

    // MARK: - Requests

    private func get<T: Decodable>(_ components: URLComponents) async throws -> T {
        let (data, response) = try await fetch(components)
        guard (200...299).contains(response.statusCode) else {
            throw Self.describeFailure(data: data, response: response)
        }
        return try Self.decode(data)
    }

    /// The same request, with "Drive will not show me this" answered as nil
    /// rather than thrown.
    ///
    /// Only the parent-folder lookup wants that, and only for 404: a folder
    /// that was trashed, or that this account cannot see, is an ordinary state
    /// of the data rather than a failure, and Drive answers *both* with 404
    /// — it deliberately does not distinguish "gone" from "not yours".
    /// Everything else still throws, 403 included: Drive uses 403 for rate
    /// limits and quota, and reading one of those as "that folder does not
    /// exist" would file a whole page of clips one level shallow and persist
    /// it, which is the failure this call exists to fix.
    private func getIfVisible<T: Decodable>(_ components: URLComponents) async throws -> T? {
        let (data, response) = try await fetch(components)
        if response.statusCode == 404 { return nil }
        guard (200...299).contains(response.statusCode) else {
            throw Self.describeFailure(data: data, response: response)
        }
        return try Self.decode(data)
    }

    /// The authorized request and its one silent refresh, with no opinion
    /// about the status code — that judgement differs between callers, so it
    /// belongs to them.
    private func fetch(_ components: URLComponents) async throws -> (Data, HTTPURLResponse) {
        guard var token = token() else { throw RemoteLibraryError.notSignedIn }
        guard let url = components.url else {
            throw RemoteLibraryError.api("Could not build a request to Google Drive.")
        }

        func request(bearer: String) -> URLRequest {
            var request = URLRequest(url: url)
            // Never a query parameter. Measured 2026-08-13: on the media path a
            // query-string token is refused with an HTML block page.
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            return request
        }

        var (data, response) = try await transport.data(for: request(bearer: token))

        // A cached token can go stale mid-session — Google's access tokens
        // last about an hour, well inside a coach's review session. Refusing
        // to refresh here is exactly the failure this app moved away from
        // once already, when a token baked into a playback URL expired
        // mid-session with no way to replace it. One retry with a freshly
        // refreshed token — silent, not another interactive `connect` — is
        // what keeps a long session working without a human. `signIn` is nil
        // for a provider built from the `token:` closure, which has no
        // refresh token to exchange, so a 401 there still surfaces as-is.
        if response.statusCode == 401, let signIn {
            do {
                token = try await signIn.refreshedAccessToken()
            } catch {
                // No stored refresh token, or it was rejected: this is what
                // `.notSignedIn` means here, not a raw exchange error the
                // coach has no way to act on.
                throw RemoteLibraryError.notSignedIn
            }
            (data, response) = try await transport.data(for: request(bearer: token))
        }
        return (data, response)
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RemoteLibraryError.api(
                "Google Drive returned an unexpected reply: \(Self.describe(error))"
            )
        }
    }

    /// A decoding failure in words that say which field was wrong.
    ///
    /// `DecodingError.localizedDescription` is "The data couldn't be read
    /// because it is missing" whatever went wrong and wherever — the coach reads
    /// it as Drive being broken, and it tells whoever has to fix it nothing at
    /// all. The key and the path are in the error the whole time; they just have
    /// to be taken out of it.
    static func describe(_ error: Error) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "the top level" : "\u{201C}\(path)\u{201D}"
        }
        switch error {
        case let DecodingError.keyNotFound(key, context):
            return "no \u{201C}\(key.stringValue)\u{201D} in the reply, at \(path(context))."
        case let DecodingError.valueNotFound(type, context):
            return "\u{201C}\(path(context))\u{201D} was null where a \(type) was expected."
        case let DecodingError.typeMismatch(type, context):
            return "\(path(context)) was not the \(type) expected."
        case let DecodingError.dataCorrupted(context):
            return "the reply was not valid JSON (\(context.debugDescription))"
        default:
            return error.localizedDescription
        }
    }

    /// Google answers some failures with an HTML anti-abuse page rather than a
    /// JSON error object. A caller that assumes non-200 means JSON would
    /// mis-parse that, so the two are told apart before decoding.
    static func describeFailure(data: Data, response: HTTPURLResponse) -> RemoteLibraryError {
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        if !contentType.contains("json") {
            return .unexpectedResponseBody(
                """
                Google Drive answered with a \(response.statusCode) web page rather than an \
                API reply. This usually means the request was not authenticated.
                """
            )
        }
        let decoded = try? JSONDecoder().decode(DriveAPIError.self, from: data)
        let message = decoded?.error?.message ?? "No detail returned by Google."
        return .api("Google Drive returned HTTP \(response.statusCode): \(message)")
    }
}

extension GoogleDriveProvider: IncrementallyEnumerable {
    public func startCursor(forRoot rootID: String) async throws -> String {
        var components = URLComponents(
            string: "https://www.googleapis.com/drive/v3/changes/startPageToken"
        )!
        components.queryItems = [
            URLQueryItem(name: "driveId", value: rootID),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
        ]
        let response: DriveStartPageToken = try await get(components)
        return response.startPageToken
    }

    public func changes(
        since cursor: String, forRoot rootID: String
    ) async throws -> RemoteLibraryChanges {
        var changed: [DriveRecord] = []
        var removed: [String] = []
        var pageToken = cursor
        var nextCursor: String?

        // Drain until Drive hands back the token to resume from next time.
        // Page tokens never expire, so a client that has been closed for
        // months still resyncs in a bounded number of calls.
        while nextCursor == nil {
            var components = URLComponents(
                string: "https://www.googleapis.com/drive/v3/changes"
            )!
            components.queryItems = [
                URLQueryItem(name: "pageToken", value: pageToken),
                // The *drive* log, not the user log: files moved into a shared
                // drive stop appearing in the user log entirely.
                URLQueryItem(name: "driveId", value: rootID),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
                // Without both, a removal never arrives and the sidebar keeps
                // offering clips that are gone.
                URLQueryItem(name: "includeRemoved", value: "true"),
                URLQueryItem(name: "includeCorpusRemovals", value: "true"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(
                    name: "fields",
                    // `changeType` is asked for so a skipped record can be
                    // told apart by what it *is*, not merely by a key being
                    // absent — see the skip below.
                    value: "nextPageToken,newStartPageToken,changes(changeType,fileId,removed,file(\(Self.changeFileFields)))"
                ),
            ]
            let page: DriveChangeList = try await get(components)
            for change in page.changes {
                // Drive's log is not only file changes. A change to the shared
                // drive itself — renamed, sharing settings edited — arrives as
                // `changeType: "drive"` with `driveId`/`drive` and no file.
                // Such a record describes no clip, so it affects no clip.
                //
                // Two conditions rather than one, because each covers the
                // other's blind spot:
                //
                //  - `changeType != "file"` alone would silently drop *every*
                //    change if that field ever stopped arriving (a mask typo, a
                //    rename in a future API version) — the whole library going
                //    quiet, with nothing to show for it. So it only applies
                //    when the field is actually present.
                //  - a missing `fileId` alone is the structural test, and it is
                //    what this bug was, but it does not catch the worse
                //    variant: a non-file record that *does* carry an id. Drive
                //    stamps a drive-level change with the drive's own id, and a
                //    drive id is a folder id — that would fall into the
                //    `file == nil` branch below and be reported as a removal,
                //    silently evicting a real entry from the index.
                //
                // Together they also give the right answer for a change type
                // Google has not shipped yet, which is what this bug was: an
                // unfamiliar record is skipped, not guessed at.
                guard let fileId = change.fileId,
                      change.changeType == nil || change.changeType == "file"
                else { continue }
                // `trashed` counts as removed. Google's docs define `removed`
                // only as "removed from this list of changes, for example by
                // deletion or loss of access" and say nothing about trashing,
                // so this handles both readings: if Drive reports a trashed
                // clip as an ordinary change it is caught here, and if it
                // reports one as `removed` the first branch already had it.
                // Getting this wrong the other way would leave a clip a coach
                // deleted sitting in the sidebar until Drive purged it.
                if change.removed == true || change.file == nil || change.file?.trashed == true {
                    removed.append(fileId)
                } else if let record = change.file {
                    changed.append(record)
                }
            }
            if let next = page.nextPageToken {
                // A server repeating a token would otherwise re-issue the same
                // request forever, which is the one way this loop's "bounded
                // number of calls" claim could be false.
                guard next != pageToken else {
                    throw RemoteLibraryError.api(
                        "Google Drive repeated a change-feed page token. Refresh again in a moment."
                    )
                }
                pageToken = next
            } else if let newStart = page.newStartPageToken {
                nextCursor = newStart
            } else {
                // Neither token: without this the loop would spin on an
                // unchanged `pageToken`.
                throw RemoteLibraryError.api(
                    "Google Drive returned a change page with neither a next page nor a new start token."
                )
            }
        }

        // A change gives a file id and its parents, not a path, and the page
        // carries only the folders that changed too — which for a clip whose
        // bytes changed under an untouched folder is none of them. The rest
        // are fetched by id; see `resolvedFolderPaths` for what assuming
        // otherwise cost.
        let folders = Dictionary(
            changed.filter { $0.mimeType == Self.folderMimeType }.map { ($0.id, $0) },
            // Drive can report one record twice — results shift mid-pagination,
            // and a multi-page change drain can repeat a file.
            // `uniqueKeysWithValues` traps on that, which would crash the app
            // on a routine refresh.
            uniquingKeysWith: { first, _ in first }
        )
        let changedFiles = changed.filter { $0.mimeType != Self.folderMimeType }
        let paths = try await resolvedFolderPaths(
            of: changedFiles, knownFolders: folders, rootID: rootID
        )
        return RemoteLibraryChanges(
            changed: zip(changedFiles, paths).map { record, path in
                RemoteFile(
                    id: record.id,
                    name: record.name,
                    path: path,
                    size: Int64(record.size ?? "") ?? 0,
                    contentVersion: record.headRevisionId,
                    md5: record.md5Checksum,
                    width: record.videoMediaMetadata?.width,
                    height: record.videoMediaMetadata?.height,
                    durationMillis: record.videoMediaMetadata?.durationMillis.flatMap(Int.init)
                )
            },
            removed: removed,
            cursor: nextCursor ?? cursor
        )
    }

    /// `trashed` is requested because the sweep excludes trashed files with
    /// `q: trashed = false` and the change feed has no equivalent — without
    /// the field there is no way to tell a trashed clip from a live one.
    static let changeFileFields = "id,name,mimeType,size,md5Checksum,headRevisionId,parents,trashed,videoMediaMetadata(width,height,durationMillis)"
}

// MARK: - Wire formats

struct DriveRecord: Decodable {
    let id: String
    let name: String
    let mimeType: String
    let size: String?
    let md5Checksum: String?
    let headRevisionId: String?
    let parents: [String]?
    /// Only requested by the change feed. The sweep filters trashed files out
    /// server-side with `q: trashed = false`, so it never needs to read this.
    let trashed: Bool?
    /// What `ClipWeight` judges a clip's weight from, before anything is
    /// downloaded. Absent for a clip Drive has not finished processing.
    ///
    /// Drive nests these, and reports `durationMillis` as a *string* while
    /// width and height are numbers. Mirrored exactly rather than flattened:
    /// a decode that guesses at the shape is how the change feed's missing
    /// `fileId` took down a whole library open.
    let videoMediaMetadata: VideoMediaMetadata?

    struct VideoMediaMetadata: Decodable {
        let width: Int?
        let height: Int?
        let durationMillis: String?
    }
}

/// Google omits an empty collection rather than sending `[]`.
///
/// A `files.list` that matches nothing answers `{"kind": "drive#fileList",
/// "incompleteSearch": false}` — no `files` key at all — and a non-optional
/// array turns that into `keyNotFound`, which surfaces as "The data couldn't be
/// read because it is missing." So an empty folder was reported to the coach as
/// Google having failed. The same is true of `drives` and `changes`, so all
/// three read absence as emptiness, which is what it means.
private struct DriveFileList: Decodable {
    let nextPageToken: String?
    let incompleteSearch: Bool?
    let files: [DriveRecord]

    enum CodingKeys: String, CodingKey { case nextPageToken, incompleteSearch, files }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
        incompleteSearch = try container.decodeIfPresent(Bool.self, forKey: .incompleteSearch)
        files = try container.decodeIfPresent([DriveRecord].self, forKey: .files) ?? []
    }
}

private struct DriveListOfDrives: Decodable {
    struct Drive: Decodable {
        let id: String
        let name: String
    }

    let nextPageToken: String?
    let drives: [Drive]

    enum CodingKeys: String, CodingKey { case nextPageToken, drives }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
        drives = try container.decodeIfPresent([Drive].self, forKey: .drives) ?? []
    }
}

private struct DriveAPIError: Decodable {
    struct Details: Decodable {
        let code: Int?
        let message: String?
    }

    let error: Details?
}

private struct DriveStartPageToken: Decodable {
    let startPageToken: String
}

private struct DriveChangeList: Decodable {
    struct Change: Decodable {
        /// Optional because not every change record describes a file: a change
        /// to the shared drive itself (`changeType: "drive"`) carries
        /// `driveId`/`drive` and no `fileId` at all. Non-optional this threw
        /// `keyNotFound` — and because a page decodes as one unit, one such
        /// record anywhere in a 1000-item page took the whole library open
        /// with it: "no `fileId` in the reply, at `changes.Index 38`".
        let fileId: String?
        /// `"file"` or `"drive"` today. Optional so a reply that ever stops
        /// carrying it degrades to the `fileId` rule rather than dropping
        /// every change on the floor.
        let changeType: String?
        let removed: Bool?
        let file: DriveRecord?
    }

    let nextPageToken: String?
    let newStartPageToken: String?
    let changes: [Change]

    enum CodingKeys: String, CodingKey { case nextPageToken, newStartPageToken, changes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
        newStartPageToken = try container.decodeIfPresent(String.self, forKey: .newStartPageToken)
        changes = try container.decodeIfPresent([Change].self, forKey: .changes) ?? []
    }
}
