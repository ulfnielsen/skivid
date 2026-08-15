import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Platform-agnostic state for the sort-and-resize workflow. Folder selection,
/// keyboard input and transcoding all reach it through the seams in
/// `Seams.swift`, so an iPadOS target can present the same model.
///
/// Access levels are deliberately narrow: `public` marks exactly what the app
/// target's `SortingSheet` and `SortingWindowController` touch. Members used
/// only by this module or by tests stay internal.
@MainActor
public final class SortingModel: ObservableObject {
    @Published public var sourcePath = ""
    @Published public var namesPath: String
    @Published public var eventDate = Date()
    @Published public var eventTitle = ""
    @Published public var athleteQuery = ""
    @Published public private(set) var athleteNames: [String] = []
    @Published private(set) var rawVideos: [URL] = []
    @Published private(set) var currentIndex = 0
    @Published public private(set) var isSorting = false
    @Published public private(set) var queuedResizes = 0
    @Published public private(set) var completedResizes = 0
    @Published public private(set) var failedResizes: [String] = []
    @Published public private(set) var status = "Choose a folder of raw clips."
    @Published public var errorMessage: String?
    @Published public private(set) var completedOutputDirectory: URL?
    /// True when the source must not be written to — an SD card still holding
    /// the only copy of a session. Set before `beginSorting`.
    @Published public var keepsSourceIntact = false
    /// Where a source-preserving session writes its resizes. Ignored when
    /// `keepsSourceIntact` is false, because that session writes beside the
    /// source the way it always has.
    @Published public var outputRoot: URL = SortingModel.defaultOutputRoot()

    public let player = AVPlayer()
    private let resizeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "dk.dyregod.video-viewer.resize"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var sourceDirectory: URL?
    /// The session's end-stage. Nil until `beginSorting` chooses one.
    ///
    /// Defaults to `LocalFolderPublisher` over directories derived from the
    /// source, which is exactly what this model did inline before the seam
    /// existed — so a Mac session behaves identically.
    private var publisher: ClipPublisher?
    /// Kept alongside `publisher` purely so `completeIfPossible` can report
    /// where the resized library landed; `ClipPublisher` does not expose its
    /// root back out.
    private var resizedDirectory: URL?
    private var eventFolder = ""
    private var taggingFinished = false
    private let mediaPipeline: MediaPipeline

    /// Optional because a unit-test model needs neither. A sorting session
    /// without an input source simply has no keyboard control, and one without
    /// a folder picker cannot open the two "Choose…" panels.
    private let input: PlaybackInputSource?
    private let folderPicker: FolderPicker?

    /// `defaultNamesURL` is injected rather than derived: `~/Ski/athletes.txt`
    /// is a macOS convention, and the core must not assume a home-directory
    /// layout. Nil, or a path that does not exist, leaves the field empty.
    public init(
        mediaPipeline: MediaPipeline,
        input: PlaybackInputSource? = nil,
        folderPicker: FolderPicker? = nil,
        defaultNamesURL: URL? = nil
    ) {
        self.mediaPipeline = mediaPipeline
        self.input = input
        self.folderPicker = folderPicker
        namesPath = defaultNamesURL.map { url in
            FileManager.default.fileExists(atPath: url.path) ? url.path : ""
        } ?? ""
        reloadNames()
        input?.onIntent = { [weak self] intent in
            self?.handle(intent)
        }
        // The `NSEvent` monitor this replaced was installed by `beginSorting`
        // and removed by `stopPlayback`, so the setup screen never intercepted
        // keys. An input source that is live from construction would, hence the
        // explicit disable here.
        input?.setEnabled(false)
    }

    /// The app's Documents directory, which on iPadOS is what
    /// `UIFileSharingEnabled` exposes under "On My iPad" in Files — so a
    /// coach can reach the results without this app's help.
    ///
    /// `public` so the iPad call site can pass it to `outputRoot` explicitly
    /// alongside `keepsSourceIntact = true`, rather than relying on it being
    /// this property's default — `outputRoot` is ignored whenever
    /// `keepsSourceIntact` is false, so a call site that sets one and not the
    /// other is easy to get wrong silently.
    public static func defaultOutputRoot() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sorted", isDirectory: true)
    }

    public var currentVideo: URL? {
        rawVideos.indices.contains(currentIndex) ? rawVideos[currentIndex] : nil
    }

    public var matchingAthletes: [String] {
        SortingLibrary.matches(for: athleteQuery, names: athleteNames)
    }

    public var resolvedAthlete: String? {
        matchingAthletes.count == 1 ? matchingAthletes[0] : nil
    }

    public var newAthleteCandidate: String? {
        let candidate = athleteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              SortingLibrary.matches(for: candidate, names: athleteNames).isEmpty,
              !athleteNames.contains(where: {
                  $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                      == candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
              })
        else {
            return nil
        }
        return candidate
    }

    public var progressLabel: String {
        let remaining = rawVideos.count
        if taggingFinished {
            return "Tagging complete · resizing \(completedResizes) of \(queuedResizes)"
        }
        return "\(remaining) clip\(remaining == 1 ? "" : "s") left to tag · \(queuedResizes - completedResizes) waiting to resize"
    }

    public func chooseSourceDirectory() async {
        guard let folderPicker,
              let url = await folderPicker.pickFolder(
                  startingAt: nil,
                  title: "Choose folder containing raw videos",
                  confirmLabel: "Choose"
              )
        else { return }
        sourcePath = url.path
        if let firstVideo = try? SortingLibrary.rawVideos(in: url).first {
            eventDate = SortingLibrary.suggestedEventDate(from: firstVideo)
        }
    }

    public func chooseNamesFile() async {
        guard let folderPicker,
              let url = await folderPicker.pickFile(
                  ofType: .plainText,
                  title: "Choose athlete-name list"
              )
        else { return }
        namesPath = url.path
        reloadNames()
    }

    public func reloadNames() {
        let url = namesPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : URL(fileURLWithPath: namesPath)
        athleteNames = SortingLibrary.athleteNames(from: url)
    }

    /// Internal: the model subscribes itself to `input.onIntent`, so nothing
    /// outside the module drives it directly.
    ///
    /// The sorting window's `NSEvent` monitor bound exactly two keys — Left and
    /// Right — and acted on key-down only. Acting on `.seek` and ignoring the
    /// slow-motion pair reproduces that: it never had hold-to-scrub. The `isSorting`
    /// guard is the one the old monitor's closure carried.
    func handle(_ intent: PlaybackIntent) {
        guard isSorting else { return }
        switch intent {
        case .seek(.backward):
            seek(seconds: -5)
        case .seek(.forward):
            seek(seconds: 5)
        default:
            break
        }
    }

    public func beginSorting() {
        do {
            let source = URL(fileURLWithPath: sourcePath.trimmingCharacters(in: .whitespacesAndNewlines))
            let videos = try SortingLibrary.rawVideos(in: source)
            guard !videos.isEmpty else { throw ViewerError.noVideos }
            eventDate = SortingLibrary.suggestedEventDate(from: videos[0])
            eventFolder = try SortingLibrary.eventFolder(date: eventDate, title: eventTitle)
            sourceDirectory = source
            if keepsSourceIntact {
                // `resizedDirectory` is set from the same root handed to the
                // publisher below, not derived separately — a read-only
                // session's resize never lands under `source`, so
                // `completedOutputDirectory` must not point there either.
                resizedDirectory = outputRoot
                publisher = ReadOnlySourcePublisher(resizedRoot: outputRoot)
            } else {
                let resizedRoot = source.appendingPathComponent("organized_resize", isDirectory: true)
                resizedDirectory = resizedRoot
                publisher = LocalFolderPublisher(
                    organizedRoot: source.appendingPathComponent("organized", isDirectory: true),
                    resizedRoot: resizedRoot
                )
            }
            rawVideos = videos
            currentIndex = 0
            queuedResizes = 0
            completedResizes = 0
            failedResizes = []
            completedOutputDirectory = nil
            taggingFinished = false
            isSorting = true
            status = "Tag this clip, then press Return. Left/Right seek 5 seconds. Resizing runs one at a time."
            input?.setEnabled(true)
            loadCurrentVideo()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func selectSuggestedAthlete(_ name: String) {
        athleteQuery = name
    }

    public func tagCurrentVideo() {
        if athleteQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            skipCurrentVideo()
            return
        }
        guard let video = currentVideo,
              let publisher,
              let athlete = resolvedAthlete else {
            status = "Keep typing until one athlete matches, or add a new athlete."
            return
        }
        do {
            let athlete = try SortingLibrary.athleteFolderName(athlete)
            let targets = try publisher.prepare(source: video, athlete: athlete, event: eventFolder)
            enqueueResize(
                source: targets.resizeSource,
                destination: targets.resizeDestination,
                athlete: athlete,
                skipSourceMetadata: publisher.maySkipSourceMetadata
            )
            athleteQuery = ""
            removeCurrentVideo()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func addNewAthleteAndTag() {
        guard let candidate = newAthleteCandidate else { return }
        do {
            let athlete = try SortingLibrary.athleteFolderName(candidate)
            athleteNames.append(athlete)
            athleteNames.sort {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
            persistNewAthlete(athlete)
            athleteQuery = athlete
            tagCurrentVideo()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func skipCurrentVideo() {
        guard currentVideo != nil else { return }
        removeCurrentVideo()
    }

    public func moveCurrentVideo(by offset: Int) {
        guard !rawVideos.isEmpty else { return }
        currentIndex = (currentIndex + offset + rawVideos.count) % rawVideos.count
        loadCurrentVideo()
    }

    public func stopPlayback() {
        player.pause()
        // Stands in for the `NSEvent.removeMonitor` this used to do: the source
        // must stop both delivering *and* swallowing key events, so they reach
        // the main window's input source again.
        input?.setEnabled(false)
    }

    private func removeCurrentVideo() {
        player.pause()
        rawVideos.remove(at: currentIndex)
        if currentIndex >= rawVideos.count {
            currentIndex = max(0, rawVideos.count - 1)
        }
        if rawVideos.isEmpty {
            taggingFinished = true
            status = "All clips tagged. Finishing the resize queue…"
            completeIfPossible()
        } else {
            loadCurrentVideo()
        }
    }

    private func loadCurrentVideo() {
        guard let currentVideo else { return }
        player.replaceCurrentItem(with: AVPlayerItem(url: currentVideo))
        player.play()
    }

    private func persistNewAthlete(_ athlete: String) {
        let path = namesPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let line = "\n\(athlete)"
        guard let data = line.data(using: .utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // The tag is still valid for this session if the optional name list is read-only.
            status = "Added \(athlete) for this session (could not update athletes.txt)."
        }
    }

    private func enqueueResize(source: URL, destination: URL, athlete: String, skipSourceMetadata: Bool) {
        queuedResizes += 1
        let pipeline = mediaPipeline
        resizeQueue.addOperation { [weak self] in
            let semaphore = DispatchSemaphore(value: 0)
            let box = ResultBox()
            Task.detached {
                do {
                    if !skipSourceMetadata {
                        // Writes an athlete tag into the *original*. Skipped for
                        // a read-only source: on an SD card this is a write to
                        // the only archive of the session, and failing here
                        // would abort a clip that resizes perfectly well.
                        try await pipeline.writeMetadata(athlete: athlete, to: source)
                    }
                    try await pipeline.resize(
                        source: source,
                        destination: destination,
                        athlete: athlete
                    )
                    box.result = .success(())
                } catch {
                    box.result = .failure(error)
                }
                semaphore.signal()
            }
            // Blocks this operation's thread, not the main thread, so the queue
            // still runs exactly one resize at a time.
            semaphore.wait()
            // Unreachable: the semaphore is only signalled once the box holds a
            // result. The fallback exists so that if it ever did fire, the user
            // would read about the resize rather than about missing videos.
            let result = box.result ?? .failure(SortingError.resizeProducedNoResult)

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.completedResizes += 1
                if case let .failure(error) = result {
                    self.failedResizes.append("\(source.lastPathComponent): \(error.localizedDescription)")
                    // `failedResizes` accumulates silently until the whole run
                    // finishes; an unreadable-format failure (or any other
                    // resize error) also needs to interrupt the operator with
                    // an alert, or it can go unnoticed for the rest of the
                    // tagging session. `errorDescription` (not a generic
                    // wrapper) is what reaches here — see MediaPipelineError.
                    self.errorMessage = error.localizedDescription
                }
                self.completeIfPossible()
            }
        }
    }

    private func completeIfPossible() {
        guard taggingFinished, completedResizes == queuedResizes else { return }
        if failedResizes.isEmpty, let resizedDirectory {
            completedOutputDirectory = resizedDirectory
            status = "Finished. Your resized library is ready."
        } else {
            status = "Finished with \(failedResizes.count) resize error(s)."
        }
    }

    private func seek(seconds: Double) {
        let current = player.currentTime().seconds
        let safeCurrent = current.isFinite ? current : 0
        let duration = player.currentItem?.duration.seconds ?? .nan
        var target = max(0, safeCurrent + seconds)
        if duration.isFinite {
            target = min(target, duration)
        }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }
}

/// Carries the outcome of an `async` pipeline job back to the `OperationQueue`
/// thread that is blocked waiting for it.
private final class ResultBox: @unchecked Sendable {
    var result: Result<Void, Error>?
}
