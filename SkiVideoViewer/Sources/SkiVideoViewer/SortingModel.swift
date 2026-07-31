import AppKit
import AVFoundation
import Foundation
import SkiVideoCore
import UniformTypeIdentifiers

@MainActor
final class SortingModel: ObservableObject {
    @Published var sourcePath = ""
    @Published var namesPath: String
    @Published var eventDate = Date()
    @Published var eventTitle = ""
    @Published var athleteQuery = ""
    @Published private(set) var athleteNames: [String] = []
    @Published private(set) var rawVideos: [URL] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var isSorting = false
    @Published private(set) var queuedResizes = 0
    @Published private(set) var completedResizes = 0
    @Published private(set) var failedResizes: [String] = []
    @Published private(set) var status = "Choose a folder of raw clips."
    @Published var errorMessage: String?
    @Published private(set) var completedOutputDirectory: URL?

    let player = AVPlayer()
    private let resizeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "ch.ski.video-viewer.resize"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var sourceDirectory: URL?
    private var organizedDirectory: URL?
    private var resizedDirectory: URL?
    private var eventFolder = ""
    private var taggingFinished = false
    private var keyboardMonitor: Any?

    init() {
        let defaultNames = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Ski/athletes.txt")
        namesPath = FileManager.default.fileExists(atPath: defaultNames.path) ? defaultNames.path : ""
        reloadNames()
    }

    var currentVideo: URL? {
        rawVideos.indices.contains(currentIndex) ? rawVideos[currentIndex] : nil
    }

    var matchingAthletes: [String] {
        SortingLibrary.matches(for: athleteQuery, names: athleteNames)
    }

    var resolvedAthlete: String? {
        matchingAthletes.count == 1 ? matchingAthletes[0] : nil
    }

    var newAthleteCandidate: String? {
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

    var progressLabel: String {
        let remaining = rawVideos.count
        if taggingFinished {
            return "Tagging complete · resizing \(completedResizes) of \(queuedResizes)"
        }
        return "\(remaining) clip\(remaining == 1 ? "" : "s") left to tag · \(queuedResizes - completedResizes) waiting to resize"
    }

    func chooseSourceDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose folder containing raw videos"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            sourcePath = url.path
            if let firstVideo = try? SortingLibrary.rawVideos(in: url).first {
                eventDate = SortingLibrary.suggestedEventDate(from: firstVideo)
            }
        }
    }

    func chooseNamesFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose athlete-name list"
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            namesPath = url.path
            reloadNames()
        }
    }

    func reloadNames() {
        let url = namesPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : URL(fileURLWithPath: namesPath)
        athleteNames = SortingLibrary.athleteNames(from: url)
    }

    func beginSorting() {
        do {
            let source = URL(fileURLWithPath: sourcePath.trimmingCharacters(in: .whitespacesAndNewlines))
            let videos = try SortingLibrary.rawVideos(in: source)
            guard !videos.isEmpty else { throw ViewerError.noVideos }
            eventDate = SortingLibrary.suggestedEventDate(from: videos[0])
            eventFolder = try SortingLibrary.eventFolder(date: eventDate, title: eventTitle)
            sourceDirectory = source
            organizedDirectory = source.appendingPathComponent("organized", isDirectory: true)
            resizedDirectory = source.appendingPathComponent("organized_resize", isDirectory: true)
            rawVideos = videos
            currentIndex = 0
            queuedResizes = 0
            completedResizes = 0
            failedResizes = []
            completedOutputDirectory = nil
            taggingFinished = false
            isSorting = true
            status = "Tag this clip, then press Return. Left/Right seek 5 seconds. Resizing runs one at a time."
            startKeyboardMonitoring()
            loadCurrentVideo()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectSuggestedAthlete(_ name: String) {
        athleteQuery = name
    }

    func tagCurrentVideo() {
        if athleteQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            skipCurrentVideo()
            return
        }
        guard let video = currentVideo,
              let organizedDirectory,
              let resizedDirectory,
              let athlete = resolvedAthlete else {
            status = "Keep typing until one athlete matches, or add a new athlete."
            return
        }
        do {
            let athlete = try SortingLibrary.athleteFolderName(athlete)
            let organizedTarget = organizedDirectory
                .appendingPathComponent(eventFolder, isDirectory: true)
                .appendingPathComponent(athlete, isDirectory: true)
                .appendingPathComponent(video.lastPathComponent)
            let resizedTarget = resizedDirectory
                .appendingPathComponent(eventFolder, isDirectory: true)
                .appendingPathComponent(athlete, isDirectory: true)
                .appendingPathComponent(video.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: organizedTarget.path),
                  !FileManager.default.fileExists(atPath: resizedTarget.path) else {
                throw SortingError.outputExists(organizedTarget.path)
            }
            try FileManager.default.createDirectory(
                at: organizedTarget.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: video, to: organizedTarget)
            enqueueResize(source: organizedTarget, destination: resizedTarget, athlete: athlete)
            athleteQuery = ""
            removeCurrentVideo()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addNewAthleteAndTag() {
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

    func skipCurrentVideo() {
        guard currentVideo != nil else { return }
        removeCurrentVideo()
    }

    func moveCurrentVideo(by offset: Int) {
        guard !rawVideos.isEmpty else { return }
        currentIndex = (currentIndex + offset + rawVideos.count) % rawVideos.count
        loadCurrentVideo()
    }

    func stopPlayback() {
        player.pause()
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
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

    private func enqueueResize(source: URL, destination: URL, athlete: String) {
        queuedResizes += 1
        resizeQueue.addOperation { [weak self] in
            let result: Result<Void, Error>
            do {
                try Self.writeAthleteMetadata(athlete, to: source)
                try Self.resize(source: source, destination: destination, athlete: athlete)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.completedResizes += 1
                if case let .failure(error) = result {
                    self.failedResizes.append("\(source.lastPathComponent): \(error.localizedDescription)")
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

    private func startKeyboardMonitoring() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isSorting,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            else { return event }
            switch event.keyCode {
            case 123:
                self.seek(seconds: -5)
                return nil
            case 124:
                self.seek(seconds: 5)
                return nil
            default:
                return event
            }
        }
    }

    nonisolated private static func writeAthleteMetadata(_ athlete: String, to source: URL) throws {
        let temporary = source.deletingLastPathComponent().appendingPathComponent(
            ".metadata-\(UUID().uuidString).\(source.pathExtension)"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try runFFmpeg([
            "-i", source.path,
            // Camera files can contain telemetry/data tracks that MP4 cannot remux.
            // Preserve the playable streams and the container metadata, but omit
            // those proprietary tracks from the tagged copy.
            "-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0", "-c", "copy",
            "-metadata", "title=\(athlete)",
            "-metadata", "artist=\(athlete)",
            "-metadata", "comment=Athlete: \(athlete)",
            temporary.path,
        ])
        _ = try FileManager.default.replaceItemAt(source, withItemAt: temporary)
    }

    nonisolated private static func resize(source: URL, destination: URL, athlete: String) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try runFFmpeg([
            "-i", source.path,
            "-vf", "scale=w=1920:h=1080:force_original_aspect_ratio=decrease",
            "-metadata", "title=\(athlete)",
            "-metadata", "artist=\(athlete)",
            "-metadata", "comment=Athlete: \(athlete)",
            destination.path,
        ])
    }

    nonisolated private static func runFFmpeg(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"] + arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "SkiVideoViewer.Resize",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message?.isEmpty == false ? message! : "ffmpeg failed"]
            )
        }
    }

    deinit {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
        }
    }
}
