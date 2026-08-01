import AVFoundation
import Foundation
import UniformTypeIdentifiers

public enum ComparisonSide {
    case left
    case right
}

public enum ComparisonLayout: String, CaseIterable, Identifiable {
    case sideBySide
    case overlay

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sideBySide: return "Side-by-side"
        case .overlay: return "Overlay"
        }
    }
}

public enum OverlayBlend: String, CaseIterable, Identifiable {
    case blend
    case difference

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .blend: return "Blend"
        case .difference: return "Difference"
        }
    }
}

/// Who the transport controls act on.
///
/// `both` is only meaningful once sync points are set — `playSynced` and
/// `seekSynced` both refuse otherwise — so `availableTargets` omits it while
/// aligning rather than offering a control that can only produce a nag.
public enum ComparisonTarget: String, CaseIterable, Identifiable, Sendable {
    case both, left, right

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .both: return "Both"
        case .left: return "Left"
        case .right: return "Right"
        }
    }

    /// The single side this target names, or `nil` for `both`. Internal: it
    /// exists so `ComparisonModel` can record which side a selection expressed
    /// a preference for, which is nobody else's business.
    var side: ComparisonSide? {
        switch self {
        case .both: return nil
        case .left: return .left
        case .right: return .right
        }
    }
}

/// One transport action, routed by `ComparisonModel.target`.
///
/// `CaseIterable` in declaration order, which is left-to-right button order:
/// the control bar renders it with a `ForEach` rather than restating the list.
public enum TransportAction: String, CaseIterable, Identifiable, Sendable {
    case back5, back1, playPause, forward1, forward5, slow

    public var id: String { rawValue }
}

/// Platform-agnostic state for the two-video comparison window. Like
/// `ViewerModel`, everything platform-specific reaches it through the seams in
/// `Seams.swift`, so an iPadOS target can present the same model.
///
/// Access levels are deliberately narrow: `public` marks exactly what the app
/// target's `ComparisonView`, `OverlayPlayerStack` and `ComparisonWindowController`
/// touch. Members used only by this module or by tests stay internal.
@MainActor
public final class ComparisonModel: ObservableObject {
    @Published public private(set) var leftName = "Choose left video"
    @Published public private(set) var rightName = "Choose right video"
    @Published public private(set) var leftTime = 0.0
    @Published public private(set) var rightTime = 0.0
    @Published public private(set) var leftDuration = 0.0
    @Published public private(set) var rightDuration = 0.0
    @Published public private(set) var isSynced = false
    @Published public private(set) var status = "Choose two videos and align them independently."
    @Published public var layout: ComparisonLayout = .sideBySide
    @Published public var overlayOpacity: Double = 0.5
    @Published public var blend: OverlayBlend = .blend
    /// Writable so a `Picker` can bind to it, but self-correcting: a caller
    /// that selects `both` while aligning would otherwise leave a selection
    /// `availableTargets` does not contain, which SwiftUI renders as no
    /// selection at all. Assigning from inside `didSet` does not re-enter it.
    ///
    /// Selecting a side is itself an expression of preference — arguably the
    /// clearest one there is — so it records the last-touched side too.
    /// Without that, picking `Right`, syncing, and clearing sync dropped the
    /// user back on `Left`, because nothing between those three steps had
    /// called a per-side method.
    @Published public var target: ComparisonTarget = .left {
        didSet {
            guard availableTargets.contains(target) else {
                target = lastTouchedTarget
                return
            }
            if let side = target.side { lastTouchedSide = side }
        }
    }

    public let leftPlayer = AVPlayer()
    public let rightPlayer = AVPlayer()
    public let openLibrary: [ComparisonAthleteChoice]

    /// Where `target` lands when `both` stops being available. Snapping back to
    /// Left after the user drops a clip into the right pane reads as a bug, so
    /// the demotion follows whichever side was last acted on.
    ///
    /// Written by `noteTouched(_:)` from every per-side entry point, by `load`,
    /// and by `target`'s own `didSet`. It used to be written only in
    /// `applyTransport` and `load`, which left every other route stale — the
    /// measured symptom was that aligning the right clip by dragging the
    /// scrubber (the only route to an absolute seek, since `TransportAction`
    /// has no such case), then syncing and clearing sync, landed on Left.
    private var lastTouchedSide: ComparisonSide = .left

    private var lastTouchedTarget: ComparisonTarget {
        lastTouchedSide == .left ? .left : .right
    }

    /// Records a *side-directed* call. Every per-side method funnels through
    /// this rather than assigning `lastTouchedSide` itself, so the rule lives
    /// in one place.
    ///
    /// The guard is the whole point. `lastTouchedSide` answers exactly one
    /// question — which side a `both` demotion should land on — so it must
    /// only follow calls that express a preference for a side. A per-side call
    /// made while the bar targets `both` does not: the scrubber shows the
    /// common timeline there and drags it through `scrub(.left, to:)` because
    /// there is no paired overload, so without the guard, dragging the common
    /// timeline would silently reassign the landing side to Left and
    /// reintroduce the very bug this fixes for a user who had chosen Right.
    /// `applyTransport` has always behaved this way — its `both` branch never
    /// writes it — and this makes the direct entry points agree.
    ///
    /// `load(_:side:)` deliberately does *not* use this: dropping a clip into
    /// a pane names that side whatever the target is, and it has to be
    /// recorded before `clearSync` demotes off `both`.
    private func noteTouched(_ side: ComparisonSide) {
        guard target != .both else { return }
        lastTouchedSide = side
    }

    /// Readable inside the module so the tests can prove a nudge moves a sync
    /// point — with undecodable fixtures the published `leftTime`/`rightTime`
    /// never update, so these are the only durable evidence. Writable only
    /// here: the pair is an invariant (`L_cur - L_sync == R_cur - R_sync` while
    /// locked), and nothing outside these methods may set one without the
    /// other.
    private(set) var leftSyncPoint = CMTime.zero
    private(set) var rightSyncPoint = CMTime.zero
    private var leftTimeObserver: Any?
    private var rightTimeObserver: Any?
    private var leftDurationObserver: NSKeyValueObservation?
    private var rightDurationObserver: NSKeyValueObservation?
    private var playbackGeneration = 0

    /// Optional because a unit-test model needs neither. A comparison window
    /// without an input source simply has no keyboard control, and one without
    /// a folder picker cannot open the "Choose File…" panel.
    private let input: PlaybackInputSource?
    private let folderPicker: FolderPicker?

    public init(
        initialLeftVideo: URL? = nil,
        openLibrary: [ComparisonAthleteChoice] = [],
        input: PlaybackInputSource? = nil,
        folderPicker: FolderPicker? = nil
    ) {
        self.openLibrary = openLibrary
        self.input = input
        self.folderPicker = folderPicker
        leftPlayer.automaticallyWaitsToMinimizeStalling = false
        rightPlayer.automaticallyWaitsToMinimizeStalling = false
        installTimeObservers()
        input?.onIntent = { [weak self] intent in
            self?.handle(intent)
        }
        if let initialLeftVideo {
            load(initialLeftVideo, side: .left)
        }
    }

    public var hasTwoVideos: Bool {
        leftPlayer.currentItem != nil && rightPlayer.currentItem != nil
    }

    /// Difference blending only reads correctly at full opacity, so the slider
    /// is ignored (and disabled in the UI) while difference mode is active.
    public var topLayerOpacity: Double {
        blend == .difference ? 1.0 : overlayOpacity
    }

    public var availableTargets: [ComparisonTarget] {
        isSynced ? [.both, .left, .right] : [.left, .right]
    }

    /// One transport action, routed to the synced pair or to a single side by
    /// `target`. The per-side methods already fall through to their synced
    /// equivalents when `isSynced`, so this only has to pick the entry point.
    public func applyTransport(_ action: TransportAction) {
        switch target {
        case .both:
            switch action {
            case .back5: seekSynced(by: -5)
            case .back1: seekSynced(by: -1)
            case .forward1: seekSynced(by: 1)
            case .forward5: seekSynced(by: 5)
            case .playPause:
                if leftPlayer.rate == 0 && rightPlayer.rate == 0 {
                    playSynced()
                } else {
                    pauseBoth()
                }
            case .slow: playSynced(rate: 0.25)
            }
        case .left, .right:
            // No `noteTouched` here any more. Every branch below reaches a
            // per-side method that records the side itself, so a call here was
            // redundant — mutation-verified: deleting it changed no test.
            // Keeping it would have meant the rule lived in two layers, which
            // is how it came to be missing from one of them in the first place.
            let side: ComparisonSide = target == .left ? .left : .right
            switch action {
            // Seeks become nudges once synced: they correct this clip against
            // the other instead of moving the locked pair. `nudge` falls back
            // to a plain per-side seek while aligning.
            case .back5: nudge(side, by: -5)
            case .back1: nudge(side, by: -1)
            case .forward1: nudge(side, by: 1)
            case .forward5: nudge(side, by: 5)
            // Playback deliberately stays paired while synced — running one
            // clip alone would desync exactly what the user just aligned. Both
            // of these already delegate to the pair when `isSynced`, so they
            // ignore the side without having to test for it.
            case .playPause: toggleIndividual(side)
            case .slow: playIndividual(side, rate: 0.25)
            }
        }
    }

    /// Internal: the model subscribes itself to `input.onIntent`, so nothing
    /// outside the module drives it directly.
    ///
    /// The comparison window's `NSEvent` monitor bound exactly three keys —
    /// Space, Left and Right — and acted on key-down only. Acting on
    /// `.scrubBegan` and ignoring `.scrubEnded` reproduces that: it never had
    /// hold-to-scrub. The remaining intents were passed through to the app by
    /// the old monitor and stay unhandled here.
    ///
    /// Routed through `applyTransport` so the keys and the on-screen buttons
    /// cannot disagree. They used to: these called `playSynced`/`seekSynced`
    /// directly, so while aligning with Left targeted the ▶ button played the
    /// left clip while Space only answered "Set the sync points first."
    func handle(_ intent: PlaybackIntent) {
        switch intent {
        case .togglePlayback:
            applyTransport(.playPause)
        case .scrubBegan(.backward):
            applyTransport(.back1)
        case .scrubBegan(.forward):
            applyTransport(.forward1)
        default:
            break
        }
    }

    public func chooseVideo(side: ComparisonSide) async {
        guard let folderPicker else { return }
        let title = side == .left
            ? "Choose left comparison video"
            : "Choose right comparison video"
        guard let url = await folderPicker.pickFile(ofType: .movie, title: title) else { return }
        load(url, side: side)
    }

    func load(_ url: URL, side: ComparisonSide) {
        let player = player(for: side)
        // Not `noteTouched`: dropping a clip into a pane names that side
        // whatever the target is, and it must be recorded before `clearSync`
        // below demotes off `both`.
        lastTouchedSide = side
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

    public func load(_ choice: ComparisonVideoChoice, side: ComparisonSide) {
        load(choice.playbackURL, side: side)
        switch side {
        case .left:
            leftName = choice.name
        case .right:
            rightName = choice.name
        }
    }

    public func toggleIndividual(_ side: ComparisonSide) {
        noteTouched(side)
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

    public func playIndividual(_ side: ComparisonSide, rate: Float) {
        noteTouched(side)
        if isSynced {
            playSynced(rate: rate)
            return
        }
        let player = player(for: side)
        player.playImmediately(atRate: rate)
        status = "Playing \(side == .left ? "left" : "right") at \(String(format: "%.2g", rate))×"
    }

    /// A per-side correction that survives the pair being locked: it moves one
    /// clip *relative to* the other. The clip's sync point moves with it by the
    /// same amount, so three things stay true — the pair remains locked, at the
    /// corrected offset; `scrub` (which derives its offset from the two sync
    /// points) follows the correction; and `returnToSyncPoints()` comes back to
    /// the corrected alignment rather than the one being corrected.
    ///
    /// The sync point shifts by the distance actually travelled, not the
    /// distance asked for, so a nudge clamped at 0 or at the end of the clip
    /// cannot drift the sync point away from the frame it names.
    ///
    /// The clip stays in bounds; the sync point it carries need not, because it
    /// starts wherever the user set it. `normalizeSyncPoints()` slides the pair
    /// back into range afterwards — see it for why that is safe and why the
    /// alternative is a silent misalignment.
    ///
    /// While aligning there is nothing to correct against, so this degrades to
    /// an ordinary per-side seek.
    public func nudge(_ side: ComparisonSide, by seconds: Double) {
        noteTouched(side)
        guard isSynced else {
            seek(side, by: seconds)
            return
        }
        pauseBoth()
        let clip = player(for: side)
        let currentSeconds = clip.currentTime().seconds
        let from = currentSeconds.isFinite ? currentSeconds : 0
        let travelled = clampedSeekTarget(for: clip, to: from + seconds) - from
        seek(clip, to: from + seconds)
        let shift = CMTime(seconds: travelled, preferredTimescale: 600)
        switch side {
        case .left: leftSyncPoint = leftSyncPoint + shift
        case .right: rightSyncPoint = rightSyncPoint + shift
        }
        // The clip stayed inside its own bounds; the *sync point* need not
        // have. Slide the pair back into range before anything reads it.
        normalizeSyncPoints()
        status = "\(side == .left ? "Left" : "Right") nudged \(seconds >= 0 ? "+" : "")\(Int(seconds)) seconds"
    }

    public func seek(_ side: ComparisonSide, by seconds: Double) {
        noteTouched(side)
        if isSynced {
            seekSynced(by: seconds)
            return
        }
        clearSync(message: "Alignment changed. Set sync points again when ready.")
        seek(player(for: side), to: currentTime(for: side) + seconds)
    }

    func seek(_ side: ComparisonSide, to seconds: Double) {
        noteTouched(side)
        if isSynced {
            seekSynced(by: seconds - currentTime(for: side))
            return
        }
        clearSync(message: "Alignment changed. Set sync points again when ready.")
        seek(player(for: side), to: seconds)
    }

    public func scrub(_ side: ComparisonSide, to seconds: Double) {
        noteTouched(side)
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

    public func setSyncPoints() {
        guard hasTwoVideos else {
            status = "Choose both videos before setting sync points."
            return
        }
        pauseBoth()
        leftSyncPoint = leftPlayer.currentTime()
        rightSyncPoint = rightPlayer.currentTime()
        isSynced = true
        target = .both
        status = "Synchronized from L \(Timecode.string(leftTime)) and R \(Timecode.string(rightTime))."
    }

    public func removeSync() {
        pauseBoth()
        isSynced = false
        if target == .both { target = lastTouchedTarget }
        status = "Independent controls restored. Align the videos and set new sync points when ready."
    }

    public func playSynced(rate: Float = 1) {
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

    public func pauseBoth() {
        playbackGeneration += 1
        leftPlayer.pause()
        rightPlayer.pause()
        if isSynced {
            status = "Paused together"
        }
    }

    public func seekSynced(by seconds: Double) {
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

    public func returnToSyncPoints() {
        guard isSynced else { return }
        pauseBoth()
        // Again here, not only in `nudge`: a clip's duration arrives
        // asynchronously, so a nudge made before the item finished loading
        // cannot know its upper bound yet. Without this the two seeks below
        // clamp *independently* and the pair lands at the wrong offset while
        // `isSynced` still reads true and the status says it returned.
        normalizeSyncPoints()
        leftPlayer.seek(to: leftSyncPoint, toleranceBefore: .zero, toleranceAfter: .zero)
        rightPlayer.seek(to: rightSyncPoint, toleranceBefore: .zero, toleranceAfter: .zero)
        status = "Returned to the sync points"
    }

    public func close() {
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
        // Stands in for the `NSEvent.removeMonitor` this used to do: the source
        // must stop both delivering *and* swallowing key events, so they reach
        // the main window's input source again.
        input?.onIntent = nil
        input?.setEnabled(false)
    }

    private func player(for side: ComparisonSide) -> AVPlayer {
        side == .left ? leftPlayer : rightPlayer
    }

    private func currentTime(for side: ComparisonSide) -> Double {
        side == .left ? leftTime : rightTime
    }

    /// Extracted so `nudge` can ask where a seek would land without performing
    /// it — it has to shift the sync point by the distance actually travelled.
    private func clampedSeekTarget(for player: AVPlayer, to seconds: Double) -> Double {
        min(max(0, seconds.isFinite ? seconds : 0), lastSeekableSecond(of: player))
    }

    /// The furthest second a seek on this player can reach. A duration that is
    /// not known yet reads back as NaN — every player before its item finishes
    /// loading, and every undecodable fixture — and contributes *no* upper
    /// bound rather than a zero-length clip.
    private func lastSeekableSecond(of player: AVPlayer) -> Double {
        let duration = player.currentItem?.duration.seconds ?? .nan
        return duration.isFinite ? duration : .infinity
    }

    /// Slides both sync points by one common delta until they are inside their
    /// clips. **Only the difference between them carries meaning** — it is the
    /// offset the locked pair keeps — so a common slide is free, and it is the
    /// only correction available that cannot change the alignment.
    ///
    /// This exists because `nudge` moves one sync point by the distance its
    /// clip travelled, and repeated nudges accumulate: four `back5` corrections
    /// push a sync point 20s below zero wherever it started. `AVPlayer.seek`
    /// then clamps each side *independently* in `returnToSyncPoints()`, which
    /// destroys the offset between them and lands the pair seconds apart —
    /// silently, with `isSynced` still true. Measured on generated H.264 before
    /// this existed: sync points 2.0/2.0, pair at 8.0, one `back5` on the left,
    /// return landed 0.0/2.0 — 3.0s out of alignment, in a screen whose entire
    /// job is alignment.
    ///
    /// Both bounds are handled. Below zero is what a run of `back5` reaches;
    /// past the duration is the exactly symmetric case for `forward5`, and just
    /// as reachable.
    ///
    /// When the clips are too short to hold the offset at all — every delta
    /// leaves one end out of range — the lower bound wins: a negative time
    /// names no frame at all, while a time past the end at least clamps to the
    /// last one.
    private func normalizeSyncPoints() {
        let left = leftSyncPoint.seconds
        let right = rightSyncPoint.seconds
        guard left.isFinite, right.isFinite else { return }
        let lowest = max(-left, -right)
        let highest = min(lastSeekableSecond(of: leftPlayer) - left, lastSeekableSecond(of: rightPlayer) - right)
        let delta = max(lowest, min(0, highest))
        guard delta != 0, delta.isFinite else { return }
        let shift = CMTime(seconds: delta, preferredTimescale: 600)
        leftSyncPoint = leftSyncPoint + shift
        rightSyncPoint = rightSyncPoint + shift
    }

    private func seek(_ player: AVPlayer, to seconds: Double) {
        let clamped = clampedSeekTarget(for: player, to: seconds)
        player.currentItem?.cancelPendingSeeks()
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    /// The other way sync drops, and `removeSync()` is not the only path — so
    /// the `both` demotion has to live here too, or `target` keeps a value
    /// `availableTargets` no longer offers and the picker shows a selection
    /// that is not there.
    ///
    /// Loading a clip is the only route that reaches here *while* `target` is
    /// `both`: the per-side callers (`seek`, `toggleIndividual`) all delegate
    /// to their synced equivalents and return before getting this far whenever
    /// `isSynced`. The guard stays anyway — it is the invariant, not the
    /// current call graph, that must hold.
    private func clearSync(message: String) {
        if isSynced {
            pauseBoth()
        }
        isSynced = false
        if target == .both { target = lastTouchedTarget }
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
}
