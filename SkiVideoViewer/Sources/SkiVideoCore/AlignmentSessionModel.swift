import CoreGraphics
import Foundation

/// The per-pair state of "how do these two clips line up spatially": loading
/// the sidecar, running the registration pass, and answering the renderer's
/// one question — what translation applies at this instant of the run.
///
/// Shaped after `SubjectSessionModel`, deliberately and down to the details: the
/// same idle / working / ready / failed states, the same injectable function so
/// every transition is reachable from a unit test without a real 15-second pass,
/// the same generation counter so a superseded run cannot overwrite the state of
/// the run that replaced it, and the same rule that in-memory state is updated
/// **before** persistence is attempted. A pass the operator has just waited out
/// must not be thrown away because the footage folder is read-only.
///
/// ## Why this owns a resolved copy of the gate's answers
///
/// `AlignmentGate.translation(in:at:)` is O(samples) per call and has to be: the
/// hysteretic state at an instant is the whole history of the overlap signal up
/// to it, so the gate walks the track from the beginning every time. That is
/// correct and must not change. It is also unusable from a renderer, which asks
/// the same question ten times a second against a 425-sample track — O(n²) per
/// second of playback, for an answer that cannot change between calls.
///
/// So the whole track is resolved **once**, when it is adopted, by asking the
/// real gate at every sample time; see `ResolvedAlignment`. Playback then does a
/// binary search and an interpolation. The cache is built from the gate rather
/// than reimplementing it, so the two cannot drift — that is the point of doing
/// it this way rather than lifting the gate's internals out.
@MainActor
public final class AlignmentSessionModel: ObservableObject {
    public enum State: Equatable {
        case idle
        case computing(progress: Double)
        case ready(AlignmentTrack)
        case failed(String)
    }

    /// The shape of `AlignmentAnalyzer.analyse`, minus the parameters this
    /// model never overrides. Injectable for the same reason
    /// `SubjectSessionModel.AnalyseFunction` is: the transitions below —
    /// success, cancel, known failure, unknown failure, and a second run
    /// superseding a first — are exactly the ones a frozen `.computing` state
    /// would hide, and none of them is reachable from a unit test through the
    /// real Vision registration pass.
    public typealias ComputeFunction = @Sendable (
        _ left: URL, _ right: URL,
        _ leftStart: TimeInterval, _ rightStart: TimeInterval,
        _ progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AlignmentTrack

    @Published public private(set) var state: State = .idle
    /// Whether the loaded track was computed against different run starts than
    /// the ones in force. Reported, never acted on — as with
    /// `ClipAnalysis.isStale`, the samples are kept — but unlike a stale
    /// subject pick it does disable alignment, because a track computed for
    /// other run starts describes a *different comparison* and applying it
    /// would move the wrong clip by the wrong amount at the wrong instant.
    @Published public private(set) var isStale = false
    /// A track that could be computed but not written. Surfaced once; the
    /// track is in memory and good for this session either way.
    @Published public private(set) var saveWarning: String?

    /// The operator's Align switch. Independent of whether a track exists —
    /// the UI disables the control instead of silently rewriting this — so
    /// turning alignment off and computing a new track does not turn it back
    /// on behind the operator's back.
    ///
    /// Defaults to on: computing a track is an explicit, expensive request,
    /// and having to then find a second control to see the result would be a
    /// step that exists only to be performed.
    @Published public var isAligned = true

    private let performAnalysis: ComputeFunction
    private var currentTask: Task<AlignmentTrack, Error>?
    /// Bumped on every `compute` call so a run superseded by a later one can
    /// tell, once its cancellation unwinds, that it is no longer the run of
    /// record and must not overwrite `state` with its own outcome.
    private var generation = 0
    private var resolved: ResolvedAlignment?

    public init(compute: @escaping ComputeFunction = { left, right, leftStart, rightStart, progress in
        try await AlignmentAnalyzer.analyse(
            left: left, right: right,
            leftStart: leftStart, rightStart: rightStart,
            progress: progress
        )
    }) {
        self.performAnalysis = compute
    }

    public var track: AlignmentTrack? {
        if case let .ready(track) = state { return track }
        return nil
    }

    /// Whether the Align switch may be used at all. A stale track counts as no
    /// track for this purpose; see `isStale`.
    public var canAlign: Bool { track != nil && !isStale }

    /// Why the Align switch is off limits, in the operator's words, or nil when
    /// it is not. This is the `.help` string the control carries — a disabled
    /// control that does not say why is the thing this redesign removes.
    public var alignmentUnavailableReason: String? {
        if isStale {
            return """
            The stored alignment was measured from different run starts. \
            Compute it again to use it.
            """
        }
        if track == nil {
            return "No alignment has been measured for this pair yet. Compute it first."
        }
        return nil
    }

    /// The translation to apply to the **right** clip at `time` seconds after
    /// the run start, or nil to draw the pair unaligned.
    ///
    /// Everything the gate decides is honoured here: nil means identity,
    /// whether because the operator turned Align off, because no usable track
    /// exists, because the instant is outside the measured span, or because the
    /// gate disengaged at it. A caller that wanted the raw sample instead would
    /// be putting one clip in the corner of the frame during the low-overlap
    /// stretches the gate exists to catch.
    public func translation(at time: TimeInterval) -> CGVector? {
        guard isAligned, canAlign, let resolved else { return nil }
        return resolved.translation(at: time)
    }

    /// Whether the pass measured this instant at all. The two reasons for an
    /// identity translation read completely differently to an operator —
    /// "nothing was measured out here" against "this stretch was measured and
    /// judged unalignable" — so the status chip needs to tell them apart.
    public func covers(_ time: TimeInterval) -> Bool {
        guard canAlign, let resolved else { return false }
        return resolved.covers(time)
    }

    /// Alignment is on, this instant was measured, and the gate still says
    /// identity. Exactly the condition the status chip explains, so that an
    /// unaligned stretch mid-run reads as a decision rather than as the feature
    /// having failed.
    public func isDisengaged(at time: TimeInterval) -> Bool {
        isAligned && covers(time) && translation(at: time) == nil
    }

    /// Reads the sidecar if there is one, moving to `.ready`. Returns what it
    /// found so a caller can decide whether to offer the pass.
    ///
    /// The run starts are passed in rather than read from the track, because
    /// the whole question is whether the two agree.
    @discardableResult
    public func loadStored(
        left: ClipIdentity, right: ClipIdentity,
        leftStart: TimeInterval, rightStart: TimeInterval
    ) -> AlignmentTrack? {
        guard let stored = AlignmentTrackStore.load(left: left, right: right) else {
            reset()
            return nil
        }
        isStale = stored.isStale(leftStart: leftStart, rightStart: rightStart)
        adopt(stored)
        state = .ready(stored)
        return stored
    }

    /// Convenience for a caller that only has URLs — a local pair, most
    /// often. `ClipIdentity(_:)` is always `.local`, so this must not be used
    /// for a pair where either side's bytes sit somewhere other than where
    /// the clip itself lives, which is exactly the cloud case `loadStored(
    /// left:right:leftStart:rightStart:)` exists for.
    @discardableResult
    public func loadStored(
        left: URL, right: URL,
        leftStart: TimeInterval, rightStart: TimeInterval
    ) -> AlignmentTrack? {
        loadStored(
            left: ClipIdentity(left), right: ClipIdentity(right),
            leftStart: leftStart, rightStart: rightStart
        )
    }

    /// Back to knowing nothing, for when the pair itself changes — a clip
    /// swapped, a run start no longer picked. Without this a track loaded for
    /// the previous pair would keep answering `translation(at:)` for a
    /// comparison it does not describe.
    public func reset() {
        cancel()
        adopt(nil)
        state = .idle
        isStale = false
        saveWarning = nil
    }

    /// Runs the registration pass, publishing progress, then writes the
    /// sidecar. Cancels any run in flight first.
    ///
    /// Never leaves `state` on `.computing`: a `CancellationError` returns it
    /// to `.idle` (the operator asked to stop, not to see a failure), and any
    /// other error moves it to `.failed` with a description.
    ///
    /// The track is adopted into memory **before** the write is attempted, and
    /// a failed write is reported through `saveWarning` rather than thrown or
    /// folded into `.failed`. The pass costs the operator fifteen seconds of
    /// waiting; an unwritable footage folder is a persistence problem, not an
    /// alignment failure, and it must not cost them the result.
    ///
    /// `left`/`right` say where to *read the frames from* — the pass needs real
    /// pixels, cloud clip or not, so it always takes URLs. `leftIdentity`/
    /// `rightIdentity` say what to *file the result under*, and are required
    /// rather than defaulted: an optional that quietly fell back to
    /// `ClipIdentity(left)`/`ClipIdentity(right)` would re-create, for any
    /// caller that forgot to pass one, exactly the defect this parameter pair
    /// exists to remove — silently, and only for a cloud pair, which is the
    /// hardest case to notice. For a cloud pair the two answers genuinely
    /// differ: the URLs are cache paths, the identities are the clips
    /// themselves, and only the identities are safe to key a sidecar on. Every
    /// caller has to have both — `ComparisonView.computeAlignment()` does,
    /// being the only production caller — so there is nothing an omitted
    /// identity could mean here.
    public func compute(
        left: URL, right: URL,
        leftIdentity: ClipIdentity, rightIdentity: ClipIdentity,
        leftStart: TimeInterval, rightStart: TimeInterval
    ) async {
        cancel()
        generation += 1
        let myGeneration = generation
        isStale = false
        saveWarning = nil
        state = .computing(progress: 0)

        let performAnalysis = self.performAnalysis
        let task = Task { [weak self] () -> AlignmentTrack in
            try await performAnalysis(left, right, leftStart, rightStart) { progress in
                Task { @MainActor in
                    self?.updateProgress(progress, generation: myGeneration)
                }
            }
        }
        currentTask = task

        do {
            let result = try await task.value
            if myGeneration == generation {
                adopt(result)
                state = .ready(result)
                isStale = false
                do {
                    try AlignmentTrackStore.save(
                        result, left: leftIdentity, right: rightIdentity
                    )
                } catch {
                    saveWarning = "\(left.lastPathComponent): \(error). "
                        + "The alignment still applies for this session."
                }
            }
        } catch is CancellationError {
            if myGeneration == generation {
                state = .idle
            }
        } catch let error as AlignmentAnalyzer.AnalysisError {
            if myGeneration == generation {
                state = .failed(error.description)
            }
        } catch {
            if myGeneration == generation {
                state = .failed(String(describing: error))
            }
        }
        if myGeneration == generation {
            currentTask = nil
        }
    }

    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    public func dismissSaveWarning() {
        saveWarning = nil
    }

    /// Resolving the gate over the whole track is the expensive step, so it
    /// happens here — once per track adopted — and nowhere else.
    private func adopt(_ track: AlignmentTrack?) {
        resolved = track.map(ResolvedAlignment.init(track:))
    }

    private func updateProgress(_ value: Double, generation: Int) {
        guard generation == self.generation else { return }
        guard case .computing = state else { return }
        state = .computing(progress: value)
    }
}

/// `AlignmentGate`'s answer at every sample of one track, computed once.
///
/// Built by asking the real gate at each sample time — not by reimplementing
/// its walk — so the cached series is the gate's own output by construction.
/// Building it is O(n²) once (425 samples on a real track, tens of
/// milliseconds); every playback query afterwards is a binary search.
///
/// ## What a query between two samples returns
///
/// The gate is exact at sample times, so only the gaps need a rule. At the
/// pass's 25 Hz a gap is 40 ms, against a playback clock that ticks every
/// 100 ms, so this is about correctness of shape rather than about a
/// perceptible difference:
///
/// - **Both ends aligned** — interpolate. This *is* the gate: inside an engaged
///   run it interpolates the measured translations, and inside the ease it
///   scales one translation linearly, so a straight line between the two
///   endpoints reproduces both exactly. It is also exact across the instant of
///   a disengage, where the gate holds the last engaged translation and the
///   ease starts from that same value at full weight.
/// - **The earlier end is identity** — identity. Also exact: the gate cannot
///   start easing part way through a gap (an ease starts at the disengaging
///   *sample*), and it never fades alignment *in*, so nothing happens between
///   an identity sample and the next one.
/// - **The later end is identity** — interpolate toward zero, which is where
///   the ease was already heading. The only approximation in the file, and the
///   only place the cache and the gate disagree at all: the gate's ease reaches
///   zero somewhere *inside* this gap, while this one reaches it at the gap's
///   far end, so across those 40 ms the translation runs up to one sample's
///   worth of the ease — 16% of the disengaging translation at 25 Hz — ahead of
///   the gate's. Measured on a track with a disengage, an ease and a re-engage:
///   0.040 s and 0.0035 normalised widths, about 2.8pt on an 800pt video area,
///   and `testTheCacheDiffersFromTheGateOnlyAcrossTheEndOfAnEase` bounds both.
///   The alternative, a step to zero, is a visible jump in the one place the
///   ease exists to prevent one.
struct ResolvedAlignment {
    /// Ascending, parallel to `translations`.
    private let times: [TimeInterval]
    private let translations: [CGVector?]

    init(track: AlignmentTrack) {
        let times = track.samples.map(\.time)
        self.times = times
        self.translations = times.map { AlignmentGate.translation(in: track, at: $0) }
    }

    /// Whether the pass measured this instant.
    func covers(_ time: TimeInterval) -> Bool {
        guard let first = times.first, let last = times.last else { return false }
        return time >= first && time <= last
    }

    func translation(at time: TimeInterval) -> CGVector? {
        guard covers(time), let high = firstIndex(notBefore: time) else { return nil }
        let low = times[high] == time ? high : high - 1
        guard let start = translations[low] else { return nil }
        if low == high { return start }

        let end = translations[high] ?? .zero
        let span = times[high] - times[low]
        guard span > 0 else { return start }
        let fraction = (time - times[low]) / span
        return CGVector(
            dx: start.dx + (end.dx - start.dx) * fraction,
            dy: start.dy + (end.dy - start.dy) * fraction
        )
    }

    /// The first index whose time is at or after `time`, by binary search —
    /// the whole reason this type exists rather than a linear scan of the
    /// gate.
    private func firstIndex(notBefore time: TimeInterval) -> Int? {
        var low = 0
        var high = times.count
        while low < high {
            let middle = (low + high) / 2
            if times[middle] < time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < times.count ? low : nil
    }
}
