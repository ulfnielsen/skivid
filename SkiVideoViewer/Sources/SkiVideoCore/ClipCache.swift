import CryptoKit
import Foundation

/// Fetches a clip's bytes to a local file. A seam, so the cache's own tests
/// never reach the network.
public protocol ClipDownloader: Sendable {
    func download(_ source: DownloadSource, of file: RemoteFile, to destination: URL) async throws
}

public struct URLSessionClipDownloader: ClipDownloader {
    private let session: URLSession

    /// The default session. A background session — which is what an iPad
    /// download needs to survive suspension — requires the delegate API rather
    /// than `download(for:)`, so it lands with the iPad work in plan 3.
    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func download(
        _ source: DownloadSource, of file: RemoteFile, to destination: URL
    ) async throws {
        var request = URLRequest(url: source.url)
        for (field, value) in source.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (temporary, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteLibraryError.api("The download did not return an HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            if !contentType.contains("json") && !contentType.hasPrefix("video") {
                // Drive answers an unauthenticated media request with an HTML
                // block page. Saying so beats "the file is corrupt".
                throw RemoteLibraryError.unexpectedResponseBody(
                    "Downloading \(file.name) returned a \(http.statusCode) web page rather than video."
                )
            }
            throw RemoteLibraryError.api("Downloading \(file.name) failed with HTTP \(http.statusCode).")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}

/// Clips on disk, so `AVPlayer` and `AVAssetReader` only ever see local files.
///
/// An actor because two panes of the comparison window can ask for the same
/// clip at the same moment, and the answer must be one download.
///
/// Whole files, never ranges: the library's clips are 13–61 s and p50 32 MB,
/// so a clip lands in a couple of seconds, and every scrub-heavy and
/// analysis feature in the app needs a complete local file anyway —
/// `AVAssetReader` cannot read a remote source at all.
public actor ClipCache {
    /// One entry per cached clip. `contentVersion` is what decides whether the
    /// bytes on disk are still the bytes in Drive.
    private struct Entry: Codable {
        let fileID: String
        let fileName: String
        let contentVersion: String?
        let bytes: Int64
        var lastUsed: Date
        /// What eviction actually orders on.
        ///
        /// `lastUsed` is a wall-clock stamp kept for diagnostics and for any
        /// later age-based policy, but it cannot order this: two clips
        /// materialised in quick succession can share a `Date`, and `sorted`
        /// breaks ties arbitrarily — so on a fast machine the clip a coach
        /// just watched could be evicted instead of the oldest. A counter the
        /// actor hands out is total by construction.
        var useOrder: Int
        var isPinned: Bool
    }

    private let root: URL
    private let downloader: ClipDownloader
    private var budget: Int64
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<URL, Error>] = [:]
    private let now: () -> Date
    private var nextUseOrder: Int

    public init(
        root: URL,
        downloader: ClipDownloader,
        budget: Int64,
        now: @escaping () -> Date = Date.init
    ) {
        self.root = root
        self.downloader = downloader
        self.budget = budget
        self.now = now
        self.entries = Self.loadManifest(at: Self.manifestURL(in: root))
        // Resume above whatever the last run reached, so ordering survives a
        // relaunch instead of restarting and making old entries look fresh.
        self.nextUseOrder = (self.entries.values.map(\.useOrder).max() ?? 0) + 1
    }

    private func takeUseOrder() -> Int {
        defer { nextUseOrder += 1 }
        return nextUseOrder
    }

    // MARK: - Reading

    /// The local file for this clip, or nil when it is not on disk. Never
    /// downloads — a caller that wants the clip asks `materialize`.
    public func cachedURL(for identity: ClipIdentity) -> URL? {
        guard case let .remote(_, fileID) = identity,
              let entry = entries[fileID]
        else { return nil }
        let url = fileURL(for: entry)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // The manifest outlived the bytes: iOS may purge Caches, and a
            // coach may empty it by hand. Forget the entry rather than hand
            // back a path to nothing — and persist that forgetting, or the
            // stale entry returns on the next launch.
            entries.removeValue(forKey: fileID)
            saveManifest()
            return nil
        }
        return url
    }

    public func bytesOnDisk() -> Int64 {
        entries.values.reduce(0) { $0 + $1.bytes }
    }

    // MARK: - Writing

    /// The clip as a local file, downloading it if it is not already current.
    ///
    /// Concurrent calls for one clip share a single download — the comparison
    /// window asks for two clips at once and can ask for the same one twice.
    public func materialize(_ file: RemoteFile, source: DownloadSource) async throws -> URL {
        if let entry = entries[file.id],
           let version = entry.contentVersion,
           // Nil on either side means "cannot confirm this is current", and
           // an unconfirmable cache is worse than a re-download.
           version == file.contentVersion,
           FileManager.default.fileExists(atPath: fileURL(for: entry).path) {
            entries[file.id]?.lastUsed = now()
            entries[file.id]?.useOrder = takeUseOrder()
            return fileURL(for: entry)
        }

        if let existing = inFlight[file.id] {
            return try await existing.value
        }

        let task = Task<URL, Error> {
            try await fetch(file, source: source)
        }
        inFlight[file.id] = task
        defer { inFlight[file.id] = nil }
        return try await task.value
    }

    private func fetch(_ file: RemoteFile, source: DownloadSource) async throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = fileURL(fileID: file.id, fileName: file.name)
        let scratch = destination.appendingPathExtension("partial")

        do {
            try await downloader.download(source, of: file, to: scratch)
            try verify(scratch, against: file)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: scratch, to: destination)
        } catch {
            // A half-written clip must never read as cached — AVPlayer would
            // open it and show a truncated run. The destination is
            // untouched on this path, so a previous, still-playable version
            // is deliberately left alone: removing its entry here would
            // make the good copy on disk unplayable and its bytes invisible
            // to the budget, permanently — worse than the failure itself.
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }

        // A renamed extension (Drive's .mp4 becoming .mov) means the new
        // entry's `fileURL` differs from the old one's, so the plain
        // overwrite above never touches the old file. Without this it is
        // orphaned: untracked, uncounted, and never evicted.
        if let old = entries[file.id] {
            let oldURL = fileURL(for: old)
            if oldURL != destination {
                try? FileManager.default.removeItem(at: oldURL)
            }
        }

        entries[file.id] = Entry(
            fileID: file.id, fileName: file.name, contentVersion: file.contentVersion,
            bytes: file.size, lastUsed: now(), useOrder: takeUseOrder(),
            isPinned: entries[file.id]?.isPinned ?? false
        )
        evictToFit(protecting: file.id)
        saveManifest()
        return destination
    }

    /// Checks the bytes landed whole. `md5Checksum` when Drive supplied one;
    /// size otherwise, which is all a caller has for a file without it.
    private func verify(_ url: URL, against file: RemoteFile) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes == file.size else {
            throw RemoteLibraryError.api(
                "\(file.name) downloaded incompletely (\(bytes) of \(file.size) bytes)."
            )
        }
        guard let expected = file.md5 else { return }
        let digest = Insecure.MD5.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw RemoteLibraryError.api("\(file.name) did not download correctly. Try again.")
        }
    }

    // MARK: - Retention

    public func recordPlayback(of identity: ClipIdentity) {
        guard case let .remote(_, fileID) = identity else { return }
        entries[fileID]?.lastUsed = now()
        entries[fileID]?.useOrder = takeUseOrder()
        saveManifest()
    }

    public func pin(_ identity: ClipIdentity) {
        guard case let .remote(_, fileID) = identity, entries[fileID] != nil else { return }
        entries[fileID]?.isPinned = true
        saveManifest()
    }

    public func unpin(_ identity: ClipIdentity) {
        guard case let .remote(_, fileID) = identity else { return }
        entries[fileID]?.isPinned = false
        evictToFit()
        saveManifest()
    }

    public func setBudget(_ bytes: Int64) {
        budget = bytes
        // Immediately, not at the next download: a coach freeing disk space
        // expects the space back now.
        evictToFit()
        saveManifest()
    }

    /// Drops least-recently-used clips until the total fits the budget.
    ///
    /// Never evicts a pinned clip, and never the clip just materialised —
    /// evicting the file we are about to hand back leaves the caller with a
    /// path to nothing and makes every retry re-download and re-evict it.
    /// Nor does it ever refuse to keep a clip larger than the whole budget —
    /// the biggest clips in the library would otherwise become permanently
    /// unopenable.
    public func evictToFit(protecting fileID: String? = nil) {
        var total = bytesOnDisk()
        guard total > budget else { return }
        let candidates = entries.values
            .filter { !$0.isPinned && $0.fileID != fileID }
            .sorted { $0.useOrder < $1.useOrder }
        for entry in candidates {
            guard total > budget, entries.count > 1 else { break }
            try? FileManager.default.removeItem(at: fileURL(for: entry))
            entries.removeValue(forKey: entry.fileID)
            total -= entry.bytes
        }
    }

    // MARK: - Layout

    /// Named by a digest of the file id, not by the clip's name: a rename in
    /// Drive then costs nothing, and two clips sharing a name cannot collide.
    /// See `StorageName` for why a digest. The extension is kept because
    /// `AVURLAsset` reads it as a type hint.
    private func fileURL(fileID: String, fileName: String) -> URL {
        let extensionOnly = URL(fileURLWithPath: fileName).pathExtension
        return root
            .appendingPathComponent(StorageName.forIdentifier(fileID))
            .appendingPathExtension(extensionOnly.isEmpty ? "mp4" : extensionOnly)
    }

    private func fileURL(for entry: Entry) -> URL {
        fileURL(fileID: entry.fileID, fileName: entry.fileName)
    }

    private static func manifestURL(in root: URL) -> URL {
        root.appendingPathComponent("clips.skicache.json")
    }

    private static func loadManifest(at url: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return entries
    }

    private func saveManifest() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: Self.manifestURL(in: root), options: .atomic)
    }
}
