import Foundation

/// The per-clip state of "find the subject in this footage": running the
/// analysis, remembering what it found, and persisting the operator's pick.
///
/// A plain observable object rather than view state because the analysis it
/// wraps is a ~16s async job with progress, cancellation and disk IO — three
/// failure modes that are not the sort of thing to reproduce in a UI harness.
@MainActor
public final class SubjectSessionModel: ObservableObject {
    public enum State: Equatable {
        case idle
        case analysing(progress: Double)
        case ready(ClipAnalysis)
        case failed(String)
    }

    /// Confirming a pick with no analysis in memory to attach it to. This is a
    /// caller error — `confirm` is only meaningful after `loadStored` or
    /// `analyse` has produced something — so it is reported rather than
    /// silently swallowed.
    public enum SessionError: Error, CustomStringConvertible {
        case noAnalysis

        public var description: String {
            "no analysis is loaded to attach this pick to"
        }
    }

    /// The shape of `SubjectAnalyzer.analyse`, minus the parameters this model
    /// never overrides. Injectable so tests can stand in a fake for the ~16s
    /// real analyser — the transitions in `analyse(clip:)` (success, cancel,
    /// known failure, unknown failure, and a second run superseding a first)
    /// are exactly the ones a frozen `.analysing` state would hide, and they
    /// are not reachable from a unit test through the real Vision pipeline.
    public typealias AnalyseFunction = @Sendable (
        URL, @escaping @Sendable (Double) -> Void
    ) async throws -> ClipAnalysis

    @Published public private(set) var state: State = .idle
    @Published public private(set) var isStale = false

    private let performAnalysis: AnalyseFunction
    private var currentTask: Task<ClipAnalysis, Error>?
    /// Bumped on every `analyse(clip:)` call so a run superseded by a later
    /// one can tell, once its cancellation unwinds, that it is no longer the
    /// run of record and must not overwrite `state` with its own outcome.
    private var generation = 0

    public var analysis: ClipAnalysis? {
        if case let .ready(analysis) = state { return analysis }
        return nil
    }

    public var pickedSubject: SubjectPick? { analysis?.subject }

    public init(analyse: @escaping AnalyseFunction = { clip, progress in
        try await SubjectAnalyzer.analyse(clip: clip, progress: progress)
    }) {
        self.performAnalysis = analyse
    }

    /// Reads the sidecar if there is one, moving to `.ready`. Returns what it
    /// found so a caller can decide whether to offer analysis.
    ///
    /// Staleness is surfaced via `isStale`, never acted on: the segments, the
    /// pick and the run start are all kept exactly as stored. A run start is a
    /// time and a time does not expire; the pick is expensive human input.
    /// Silently recomputing would discard a human decision to chase a number
    /// that was probably already right.
    @discardableResult
    public func loadStored(for clip: URL) -> ClipAnalysis? {
        guard let stored = ClipAnalysisStore.load(for: clip) else {
            state = .idle
            isStale = false
            return nil
        }
        isStale = stored.isStale(against: .current)
        state = .ready(stored)
        return stored
    }

    /// Runs the analysis, publishing progress. Cancels any run in flight
    /// first.
    ///
    /// Never leaves `state` on `.analysing`: a `CancellationError` returns it
    /// to `.idle` (the operator asked to stop, not to see a failure), and any
    /// other error — in practice a `SubjectAnalyzer.AnalysisError` — moves it
    /// to `.failed` with a description.
    public func analyse(clip: URL) async {
        cancel()
        generation += 1
        let myGeneration = generation
        isStale = false
        state = .analysing(progress: 0)

        let performAnalysis = self.performAnalysis
        let task = Task { [weak self] () -> ClipAnalysis in
            try await performAnalysis(clip) { progress in
                Task { @MainActor in
                    self?.updateProgress(progress, generation: myGeneration)
                }
            }
        }
        currentTask = task

        do {
            let result = try await task.value
            if myGeneration == generation {
                state = .ready(result)
                isStale = false
            }
        } catch is CancellationError {
            if myGeneration == generation {
                state = .idle
            }
        } catch let error as SubjectAnalyzer.AnalysisError {
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

    /// Records the pick in memory, then writes the sidecar. Throws only on
    /// the write — the pick is kept either way.
    ///
    /// The ordering here is the point: the operator has just spent ~20s and
    /// made a judgement no algorithm can make. Updating in-memory state
    /// before attempting the write means that judgement survives even if the
    /// footage sits on a read-only volume or the disk is full — persistence
    /// failing is not analysis failing.
    /// - Parameter correctedRunStart: the operator's correction to the detected
    ///   start, when this call is recording one. It never replaces `runStart`:
    ///   the measurement and the judgement are two different facts, and keeping
    ///   both is what lets a re-analysis update the measurement without
    ///   discarding the judgement. Defaults to nil, so confirming a *fresh*
    ///   pick drops any earlier correction — a correction is to a particular
    ///   detected start, and a new detection is not that start.
    public func confirm(
        segmentIDs: [Int], runStart: StoredRunStart,
        correctedRunStart: TimeInterval? = nil, for clip: URL
    ) throws {
        guard let current = analysis else { throw SessionError.noAnalysis }
        let updated = current.with(
            subject: SubjectPick(
                segmentIDs: segmentIDs, runStart: runStart,
                correctedRunStart: correctedRunStart
            )
        )
        state = .ready(updated)
        try ClipAnalysisStore.save(updated, for: clip)
    }

    private func updateProgress(_ value: Double, generation: Int) {
        guard generation == self.generation else { return }
        guard case .analysing = state else { return }
        state = .analysing(progress: value)
    }
}
