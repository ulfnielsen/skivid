import AVFoundation
import Foundation

/// Platform-agnostic playback state. Everything platform-specific reaches it
/// through the seams in `Seams.swift`, so the same model backs the macOS app
/// and, in phase 2, an iPadOS one.
///
/// Access levels are deliberately narrow: `public` marks exactly what the app
/// target's views and `App` struct touch. Members used only by tests stay
/// internal and are reached with `@testable import SkiVideoCore`.
@MainActor
public final class ViewerModel: ObservableObject {
    @Published public private(set) var directory: URL?
    @Published public private(set) var athletes: [AthleteGroup] = []
    @Published public var selectedAthleteID: String?
    @Published public var athleteQuery = ""
    /// Internal: no view reads it, but the intent tests assert on it.
    @Published private(set) var videoIndex = 0
    @Published public private(set) var status = "Choose an organized video directory"
    @Published public var errorMessage: String?
    /// Position and length of the current clip, for the scrubber and the time
    /// readout. Published for the same reason `ComparisonModel` publishes its
    /// pair: `AVPlayer` reports neither, so a view that wants them has to be
    /// told.
    @Published public private(set) var currentTime = 0.0
    @Published public private(set) var duration = 0.0
    /// Whether the player is actually moving. Derived from the player by KVO —
    /// see `startObservingRate` — not written by hand at each call site, because
    /// there are several of those (`togglePlayback`, `applyTransport`'s `.slow`,
    /// `SlowMotionHold.begin`/`.end` and `loadCurrentVideo`) and another is one
    /// refactor away.
    ///
    /// `ContentView` uses it to give up the athlete-search field's focus once
    /// the operator starts watching, so Space reaches the transport instead of
    /// being typed into the field.
    @Published public private(set) var isPlaying = false

    /// How far into the current clip the operator has zoomed.
    ///
    /// Kept across clip and athlete changes — watching several runs of one
    /// drill at a fixed magnification is what the control is for — and reset in
    /// `openDirectory`/`openRemoteLibrary`, where a pan into one library's
    /// corner says nothing about another's.
    @Published public private(set) var zoom = VideoZoom()

    public let player = AVPlayer()

    /// The cloud library, when one is open. Nil for a local folder.
    private var remoteIndex: RemoteLibraryIndex?
    private var remoteProvider: (any RemoteLibraryProvider)?
    private var clipCache: ClipCache?

    @Published public private(set) var isUsingRemoteLibrary = false
    /// True while the current clip's bytes are being fetched. The view shows
    /// progress instead of an empty player.
    @Published public private(set) var isPreparingClip = false

    /// Mirrors the cache for synchronous reads. `currentPlaybackURL` and
    /// `comparisonLibrary` are computed properties a SwiftUI view reads
    /// directly, so neither can await an actor.
    private var materialisedByFileID: [String: URL] = [:]

    private var activeAthleteID: String?
    private var hasStarted = false
    private let hold = SlowMotionHold()
    private var lastTapDirection: ScrubDirection?
    private var lastTapTime = Date.distantPast
    private var timeObserver: Any?
    private var durationObserver: NSKeyValueObservation?
    private var rateObserver: NSKeyValueObservation?

    private let input: PlaybackInputSource
    private let folderPicker: FolderPicker
    private let oauthPresenter: OAuthPresenter
    private let now: () -> Date

    /// Exposed so tests can assert on seeks without a playable asset.
    private(set) var lastSeekOffset: Double?

    public init(
        input: PlaybackInputSource,
        folderPicker: FolderPicker,
        oauthPresenter: OAuthPresenter,
        now: @escaping () -> Date = Date.init
    ) {
        self.input = input
        self.folderPicker = folderPicker
        self.oauthPresenter = oauthPresenter
        self.now = now
        self.input.onIntent = { [weak self] intent in
            self?.handle(intent)
        }
        startObservingTime()
        startObservingRate()
    }

    /// `ViewerModel` has no `close()` the way `ComparisonModel` does — it is
    /// expected to live for the app's lifetime — but `removeTimeObserver` is
    /// cheap and correct to call anyway rather than leave `timeObserver` as
    /// write-only storage.
    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    /// Internal: the model subscribes itself to `input.onIntent`, so no caller
    /// outside the module drives it directly.
    func handle(_ intent: PlaybackIntent) {
        switch intent {
        case .togglePlayback:
            togglePlayback()
        case let .clip(step):
            changeVideo(by: step.offset)
        case let .athlete(step):
            changeAthlete(by: step.offset)
        case let .seek(direction):
            hold.end()
            performArrowTap(direction)
        case let .slowMotionBegan(direction):
            // Two different preconditions, and neither subsumes the other.
            //
            // `currentVideo != nil` is the viewer's own: with no clip selected
            // there is nothing to scrub, and the player still exists, so
            // `begin` would happily hold an item-less player. This is the only
            // copy of that rule.
            //
            // `hold.begin`'s answer is the shared one, and it is read rather
            // than re-derived on purpose: the status line is written here, so a
            // refused `begin` must not word the status after a hold it did not
            // start. It matters for the cross-direction press — ⌘→ held, then
            // ⌘← without releasing — where the player keeps running forward and
            // an unguarded write would announce "Slow backward" over it. This
            // used to be a local `!hold.isActive`, which was the same rule
            // written out a second time; `ComparisonModel` wrote it out a third
            // time and got it wrong. Short-circuiting matters: `begin` is not
            // reached, and so cannot start a hold, when there is no clip.
            guard currentVideo != nil,
                  hold.begin(direction, players: [player])
            else { return }
            status = direction == .forward ? "Slow forward" : "Slow backward"
        case .slowMotionEnded:
            endSlowMotion()
        case .focusAthleteSearch, .openFolder:
            // Handled by the view layer, which owns focus and the picker.
            break
        }
    }

    public var currentAthlete: AthleteGroup? {
        guard let activeAthleteID else { return nil }
        return athletes.first { $0.id == activeAthleteID }
    }

    public var filteredAthletes: [AthleteGroup] {
        let query = normalizedName(athleteQuery)
        guard !query.isEmpty else { return athletes }
        return athletes.filter {
            normalizedName($0.name).contains(query)
                || normalizedName($0.event ?? "").contains(query)
        }
    }

    /// `filteredAthletes` in sidebar sections — the grouping already sorted
    /// every event's athletes together, so one forward pass is enough and the
    /// sections come out in the same order as the flat list. Computed, never
    /// stored: the flat array stays the source of truth because selection-by-id,
    /// `changeAthlete` and the Page keys all run on it.
    public var events: [EventGroup] {
        EventGroup.sections(of: filteredAthletes)
    }

    var currentVideo: URL? {
        guard let athlete = currentAthlete,
              athlete.videos.indices.contains(videoIndex)
        else {
            return nil
        }
        return athlete.videos[videoIndex]
    }

    /// What playback opens. A local library's URLs are already files; a cloud
    /// library's resolve to whatever the cache holds, and to nil until the
    /// bytes land — there is nothing to play before then, and handing back a
    /// path to a missing file would show an error instead of progress.
    public var currentPlaybackURL: URL? {
        guard let currentVideo else { return nil }
        guard let remoteIndex, let file = remoteIndex.file(for: currentVideo) else {
            return currentVideo
        }
        return cachedRemoteURL(for: file)
    }

    private func cachedRemoteURL(for file: RemoteFile) -> URL? {
        materialisedByFileID[file.id]
    }

    public var comparisonLibrary: [ComparisonAthleteChoice] {
        athletes.map { athlete in
            ComparisonAthleteChoice(
                id: athlete.id,
                // The picker draws a flat menu with no section headers, so two
                // Alices from two events would be indistinguishable without
                // this. Left alone when there is no event, so a single-event
                // library reads exactly as it always has.
                name: athlete.event.map { "\(athlete.name) — \($0)" } ?? athlete.name,
                videos: athlete.videos.map { video in
                    ComparisonVideoChoice(
                        id: "\(athlete.id)|\(video.absoluteString)",
                        name: video.lastPathComponent,
                        playbackURL: remoteIndex?.file(for: video)
                            .flatMap { materialisedByFileID[$0.id] } ?? video
                    )
                }
            )
        }
    }

    public var clipDescription: String {
        guard let athlete = currentAthlete, let currentVideo else { return "" }
        let position = "Clip \(videoIndex + 1) of \(athlete.videos.count)"
        guard let event = athlete.event else {
            return "\(position) · \(currentVideo.lastPathComponent)"
        }
        return "\(position) · \(event) · \(currentVideo.lastPathComponent)"
    }

    public func start(initialDirectory: URL?) {
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

    public func chooseDirectory() async {
        guard let url = await folderPicker.pickFolder(
            startingAt: directory,
            title: "Choose organized video directory",
            confirmLabel: "Open"
        ) else {
            return
        }
        openDirectory(url)
    }

    public func setKeyboardControlsEnabled(_ enabled: Bool) {
        input.setEnabled(enabled)
        if !enabled {
            endSlowMotion()
        }
    }

    /// Opens a cloud library: index it, group it, show it. No bytes are
    /// fetched — a clip downloads when it is selected.
    public func openRemoteLibrary(
        provider: any RemoteLibraryProvider,
        root: RemoteFolder,
        cache: ClipCache
    ) async throws {
        status = "Listing \(root.name)…"
        var files: [RemoteFile] = []
        for try await file in provider.enumerate(root) {
            files.append(file)
        }
        let index = RemoteLibraryIndex(
            providerIdentifier: type(of: provider).identifier,
            rootName: root.name,
            files: files
        )
        guard !index.athletes.isEmpty else { throw ViewerError.noVideos }

        endSlowMotion()
        player.pause()
        directory = nil
        remoteIndex = index
        remoteProvider = provider
        clipCache = cache
        materialisedByFileID = [:]
        isUsingRemoteLibrary = true
        athletes = index.athletes
        activeAthleteID = nil
        selectedAthleteID = index.athletes[0].id
        athleteQuery = ""
        zoom.reset()
        selectAthlete(index.athletes[0].id)
        status = "\(root.name) — \(files.count) clips"
    }

    /// Brings the selected clip's bytes to disk, so playback and analysis have
    /// a real file. A no-op for a local library.
    public func prepareCurrentClip() async throws {
        guard let currentVideo,
              let remoteIndex, let remoteProvider, let clipCache,
              let file = remoteIndex.file(for: currentVideo)
        else { return }

        // Captured before the await, so the reload below can tell whether the
        // coach moved on while this clip was downloading.
        let videoAtRequest = currentVideo

        isPreparingClip = true
        defer { isPreparingClip = false }
        status = "Fetching \(file.name)…"
        let source = try await remoteProvider.downloadSource(for: file)
        materialisedByFileID[file.id] = try await clipCache.materialize(file, source: source)
        await clipCache.recordPlayback(
            of: file.identity(inProvider: remoteIndex.providerIdentifier)
        )
        // The player was pointed at nothing while the bytes were arriving, so
        // it has to be told they landed — without this the pane stays empty
        // until the next selection change, and the clip a coach asked for
        // never appears. Guarded against the selection having moved on during
        // the download, which would otherwise load the wrong clip.
        guard currentVideo == videoAtRequest else { return }
        loadCurrentVideo()
        status = file.name
    }

    public func openDirectory(_ url: URL) {
        do {
            let scannedAthletes = try VideoLibrary.scan(url)
            guard !scannedAthletes.isEmpty else { throw ViewerError.noVideos }
            endSlowMotion()
            player.pause()
            directory = url
            athletes = scannedAthletes
            remoteIndex = nil
            remoteProvider = nil
            clipCache = nil
            materialisedByFileID = [:]
            isUsingRemoteLibrary = false
            activeAthleteID = nil
            selectedAthleteID = scannedAthletes[0].id
            zoom.reset()
            selectAthlete(scannedAthletes[0].id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func selectAthlete(_ id: String?) {
        guard let id,
              id != activeAthleteID,
              athletes.contains(where: { $0.id == id })
        else {
            return
        }
        endSlowMotion()
        activeAthleteID = id
        selectedAthleteID = id
        videoIndex = 0
        loadCurrentVideo()
    }

    @discardableResult
    public func changeVideo(by offset: Int) -> Bool {
        guard let athlete = currentAthlete, !athlete.videos.isEmpty else {
            return false
        }
        endSlowMotion()
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

    public func selectFirstMatchingAthlete() {
        guard let athlete = filteredAthletes.first else { return }
        selectAthlete(athlete.id)
    }

    public func togglePlayback() {
        guard currentVideo != nil else { return }
        endSlowMotion()
        if player.rate == 0 {
            rewindIfAtEnd()
            player.playImmediately(atRate: 1)
            status = "Playing"
        } else {
            player.pause()
            status = "Paused"
        }
    }

    /// The viewer's six transport actions, in one entry point mirroring
    /// `ComparisonModel.applyTransport`. One shape across both screens means
    /// one shared `TransportControls` view can drive either.
    public func applyTransport(_ action: TransportAction) {
        // Any in-flight slow-motion hold ends first. Without this the hold's
        // state survives the press — `SlowMotionHold.isActive` stays true, and
        // its `begin` refuses every later hold.
        endSlowMotion()
        switch action {
        case .back5: seek(seconds: -5)
        case .back1: seek(seconds: -1)
        case .forward1: seek(seconds: 1)
        case .forward5: seek(seconds: 5)
        case .playPause:
            // `togglePlayback` ends the hold itself, so the `endSlowMotion`
            // above is a no-op by the time this branch runs. Kept there anyway:
            // it is what makes the *seeking* actions cancel a hold, and this
            // button behaving the same as the Space key — which reaches
            // `togglePlayback` directly via `handle(.togglePlayback)` — is the
            // point. Play/Pause exits a hold rather than steering it.
            togglePlayback()
        case .slow:
            guard currentVideo != nil else { return }
            // The same dead end as `togglePlayback`, by a different door: this
            // branch has no toggle in front of it, so it never even asks
            // whether the player is stopped — it just calls `playImmediately`,
            // which at the end of a clip does nothing.
            rewindIfAtEnd()
            player.playImmediately(atRate: 0.25)
            status = "Quarter speed"
        }
    }

    /// Back to the first frame when play is asked for at the end of the clip.
    ///
    /// Called from both places that start the viewer from a stopped state, and
    /// deliberately not from `seek`/`scrub`: this is "play means play", not a
    /// bound. See `AVPlayer.isAtEndOfClip` for the measurements behind the
    /// tolerance, and for why no completion handler is needed here — the
    /// `playImmediately` that follows in the same turn starts correctly against
    /// an un-awaited seek.
    ///
    /// `currentTime` is written straight away rather than left to the periodic
    /// observer, which runs at 0.1s and would otherwise leave the scrubber thumb
    /// sitting at the end for a visible moment after the picture restarted.
    /// `scrub(to:)` writes it for the same reason.
    private func rewindIfAtEnd() {
        guard player.isAtEndOfClip else { return }
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = 0
    }

    /// Absolute seek, for the scrubber. `cancelPendingSeeks` first so a drag
    /// coalesces instead of queueing one seek per pixel.
    public func scrub(to seconds: Double) {
        guard player.currentItem != nil else { return }
        endSlowMotion()
        player.currentItem?.cancelPendingSeeks()
        var target = max(0, seconds)
        if duration > 0 { target = min(target, duration) }
        currentTime = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    // MARK: - Zoom

    /// `paneSize` is the video pane's own size, which only a view can know —
    /// it comes from `ViewerPane`'s `GeometryReader`. `videoSize` is *not* a
    /// parameter: `VideoZoom` needs the clip's dimensions to clamp the pan, and
    /// this class holds the player, so a view passing them would have to reach
    /// through the model to the player for a value the model already has.
    ///
    /// Out-of-range scales arrive here routinely — `ZoomControl`'s step buttons
    /// offer `scale ± 0.5` without checking the bounds — and are correct to
    /// pass on: `VideoZoom.setScale` clamps to `VideoZoom.range` unconditionally,
    /// so the range is enforced in exactly one place.
    public func setZoomScale(_ scale: Double, in paneSize: CGSize) {
        zoom.setScale(scale, in: paneSize, videoSize: videoSize)
    }

    public func panZoom(by translation: CGSize, in paneSize: CGSize) {
        zoom.pan(by: translation, in: paneSize, videoSize: videoSize)
    }

    public func resetZoom() {
        zoom.reset()
    }

    /// The current clip's own dimensions, or `.zero` before its tracks have
    /// loaded — which is the value `VideoZoom` documents as "no aspect to fit
    /// yet" and falls back to the pane's rect for. Read fresh on every call
    /// rather than cached, for the same reason `SinglePlayerView`'s layer host
    /// re-reads it: it arrives late, and it changes on every clip.
    ///
    /// **The pre-load window is benign, traced rather than assumed.** While
    /// this reads `.zero`, `VideoZoom`'s `fitted` falls back to the pane, so a
    /// clamp computed here uses **the pane's aspect, not the clip's** — and a
    /// stored `center` can therefore sit briefly outside the interval that is
    /// legal once the clip's real aspect is known. Nothing draws wrong in the
    /// meantime, because `layerFrame` re-clamps its own rendering copy against
    /// the real geometry on every pass, and nothing jumps afterwards, because
    /// the next `pan` clamps to the position already on screen. It self-heals
    /// invisibly; there is no correction to make here.
    private var videoSize: CGSize {
        player.currentItem?.presentationSize ?? .zero
    }

    /// The single teardown. Every library change and every transport action
    /// routes here, because a hold left running into a clip it was not started
    /// on is the defect this replaces.
    private func endSlowMotion() {
        guard hold.isActive else { return }
        hold.end()
        status = player.rate == 0 ? "Paused" : "Playing"
    }

    /// 0.1s matches the comparison screen's interval: fast enough that the
    /// scrubber thumb tracks playback without visible stepping, slow enough not
    /// to publish on every frame.
    private func startObservingTime() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
            }
        }
    }

    /// `rate`, not `timeControlStatus`. Both are KVO-observable, and
    /// `timeControlStatus` is the more informative of the two — which is exactly
    /// the problem here. It reports `.waitingToPlayAtSpecifiedRate` while the
    /// rate is still 0, so a stalled Google Drive stream would publish
    /// `isPlaying == true` with the picture frozen, and the operator's focus
    /// would be taken away for playback that never started. `rate != 0` is also
    /// the same predicate the model already branches on in `togglePlayback` and
    /// `endSlowMotion`, so the published flag cannot disagree with the decisions
    /// made from it. Reverse playback (`atRate: -0.35`) counts as playing, as it
    /// should; the reverse *fallback*, which pauses the player and steps it with
    /// a timer, does not — the player really is stopped there.
    ///
    /// The current rate is read inside the hop rather than taken from the change
    /// dictionary: `Task { @MainActor }` gives no ordering guarantee between two
    /// notifications, so a captured value could settle stale, whereas re-reading
    /// makes every hop converge on the player's present state. `observeDuration`
    /// re-reads for the same reason.
    private func startObservingRate() {
        rateObserver = player.observe(\.rate, options: [.initial, .new]) { player, _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = player.rate != 0
            }
        }
    }

    /// The periodic observer cannot carry duration: it does not fire while
    /// paused, and a freshly loaded clip is paused. `ComparisonModel` learned
    /// the same thing — the duration arrives asynchronously, after the item
    /// does.
    private func observeDuration(of item: AVPlayerItem) {
        durationObserver = item.observe(\.duration, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item else { return }
                let seconds = item.duration.seconds
                guard seconds.isFinite, seconds > 0 else { return }
                self.duration = seconds
            }
        }
    }

    /// Loads whatever `currentPlaybackURL` resolves to. For a local library
    /// that is always the current clip's own file; for a cloud library it is
    /// nil until `prepareCurrentClip` lands the bytes, and calling this again
    /// once it has is what puts the downloaded clip on screen.
    private func loadCurrentVideo() {
        guard currentVideo != nil else { return }
        // Reset before observing: the previous clip's figures would otherwise
        // drive the scrubber until the new duration arrives, which for a remote
        // Drive item can be a visible moment. Also correct for the "not yet
        // on disk" branch below, which has no clip to report a duration for.
        currentTime = 0
        duration = 0
        guard let playbackURL = currentPlaybackURL else {
            // Cloud clip not yet on disk. Nothing to show until the fetch
            // completes and calls back in here.
            player.replaceCurrentItem(with: nil)
            status = "Paused"
            return
        }
        let item = AVPlayerItem(url: playbackURL)
        player.replaceCurrentItem(with: item)
        observeDuration(of: item)
        player.pause()
        status = "Paused"
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

    private func normalizedName(_ name: String) -> String {
        name.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }
}
