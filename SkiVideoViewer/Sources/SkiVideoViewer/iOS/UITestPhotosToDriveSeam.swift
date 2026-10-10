#if DEBUG
import SkiVideoCore
import SwiftUI

/// The stand-ins `PhotosToDriveUITests` needs to walk the phone flow end to
/// end: From Photos → tag → upload, with nothing real on either side.
///
/// **Why a seam at all.** `PHPickerViewController` runs out of process, so
/// XCUITest cannot pick from it reliably, and the upload must never reach the
/// club's real Drive from a test. So, only when the app is launched with
/// `launchArgument`:
///  - "From Photos…" hands over fixture movies through the real
///    `PhotosClipExporter`, instead of presenting the picker;
///  - a `FakeClubDrive` (an in-memory `ItemCreatable`) is signed in and opened
///    as a Drive library with a known layout, through the same
///    `ViewerModel.signIn` / `chooseRoot` calls the Google sheet makes — so
///    `uploadTarget()` resolves exactly as it does for a coach;
///  - library list, index and roster go to throwaway stores, and sorted clips
///    to a throwaway output root, so a run neither reads nor leaves anything
///    a coach (or another test) would see.
///
/// **Why it cannot ship.** The whole file is `#if DEBUG`, and so is every call
/// site, so a Release build has neither the types nor the launch-argument
/// check — the launch argument does nothing there.
@MainActor
enum UITestPhotosToDriveSeam {
    static let launchArgument = "-SkiUITestPhotosToDrive"
    /// Path of a movie the app may read. The UI-test runner passes its own
    /// bundled fixture; a simulator app can read it in place.
    static let fixtureEnvironmentKey = "SKI_UITEST_FIXTURE_MOVIE"
    /// Comma-separated names the picks are offered under, e.g. "IMG_0101,IMG_0102".
    static let picksEnvironmentKey = "SKI_UITEST_PICKS"

    static let isActive = ProcessInfo.processInfo.arguments.contains(launchArgument)

    static let libraryName = "UI Test Club Drive"
    static let rootID = "uitest-root"
    /// Fixed so the event folder — and so every Drive path — is predictable.
    static let captureDate = Date(timeIntervalSince1970: 1_771_065_000) // 2026-02-14

    static let drive = FakeClubDrive(rootID: rootID, fixture: fixtureURL)

    static var fixtureURL: URL? {
        ProcessInfo.processInfo.environment[fixtureEnvironmentKey].map { URL(fileURLWithPath: $0) }
    }

    /// Scratch for this launch only.
    static let scratch: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("UITestPhotosToDrive", isDirectory: true)

    static var outputRoot: URL { scratch.appendingPathComponent("Sorted", isDirectory: true) }

    /// Before any model exists: every store the flow would write to points
    /// into `scratch`, wiped at launch.
    static func isolateStorage() {
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let suite = "dk.dyregod.video-viewer.uitest"
        UserDefaults().removePersistentDomain(forName: suite)
        ViewerModel.defaults = UserDefaults(suiteName: suite) ?? .standard
        RemoteLibraryIndex.storeRoot = scratch.appendingPathComponent("Index", isDirectory: true)
        AthleteRoster.storeRoot = scratch.appendingPathComponent("Roster", isDirectory: true)
    }

    /// Signs in to the fake and opens it, the way the Google sheet would.
    static func openFakeDrive(in model: ViewerModel) async {
        await model.signIn(with: drive)
        let cache = ClipCache(
            root: scratch.appendingPathComponent("CloudClips", isDirectory: true),
            downloader: FixtureDownloader(fixture: fixtureURL),
            budget: 1_000_000_000
        )
        await model.chooseRoot(
            RemoteFolder(id: rootID, name: libraryName), cache: cache, convention: .eventThenAthlete
        )
    }

    static func photosImporter() -> PhotosImporting {
        let names = (ProcessInfo.processInfo.environment[picksEnvironmentKey] ?? "IMG_0101,IMG_0102")
            .split(separator: ",").map(String.init)
        return FixturePhotosImporter(
            picks: names.map { FixturePick(suggestedName: $0, file: fixtureURL) },
            exporter: PhotosClipExporter(captureDate: { _ in captureDate })
        )
    }
}

/// What the fake Drive has been sent, on screen for the UI test to read.
/// One element, its value the sorted list of uploaded paths, so the test can
/// assert exactly what reached Drive and where.
struct FakeClubDriveReadout: View {
    @ObservedObject var log: FakeClubDrive.Log

    var body: some View {
        Text("Fake Drive uploads: \(log.uploads.count)")
            .font(.caption2)
            .padding(4)
            .background(.yellow.opacity(0.6))
            // No `.accessibilityElement()`: that turns the Text into a
            // generic element, and the test looks it up as a static text.
            .accessibilityIdentifier("uitest.fakeDrive.uploads")
            .accessibilityLabel("Fake Drive uploads: \(log.uploads.count)")
            .accessibilityValue(log.uploads.joined(separator: "\n"))
            .allowsHitTesting(false)
    }
}

/// An in-memory club Drive: one seed clip so the library has an athlete to
/// open, a folder tree that `find…`/`create…`/`upload` read and write, and a
/// log of every upload by its full path under the root.
final class FakeClubDrive: ItemCreatable, @unchecked Sendable {
    static let identifier = "uitest-fake-drive"

    @MainActor final class Log: ObservableObject {
        @Published private(set) var uploads: [String] = []
        func record(_ path: String) { uploads.append(path) }
    }

    @MainActor let log = Log()

    private let rootID: String
    private let fixture: URL?
    private let lock = NSLock()
    private var folders: [String: (name: String, parent: String)] = [:]
    private var files: [(id: String, name: String, parent: String)] = []
    private var nextID = 0

    /// The one clip the library lists, so a phone has an athlete to tap.
    static let seedPath = ["2026-01-10_Seed Camp", "Seed Athlete"]
    static let seedName = "seed.mp4"

    init(rootID: String, fixture: URL?) {
        self.rootID = rootID
        self.fixture = fixture
        var parent = rootID
        for name in Self.seedPath { parent = createFolderLocked(named: name, parent: parent) }
        files.append((id: mintLocked("file"), name: Self.seedName, parent: parent))
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    // MARK: RemoteLibraryProvider

    func connect(presenter: OAuthPresenter) async throws {}
    func resumeSession() async -> Bool { true }
    func roots() async throws -> [RemoteFolder] {
        [RemoteFolder(id: rootID, name: UITestPhotosToDriveSeam.libraryName)]
    }

    func enumerate(_ folder: RemoteFolder) -> AsyncThrowingStream<RemoteFile, Error> {
        let size = fixture.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64 } ?? 0
        let seed = RemoteFile(id: "seed-file", name: Self.seedName, path: Self.seedPath,
                              size: size, contentVersion: "1", md5: nil)
        return AsyncThrowingStream { continuation in
            continuation.yield(seed)
            continuation.finish()
        }
    }

    func downloadSource(for file: RemoteFile) async throws -> DownloadSource {
        guard let fixture else { throw RemoteLibraryError.api("No fixture movie was passed to the app.") }
        return DownloadSource(url: fixture, headers: [:])
    }

    // MARK: ItemCreatable

    func authorizeWrites(presenter: OAuthPresenter) async throws {}

    func findFolder(named name: String, parent parentID: String) async throws -> RemoteItem? {
        locked { folderIDLocked(named: name, parent: parentID).map { RemoteItem(id: $0, name: name) } }
    }

    func findFile(named name: String, parent parentID: String) async throws -> RemoteItem? {
        locked {
            files.first { $0.name == name && $0.parent == parentID }.map { RemoteItem(id: $0.id, name: $0.name) }
        }
    }

    func createFolder(named name: String, parent parentID: String) async throws -> RemoteItem {
        locked { RemoteItem(id: createFolderLocked(named: name, parent: parentID), name: name) }
    }

    func findOrCreateFolder(named name: String, parent parentID: String) async throws -> RemoteItem {
        if let existing = try await findFolder(named: name, parent: parentID) { return existing }
        return try await createFolder(named: name, parent: parentID)
    }

    func upload(fileAt url: URL, named name: String, parent parentID: String) async throws -> RemoteItem {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RemoteUploadError.retryClip("\(name) is not on disk")
        }
        // Long enough for the row to show "Uploading", short enough not to
        // slow the test.
        try await Task.sleep(nanoseconds: 300_000_000)
        let (item, path): (RemoteItem, String) = locked {
            let id = mintLocked("file")
            files.append((id: id, name: name, parent: parentID))
            return (RemoteItem(id: id, name: name), (pathLocked(of: parentID) + [name]).joined(separator: "/"))
        }
        await MainActor.run { log.record(path) }
        return item
    }

    // MARK: Locked helpers

    private func mintLocked(_ prefix: String) -> String {
        nextID += 1
        return "\(prefix)-\(nextID)"
    }

    private func folderIDLocked(named name: String, parent: String) -> String? {
        folders.filter { $0.value.name == name && $0.value.parent == parent }.keys.sorted().first
    }

    private func createFolderLocked(named name: String, parent: String) -> String {
        let id = mintLocked("folder")
        folders[id] = (name, parent)
        return id
    }

    private func pathLocked(of folderID: String) -> [String] {
        var path: [String] = []
        var current = folderID
        while current != rootID, let folder = folders[current] {
            path.insert(folder.name, at: 0)
            current = folder.parent
        }
        return path
    }
}

/// "Downloads" the seed clip by copying the fixture: the library opens and
/// plays without the network.
private struct FixtureDownloader: ClipDownloader {
    let fixture: URL?

    func download(_ source: DownloadSource, of file: RemoteFile, to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source.url, to: destination)
    }
}

/// A Photos pick backed by a file on disk, handed over the way
/// `loadFileRepresentation` does: a temporary copy valid only inside `body`.
private struct FixturePick: PickedMovie {
    let suggestedName: String?
    let file: URL?

    func withFile(_ body: @escaping @Sendable (URL) throws -> Void) async throws {
        guard let file else { throw CocoaError(.fileNoSuchFile) }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(file.pathExtension)
        try FileManager.default.copyItem(at: file, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try body(temporary)
    }
}

/// "From Photos…" without the picker: the fixture picks go through the real
/// `PhotosClipExporter`, so the source the sort reads is built exactly as a
/// coach's would be.
@MainActor
private final class FixturePhotosImporter: PhotosImporting {
    private let picks: [FixturePick]
    private let exporter: PhotosClipExporter

    init(picks: [FixturePick], exporter: PhotosClipExporter) {
        self.picks = picks
        self.exporter = exporter
    }

    func importClips() async throws -> URL? {
        try await exporter.export(picks)
    }

    func discard() { exporter.clear() }
}
#endif
