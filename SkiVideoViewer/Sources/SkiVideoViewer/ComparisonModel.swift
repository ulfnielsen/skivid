import AppKit
import AVFoundation
import Foundation
import SkiVideoCore
import UniformTypeIdentifiers

enum ComparisonSide {
    case left
    case right
}

enum ComparisonLayout: String, CaseIterable, Identifiable {
    case sideBySide
    case overlay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sideBySide: return "Side-by-side"
        case .overlay: return "Overlay"
        }
    }
}

enum OverlayBlend: String, CaseIterable, Identifiable {
    case blend
    case difference

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blend: return "Blend"
        case .difference: return "Difference"
        }
    }
}

@MainActor
final class ComparisonModel: ObservableObject {
    @Published private(set) var leftName = "Choose left video"
    @Published private(set) var rightName = "Choose right video"
    @Published private(set) var leftTime = 0.0
    @Published private(set) var rightTime = 0.0
    @Published private(set) var leftDuration = 0.0
    @Published private(set) var rightDuration = 0.0
    @Published private(set) var isSynced = false
    @Published private(set) var status = "Choose two videos and align them independently."
    @Published var layout: ComparisonLayout = .sideBySide
    @Published var overlayOpacity: Double = 0.5
    @Published var blend: OverlayBlend = .blend

    let leftPlayer = AVPlayer()
    let rightPlayer = AVPlayer()
    let openLibrary: [ComparisonAthleteChoice]

    private var leftSyncPoint = CMTime.zero
    private var rightSyncPoint = CMTime.zero
    private var leftTimeObserver: Any?
    private var rightTimeObserver: Any?
    private var leftDurationObserver: NSKeyValueObservation?
    private var rightDurationObserver: NSKeyValueObservation?
    private var keyboardMonitor: Any?
    private var playbackGeneration = 0

    init(initialLeftVideo: URL? = nil, openLibrary: [ComparisonAthleteChoice] = []) {
        self.openLibrary = openLibrary
        leftPlayer.automaticallyWaitsToMinimizeStalling = false
        rightPlayer.automaticallyWaitsToMinimizeStalling = false
        installTimeObservers()
        startKeyboardMonitoring()
        if let initialLeftVideo {
            load(initialLeftVideo, side: .left)
        }
    }

    var hasTwoVideos: Bool {
        leftPlayer.currentItem != nil && rightPlayer.currentItem != nil
    }

    /// Difference blending only reads correctly at full opacity, so the slider
    /// is ignored (and disabled in the UI) while difference mode is active.
    var topLayerOpacity: Double {
        blend == .difference ? 1.0 : overlayOpacity
    }

    func chooseVideo(side: ComparisonSide) {
        let panel = NSOpenPanel()
        panel.title = side == .left ? "Choose left comparison video" : "Choose right comparison video"
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie]
        if panel.runModal() == .OK, let url = panel.url {
            load(url, side: side)
        }
    }

    func load(_ url: URL, side: ComparisonSide) {
        let player = player(for: side)
        player.pause()
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        observeDuration(of: item, side: side)
        switch side {
        case .left:
            leftName = url.lastPathComponent
            leftTime = 0
            leftDuration = 0
        case .right:
            rightName = url.lastPathComponent
            rightTime = 0
            rightDuration = 0
        }
        clearSync(message: "Align both videos, then set the sync points.")
    }

    func load(_ choice: ComparisonVideoChoice, side: ComparisonSide) {
        load(choice.playbackURL, side: side)
        switch side {
        case .left:
            leftName = choice.name
        case .right:
            rightName = choice.name
        }
    }

    func toggleIndividual(_ side: ComparisonSide) {
        if isSynced {
            if leftPlayer.rate == 0 && rightPlayer.rate == 0 {
                playSynced()
            } else {
                pauseBoth()
            }
            return
        }
        clearSync(message: "Alignment changed. Set sync points again when ready.")
        let player = player(for: side)
        if player.rate == 0 {
            player.playImmediately(atRate: 1)
        } else {
            player.pause()
        }
    }

    func playIndividual(_ side: ComparisonSide, rate: Float) {
        if isSynced {
            playSynced(rate: rate)
            return
        }
        let player = player(for: side)
        player.playImmediately(atRate: rate)
        status = "Playing \(side == .left ? "left" : "right") at \(String(format: "%.2g", rate))×"
    }

    func seek(_ side: ComparisonSide, by seconds: Double) {
        if isSynced {
            seekSynced(by: seconds)
            return
        }
        clearSync(message: "Alignment changed. Set sync points again when ready.")
        seek(player(for: side), to: currentTime(for: side) + seconds)
    }

    func seek(_ side: ComparisonSide, to seconds: Double) {
        if isSynced {
            seekSynced(by: seconds - currentTime(for: side))
            return
        }
        clearSync(message: "Alignment changed. Set sync points again when ready.")
        seek(player(for: side), to: seconds)
    }

    func scrub(_ side: ComparisonSide, to seconds: Double) {
        guard isSynced else {
            seek(player(for: side), to: seconds)
            return
        }

        playbackGeneration += 1
        leftPlayer.pause()
        rightPlayer.pause()
        let syncOffset = rightSyncPoint.seconds - leftSyncPoint.seconds
        switch side {
        case .left:
            seek(leftPlayer, to: seconds)
            seek(rightPlayer, to: seconds + syncOffset)
        case .right:
            seek(rightPlayer, to: seconds)
            seek(leftPlayer, to: seconds - syncOffset)
        }
        status = "Scrubbing together"
    }

    func setSyncPoints() {
        guard hasTwoVideos else {
            status = "Choose both videos before setting sync points."
            return
        }
        pauseBoth()
        leftSyncPoint = leftPlayer.currentTime()
        rightSyncPoint = rightPlayer.currentTime()
        isSynced = true
        status = "Synchronized from L \(Self.timecode(leftTime)) and R \(Self.timecode(rightTime))."
    }

    func removeSync() {
        pauseBoth()
        isSynced = false
        status = "Independent controls restored. Align the videos and set new sync points when ready."
    }

    func playSynced(rate: Float = 1) {
        guard isSynced else {
            status = "Set the sync points first."
            return
        }
        leftPlayer.pause()
        rightPlayer.pause()
        playbackGeneration += 1
        let requestedGeneration = playbackGeneration
        let clock = CMClockGetHostTimeClock()
        let startTime = CMClockGetTime(clock) + CMTime(seconds: 0.12, preferredTimescale: 600)
        leftPlayer.setRate(rate, time: leftPlayer.currentTime(), atHostTime: startTime)
        rightPlayer.setRate(rate, time: rightPlayer.currentTime(), atHostTime: startTime)
        status = rate == 1 ? "Playing together" : "Slow motion together · \(String(format: "%.2g", rate))×"
        // Some file/decoder combinations do not accept a scheduled start until
        // their timebase is fully ready. Fall back to an immediate paired start.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.isSynced,
                  self.playbackGeneration == requestedGeneration,
                  self.leftPlayer.rate == 0 || self.rightPlayer.rate == 0 else { return }
            self.leftPlayer.playImmediately(atRate: rate)
            self.rightPlayer.playImmediately(atRate: rate)
            self.status = rate == 1 ? "Playing together" : "Slow motion together · \(String(format: "%.2g", rate))×"
        }
    }

    func pauseBoth() {
        playbackGeneration += 1
        leftPlayer.pause()
        rightPlayer.pause()
        if isSynced {
            status = "Paused together"
        }
    }

    func seekSynced(by seconds: Double) {
        guard isSynced else {
            status = "Set the sync points first."
            return
        }
        pauseBoth()
        let leftTarget = leftPlayer.currentTime().seconds + seconds
        let rightTarget = rightPlayer.currentTime().seconds + seconds
        seek(leftPlayer, to: leftTarget)
        seek(rightPlayer, to: rightTarget)
        status = "Both moved \(seconds >= 0 ? "+" : "")\(Int(seconds)) seconds"
    }

    func returnToSyncPoints() {
        guard isSynced else { return }
        pauseBoth()
        leftPlayer.seek(to: leftSyncPoint, toleranceBefore: .zero, toleranceAfter: .zero)
        rightPlayer.seek(to: rightSyncPoint, toleranceBefore: .zero, toleranceAfter: .zero)
        status = "Returned to the sync points"
    }

    func close() {
        leftPlayer.pause()
        rightPlayer.pause()
        if let leftTimeObserver {
            leftPlayer.removeTimeObserver(leftTimeObserver)
            self.leftTimeObserver = nil
        }
        if let rightTimeObserver {
            rightPlayer.removeTimeObserver(rightTimeObserver)
            self.rightTimeObserver = nil
        }
        leftDurationObserver = nil
        rightDurationObserver = nil
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
    }

    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00.0" }
        let minutes = Int(seconds) / 60
        let remainder = seconds - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, remainder)
    }

    private func player(for side: ComparisonSide) -> AVPlayer {
        side == .left ? leftPlayer : rightPlayer
    }

    private func currentTime(for side: ComparisonSide) -> Double {
        side == .left ? leftTime : rightTime
    }

    private func seek(_ player: AVPlayer, to seconds: Double) {
        let duration = player.currentItem?.duration.seconds ?? .nan
        var target = max(0, seconds.isFinite ? seconds : 0)
        if duration.isFinite {
            target = min(target, duration)
        }
        player.currentItem?.cancelPendingSeeks()
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func clearSync(message: String) {
        if isSynced {
            pauseBoth()
        }
        isSynced = false
        status = message
    }

    private func installTimeObservers() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        leftTimeObserver = leftPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.leftTime = time.seconds.isFinite ? time.seconds : 0
                let duration = self.leftPlayer.currentItem?.duration.seconds ?? .nan
                if duration.isFinite { self.leftDuration = duration }
            }
        }
        rightTimeObserver = rightPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.rightTime = time.seconds.isFinite ? time.seconds : 0
                let duration = self.rightPlayer.currentItem?.duration.seconds ?? .nan
                if duration.isFinite { self.rightDuration = duration }
            }
        }
    }

    private func observeDuration(of item: AVPlayerItem, side: ComparisonSide) {
        let observation = item.observe(\.duration, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, let item, self.player(for: side).currentItem === item else { return }
                let duration = item.duration.seconds
                guard duration.isFinite, duration > 0 else { return }
                switch side {
                case .left:
                    self.leftDuration = duration
                case .right:
                    self.rightDuration = duration
                }
            }
        }
        switch side {
        case .left:
            leftDurationObserver = observation
        case .right:
            rightDurationObserver = observation
        }
    }

    private func startKeyboardMonitoring() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            else { return event }
            switch event.keyCode {
            case 49 where !event.isARepeat: // Space
                if self.leftPlayer.rate == 0 && self.rightPlayer.rate == 0 {
                    self.playSynced()
                } else {
                    self.pauseBoth()
                }
                return nil
            case 123 where !event.isARepeat: // Left
                self.seekSynced(by: -1)
                return nil
            case 124 where !event.isARepeat: // Right
                self.seekSynced(by: 1)
                return nil
            default:
                return event
            }
        }
    }
}
