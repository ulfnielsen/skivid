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
    /// instead of the rate the operator was watching at.
    func begin(_ direction: ScrubDirection, players: [AVPlayer]) {
        guard !isActive, !players.isEmpty else { return }
        self.players = players
        ratesBeforeHold = players.map(\.rate)

        switch direction {
        case .forward:
            for player in players {
                player.playImmediately(atRate: Self.rate)
            }
        case .backward:
            // All-or-nothing. A synced pair with one side running natively in
            // reverse and the other stepping on a timer would drift apart,
            // which is the one thing the comparison window exists to prevent.
            let everyItemCanReverse = players.allSatisfy {
                $0.currentItem?.canPlayReverse == true
            }
            if everyItemCanReverse {
                for player in players {
                    player.playImmediately(atRate: -Self.rate)
                }
            } else {
                for player in players {
                    player.pause()
                }
                let timer = Timer(timeInterval: Self.stepInterval, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.stepBack()
                    }
                }
                reverseTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }

    /// Idempotent: the key-up is not the only caller. App-resign, window close
    /// and every library change call this too, and a hold may well not be
    /// running when they do.
    func end() {
        guard isActive else { return }
        reverseTimer?.invalidate()
        reverseTimer = nil
        for (player, rate) in zip(players, ratesBeforeHold) {
            player.pause()
            if rate != 0 {
                player.playImmediately(atRate: rate)
            }
        }
        players = []
        ratesBeforeHold = []
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
