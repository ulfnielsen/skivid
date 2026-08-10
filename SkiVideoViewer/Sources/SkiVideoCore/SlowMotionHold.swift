import AVFoundation

/// One direction of held slow playback over a set of players.
///
/// Internal, and deliberately ignorant of both models: it takes the players as
/// an argument to `begin` rather than holding a reference, so the comparison
/// window can hand it one side, the other, or the locked pair from a single
/// call site. It sets no status strings either — the two models word theirs
/// differently, and a shared unit that owned the wording would have to know
/// which model it was serving.
///
/// This is `ViewerModel`'s former arrow-hold machinery, lifted so
/// `ComparisonModel` can have the same behaviour rather than a second, subtly
/// different copy of it.
@MainActor
final class SlowMotionHold {
    /// Matches the rate the viewer's long-press has always used.
    static let rate: Float = 0.35

    /// Both the timer period and the distance stepped, so the fallback moves at
    /// roughly 1× in reverse — which is what makes it read as playback rather
    /// than as a series of jumps.
    private static let stepInterval: TimeInterval = 0.08

    /// The lead a paired start is scheduled with, and the delay after which the
    /// schedule is checked. Both are `ComparisonModel.playSynced`'s numbers,
    /// deliberately — this is that mechanism, reused rather than reinvented, and
    /// two screens starting a locked pair on two different leads would be a
    /// difference nobody could justify.
    private static let pairedStartLead: TimeInterval = 0.12
    private static let pairedStartCheck: TimeInterval = 0.35

    /// Bumped by every start and by `end()`, so a scheduled start's recovery
    /// closure can tell whether it is still the current one. Without it a
    /// recovery armed by a hold that has since ended would restart the players
    /// 0.35s after the operator released the key. Same device, same reason, as
    /// `ComparisonModel.playbackGeneration`.
    private var startGeneration = 0

    private var players: [AVPlayer] = []
    private var ratesBeforeHold: [Float] = []
    /// Readable inside the module so a test can hold the timer itself and ask
    /// whether it survived the hold — after `deinit` there is no other way to
    /// reach it, and "did this leak a firing timer" is exactly the question.
    /// Writable only here.
    private(set) var reverseTimer: Timer?

    /// The last target the reverse fallback asked for. Exposed so a test can
    /// prove the timer fired without racing a real seek's completion, and nil
    /// until the fallback path runs at least once.
    private(set) var lastFallbackTarget: Double?

    var isActive: Bool { !players.isEmpty }

    /// A second `begin` while a hold is active is ignored. Auto-repeat delivers
    /// several key-downs for one physical press, and overwriting
    /// `ratesBeforeHold` with the slow rate would make `end()` restore 0.35×
    /// instead of the rate the operator was watching at. An empty set is
    /// refused for the plainer reason that there is nothing to drive.
    ///
    /// - Returns: whether a hold actually started. Both models write a status
    ///   line for the hold, and a status written after a refusal describes a
    ///   hold that is not running — the cross-direction press (⌘→ held, then ⌘←)
    ///   announcing "Slow backward" over clips still running forward. They used
    ///   to re-derive the refusal themselves, from a *different* pair of
    ///   conditions each, and the copies drifted: the comparison window tested
    ///   only `isActive` and so announced a hold over an empty window. The rule
    ///   now lives here, where the refusal happens, and reaches the callers as
    ///   this value.
    ///
    /// Deliberately **not** `@discardableResult`. Ignoring this is exactly the
    /// mistake that produced the drift, so a caller that forgets to check must
    /// get a compiler warning; `_ =` at the call sites that genuinely do not
    /// care (the unit tests) is the cost, and it is the cheaper half.
    func begin(_ direction: ScrubDirection, players: [AVPlayer]) -> Bool {
        guard !isActive, !players.isEmpty else { return false }
        self.players = players
        ratesBeforeHold = players.map(\.rate)

        switch direction {
        case .forward:
            start(players, atRate: Self.rate, recoverIfRefused: true)
        case .backward:
            // All-or-nothing. A synced pair with one side running natively in
            // reverse and the other stepping on a timer would drift apart,
            // which is the one thing the comparison window exists to prevent.
            let everyItemCanReverse = players.allSatisfy {
                $0.currentItem?.canPlayReverse == true
            }
            if everyItemCanReverse {
                start(players, atRate: -Self.rate, recoverIfRefused: true)
            } else {
                for player in players {
                    player.pause()
                }
                // Already paired, and nothing to do about it here: one timer
                // callback steps every player in the set, from one reading of
                // the clock, so the set cannot come apart the way two
                // independent `playImmediately` calls could. See `stepBack`.
                let timer = Timer(timeInterval: Self.stepInterval, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.stepBack()
                    }
                }
                reverseTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        return true
    }

    /// Idempotent: the key-up is not the only caller. App-resign, window close
    /// and every library change call this too, and a hold may well not be
    /// running when they do.
    ///
    /// The restore is paired for the same reason the start is: putting a locked
    /// pair back at 1× with two independent calls is the same skew, arriving on
    /// the way out instead of the way in.
    func end() {
        guard isActive else { return }
        reverseTimer?.invalidate()
        reverseTimer = nil
        let held = players
        let rates = ratesBeforeHold
        players = []
        ratesBeforeHold = []
        // Also cancels any start recovery still pending from `begin`: it is
        // guarded on this counter, and the hold it belonged to is over.
        startGeneration += 1

        for player in held {
            player.pause()
        }
        // One common rate is what a locked pair has — both sides were playing
        // at 1×, or both were stopped — and it is the only case a paired
        // restore is meaningful for. Mixed rates cannot be expressed as one
        // scheduled start, so each player gets its own, exactly as before.
        guard let resumed = rates.first, resumed != 0, rates.allSatisfy({ $0 == resumed }) else {
            for (player, rate) in zip(held, rates) where rate != 0 {
                player.playImmediately(atRate: rate)
            }
            return
        }
        // No recovery closure on this path, deliberately. A recovery armed here
        // would fire 0.35s after the release and could restart players that
        // something else — `ComparisonModel.close()`, `pauseBoth()` — paused in
        // between, which is the one thing a teardown must not do. The risk it
        // would cover is also much smaller here: these players were *already
        // playing* at this rate a moment ago, so their timebases are warm,
        // which is precisely the condition `playSynced`'s recovery exists for
        // the absence of.
        start(held, atRate: resumed, recoverIfRefused: false)
    }

    /// Starts a set of players, in lockstep when there is more than one.
    ///
    /// `AVPlayer.playImmediately(atRate:)` per player is what this used to do
    /// throughout, and it is still right for one player. For two it is not:
    /// each call starts that player when its own decoder is ready, and
    /// `ComparisonModel.playSynced` exists because that skew is visible — it
    /// starts a locked pair with `setRate(_:time:atHostTime:)` against
    /// `CMClockGetHostTimeClock()` on a shared lead for exactly this reason.
    /// A pair that drifts during a hold is a defect in the window whose whole
    /// job is alignment, so the hold borrows that mechanism rather than a
    /// weaker one.
    ///
    /// **The two gates are not optional.** `setRate(_:time:atHostTime:)` raises
    /// `NSInvalidArgumentException`, which Swift cannot catch, on either of two
    /// conditions — both measured here, not assumed, each having taken the test
    /// process down once:
    ///
    /// - "cannot service a synchronized playback request … until its status is
    ///   AVPlayerStatusReadyToPlay", raised by a probe against a zero-byte item.
    /// - "… when automaticallyWaitsToMinimizeStalling is YES", raised by
    ///   `testForwardDrivesEveryPlayerItIsGiven`'s two real players. That flag
    ///   is on by default; `ComparisonModel.init` turns it off for both of its
    ///   players, which is what makes `playSynced` — and this — legal there.
    ///
    /// A set that fails either gate starts immediately, which is what every set
    /// did before this existed. The flag is *read*, never written: a shared unit
    /// that quietly reconfigured a caller's player would change stalling
    /// behaviour on a screen that never asked for paired starts.
    ///
    /// - Parameter recoverIfRefused: schedules the immediate-start recovery
    ///   `playSynced` carries, for decoders that accept the request but never
    ///   act on it. Only `begin` passes `true`, and the closure deliberately
    ///   re-reads `self.players` rather than capturing the set, so it can only
    ///   ever restart the hold that is still running.
    private func start(_ players: [AVPlayer], atRate rate: Float, recoverIfRefused: Bool) {
        startGeneration += 1
        let requested = startGeneration
        guard players.count > 1,
              players.allSatisfy({
                  $0.currentItem?.status == .readyToPlay
                      && !$0.automaticallyWaitsToMinimizeStalling
              })
        else {
            for player in players {
                player.playImmediately(atRate: rate)
            }
            return
        }

        let clock = CMClockGetHostTimeClock()
        let startTime = CMClockGetTime(clock)
            + CMTime(seconds: Self.pairedStartLead, preferredTimescale: 600)
        for player in players {
            player.setRate(rate, time: player.currentTime(), atHostTime: startTime)
        }

        guard recoverIfRefused else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pairedStartCheck) { [weak self] in
            guard let self,
                  self.startGeneration == requested,
                  self.isActive,
                  self.players.contains(where: { $0.rate == 0 })
            else { return }
            for player in self.players {
                player.playImmediately(atRate: rate)
            }
        }
    }

    /// The last line of defence for the reverse fallback's timer. `end()` is
    /// what normally invalidates it, and every teardown path calls that — but
    /// the run loop, not this object, owns the scheduled timer, so a hold
    /// released while the fallback is running would leave it firing every 80ms
    /// for the rest of the session. The `[weak self]` in the block means those
    /// firings do nothing, which is precisely why the leak would be silent.
    ///
    /// The players are deliberately *not* restored here: `deinit` has no
    /// guarantee of running at a point where changing playback would make
    /// sense, and the owning model has already torn its playback down by then.
    ///
    /// `Timer.invalidate()` must be called on the thread that scheduled the
    /// timer — the main one here — and `deinit` is nonisolated, so this rests
    /// on both owners (`ViewerModel`, `ComparisonModel`) being `@MainActor`
    /// types released from the main actor, which is true of every path today.
    /// It is a property of the callers, not a guarantee the language gives.
    /// Hopping to the main actor instead would mean sending a non-`Sendable`
    /// `Timer` across, which trades a sound assumption for an unsound one.
    deinit {
        reverseTimer?.invalidate()
    }

    private func stepBack() {
        for player in players {
            let current = player.currentTime().seconds
            let safeCurrent = current.isFinite ? current : 0
            let target = max(0, safeCurrent - Self.stepInterval)
            lastFallbackTarget = target
            player.seek(
                to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
    }
}
