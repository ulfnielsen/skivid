import AVFoundation
import Foundation
import SkiVideoCore
import UniformTypeIdentifiers

@MainActor
final class ViewerModel: ObservableObject {
    @Published private(set) var directory: URL?
    @Published private(set) var athletes: [AthleteGroup] = []
    @Published var selectedAthleteID: String?
    @Published var athleteQuery = ""
    @Published var driveFolderID: String
    @Published var clientSecretsPath: String
    @Published private(set) var isConnectingToDrive = false
    @Published private(set) var isUsingGoogleDrive = false
    @Published private(set) var videoIndex = 0
    @Published private(set) var status = "Choose an organized video directory"
    @Published var errorMessage: String?

    let player = AVPlayer()

    private var activeAthleteID: String?
    private var hasStarted = false
    private var keyboardControlsEnabled = true
    private var heldDirection: ScrubDirection?
    private var holdWorkItem: DispatchWorkItem?
    private var reverseTimer: Timer?
    private var holdStarted = false
    private var holdPausedManually = false
    private var wasPlayingBeforeHold = false
    private var rateBeforeHold: Float = 1
    private var lastTapDirection: ScrubDirection?
    private var lastTapTime = Date.distantPast
    private var driveMediaByURL: [URL: DriveMedia] = [:]

    private let input: PlaybackInputSource
    private let folderPicker: FolderPicker
    private let now: () -> Date
    private let holdThreshold: TimeInterval

    /// Exposed so tests can assert on seeks without a playable asset.
    private(set) var lastSeekOffset: Double?

    public init(
        input: PlaybackInputSource,
        folderPicker: FolderPicker,
        now: @escaping () -> Date = Date.init,
        holdThreshold: TimeInterval = 0.22
    ) {
        self.input = input
        self.folderPicker = folderPicker
        self.now = now
        self.holdThreshold = holdThreshold
        driveFolderID = UserDefaults.standard.string(forKey: "driveFolderID") ?? ""
        clientSecretsPath = UserDefaults.standard.string(forKey: "driveClientSecretsPath") ?? ""
        self.input.onIntent = { [weak self] intent in
            self?.handle(intent)
        }
    }

    public func handle(_ intent: PlaybackIntent) {
        switch intent {
        case .togglePlayback:
            togglePlayback()
        case let .clip(step):
            changeVideo(by: step.offset)
        case let .athlete(step):
            changeAthlete(by: step.offset)
        case let .scrubBegan(direction):
            beginArrow(direction)
        case let .scrubEnded(_, performTap):
            endArrow(performTap: performTap)
        case .focusAthleteSearch, .openFolder:
            // Handled by the view layer, which owns focus and the picker.
            break
        }
    }

    var currentAthlete: AthleteGroup? {
        guard let activeAthleteID else { return nil }
        return athletes.first { $0.id == activeAthleteID }
    }

    var filteredAthletes: [AthleteGroup] {
        let query = normalizedName(athleteQuery)
        guard !query.isEmpty else { return athletes }
        return athletes.filter { normalizedName($0.name).contains(query) }
    }

    var currentVideo: URL? {
        guard let athlete = currentAthlete,
              athlete.videos.indices.contains(videoIndex)
        else {
            return nil
        }
        return athlete.videos[videoIndex]
    }

    var currentPlaybackURL: URL? {
        guard let currentVideo else { return nil }
        return driveMediaByURL[currentVideo]?.streamingURL ?? currentVideo
    }

    var comparisonLibrary: [ComparisonAthleteChoice] {
        athletes.map { athlete in
            ComparisonAthleteChoice(
                id: athlete.id,
                name: athlete.name,
                videos: athlete.videos.map { video in
                    ComparisonVideoChoice(
                        id: "\(athlete.id)|\(video.absoluteString)",
                        name: video.lastPathComponent,
                        playbackURL: driveMediaByURL[video]?.streamingURL ?? video
                    )
                }
            )
        }
    }

    var clipDescription: String {
        guard let athlete = currentAthlete, let currentVideo else { return "" }
        return "Clip \(videoIndex + 1) of \(athlete.videos.count) · \(currentVideo.lastPathComponent)"
    }

    func start(initialDirectory: URL?) {
        guard !hasStarted else { return }
        hasStarted = true
        if let initialDirectory {
            openDirectory(initialDirectory)
        } else if directory == nil {
            Task { [weak self] in
                await self?.chooseDirectory()
            }
        }
    }

    func chooseDirectory() async {
        guard let url = await folderPicker.pickFolder(startingAt: directory) else {
            return
        }
        openDirectory(url)
    }

    func setKeyboardControlsEnabled(_ enabled: Bool) {
        keyboardControlsEnabled = enabled
        input.setEnabled(enabled)
        if !enabled {
            endArrow(performTap: false)
        }
    }

    func chooseClientSecretsFile() async {
        guard let url = await folderPicker.pickFile(ofType: .json) else { return }
        clientSecretsPath = url.path
        UserDefaults.standard.set(clientSecretsPath, forKey: "driveClientSecretsPath")
    }

    func connectGoogleDrive() {
        let folderID = driveFolderID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecretsPath = clientSecretsPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folderID.isEmpty, !clientSecretsPath.isEmpty else {
            errorMessage = DriveError.missingConfiguration.localizedDescription
            return
        }
        let clientSecretsURL = URL(fileURLWithPath: clientSecretsPath)
        guard FileManager.default.isReadableFile(atPath: clientSecretsURL.path) else {
            errorMessage = "The selected Google OAuth client-secret file cannot be read."
            return
        }

        UserDefaults.standard.set(folderID, forKey: "driveFolderID")
        isConnectingToDrive = true
        status = "Connecting to Google Drive…"
        Task {
            do {
                let drive = try await GoogleDriveClient.connect(clientSecretsURL: clientSecretsURL)
                status = "Scanning Shared Drive…"
                let library = try await drive.scanSharedDrive(folderID: folderID)
                guard !library.athletes.isEmpty else { throw ViewerError.noVideos }
                endArrow(performTap: false)
                player.pause()
                directory = nil
                athletes = library.athletes
                driveMediaByURL = library.mediaByURL
                isUsingGoogleDrive = true
                activeAthleteID = nil
                selectedAthleteID = library.athletes[0].id
                athleteQuery = ""
                selectAthlete(library.athletes[0].id)
                status = "Google Drive connected"
            } catch {
                errorMessage = error.localizedDescription
                status = "Could not connect to Google Drive"
            }
            isConnectingToDrive = false
        }
    }

    func openDirectory(_ url: URL) {
        do {
            let scannedAthletes = try VideoLibrary.scan(url)
            guard !scannedAthletes.isEmpty else { throw ViewerError.noVideos }
            endArrow(performTap: false)
            player.pause()
            directory = url
            athletes = scannedAthletes
            driveMediaByURL = [:]
            isUsingGoogleDrive = false
            activeAthleteID = nil
            selectedAthleteID = scannedAthletes[0].id
            selectAthlete(scannedAthletes[0].id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectAthlete(_ id: String?) {
        guard let id,
              id != activeAthleteID,
              athletes.contains(where: { $0.id == id })
        else {
            return
        }
        endArrow(performTap: false)
        activeAthleteID = id
        selectedAthleteID = id
        videoIndex = 0
        loadCurrentVideo()
    }

    @discardableResult
    func changeVideo(by offset: Int) -> Bool {
        guard let athlete = currentAthlete, !athlete.videos.isEmpty else {
            return false
        }
        endArrow(performTap: false)
        videoIndex = (videoIndex + offset + athlete.videos.count) % athlete.videos.count
        loadCurrentVideo()
        return true
    }

    @discardableResult
    func changeAthlete(by offset: Int) -> Bool {
        guard !athletes.isEmpty,
              let currentIndex = athletes.firstIndex(where: { $0.id == activeAthleteID })
        else {
            return false
        }
        let nextIndex = (currentIndex + offset + athletes.count) % athletes.count
        selectAthlete(athletes[nextIndex].id)
        return true
    }

    func selectFirstMatchingAthlete() {
        guard let athlete = filteredAthletes.first else { return }
        selectAthlete(athlete.id)
    }

    func togglePlayback() {
        guard currentVideo != nil else { return }
        if let heldDirection, holdStarted {
            if player.rate == 0 {
                holdPausedManually = false
                resumeHeldPlayback(heldDirection)
            } else {
                holdPausedManually = true
                pauseHeldPlayback(heldDirection)
            }
            return
        }
        if player.rate == 0 {
            player.playImmediately(atRate: 1)
            status = "Playing"
        } else {
            player.pause()
            status = "Paused"
        }
    }

    func beginArrow(_ direction: ScrubDirection) {
        guard currentVideo != nil, heldDirection == nil else { return }
        heldDirection = direction
        holdStarted = false

        let workItem = DispatchWorkItem { [weak self] in
            self?.startHold()
        }
        holdWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: workItem)
    }

    func endArrow(performTap: Bool = true) {
        guard let direction = heldDirection else { return }
        holdWorkItem?.cancel()
        holdWorkItem = nil
        reverseTimer?.invalidate()
        reverseTimer = nil
        heldDirection = nil

        if holdStarted {
            player.pause()
            if holdPausedManually {
                status = "Paused"
            } else if wasPlayingBeforeHold {
                player.playImmediately(atRate: rateBeforeHold)
                status = "Playing"
            } else {
                status = "Paused"
            }
        } else if performTap {
            performArrowTap(direction)
        }
        holdStarted = false
        holdPausedManually = false
    }

    private func loadCurrentVideo() {
        guard let currentVideo else { return }
        if let media = driveMediaByURL[currentVideo] {
            player.replaceCurrentItem(with: AVPlayerItem(url: media.streamingURL))
        } else {
            player.replaceCurrentItem(with: AVPlayerItem(url: currentVideo))
        }
        player.pause()
        status = "Paused · Space to play"
    }

    private func seek(seconds: Double) {
        lastSeekOffset = seconds
        guard player.currentItem != nil else { return }
        let currentSeconds = player.currentTime().seconds
        let safeCurrent = currentSeconds.isFinite ? currentSeconds : 0
        var targetSeconds = max(0, safeCurrent + seconds)
        let duration = player.currentItem?.duration.seconds ?? .nan
        if duration.isFinite {
            targetSeconds = min(targetSeconds, duration)
        }
        let target = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func performArrowTap(_ direction: ScrubDirection) {
        let timestamp = now()
        let isDoubleTap = lastTapDirection == direction
            && timestamp.timeIntervalSince(lastTapTime) <= 0.38
        let seconds = isDoubleTap ? 5.0 : 1.0
        seek(seconds: Double(direction.rawValue) * seconds)
        status = "\(direction == .forward ? "Forward" : "Back") \(isDoubleTap ? 5 : 1) seconds"
        lastTapDirection = isDoubleTap ? nil : direction
        lastTapTime = isDoubleTap ? .distantPast : timestamp
    }

    private func startHold() {
        guard let direction = heldDirection else { return }
        holdStarted = true
        holdPausedManually = false
        wasPlayingBeforeHold = player.rate != 0
        rateBeforeHold = player.rate == 0 ? 1 : abs(player.rate)

        resumeHeldPlayback(direction)
    }

    private func resumeHeldPlayback(_ direction: ScrubDirection) {
        switch direction {
        case .forward:
            player.playImmediately(atRate: 0.35)
            status = "Slow forward"
        case .backward:
            if player.currentItem?.canPlayReverse == true {
                player.playImmediately(atRate: -0.35)
            } else {
                player.pause()
                let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.seek(seconds: -0.08)
                    }
                }
                reverseTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
            status = "Slow backward"
        }
    }

    private func pauseHeldPlayback(_ direction: ScrubDirection) {
        if direction == .backward {
            reverseTimer?.invalidate()
            reverseTimer = nil
        }
        player.pause()
        status = "Slow \(direction == .forward ? "forward" : "backward") paused"
    }

    private func normalizedName(_ name: String) -> String {
        name.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }
}
