import AVFoundation
import Combine
import SkiVideoCore
import SwiftUI

/// The two per-clip subject sessions, one per side.
///
/// A reference type with one accessor rather than two `@StateObject`s and an
/// `if side == .left` at every call site: "which session belongs to which
/// side" is a rule, and a rule stated once can be tested once. Owned by
/// `ComparisonView` for the window's lifetime, so a pick made on the left
/// clip is still there when the right one is picked and the pair can be
/// synced.
@MainActor
final class SubjectSessions: ObservableObject {
    let left = SubjectSessionModel()
    let right = SubjectSessionModel()

    private var republish: [AnyCancellable] = []

    /// Forwards both children's `objectWillChange`, which is not ceremony:
    /// nesting one `ObservableObject` inside another publishes nothing by
    /// itself, so without this a pick confirmed on the second side would not
    /// re-render `ComparisonView` — and "Sync from detected starts" is derived
    /// from exactly that state, so the menu would stay absent until some
    /// unrelated change happened to redraw the bar.
    init() {
        for session in [left, right] {
            session.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &republish)
        }
    }

    func session(for side: ComparisonSide) -> SubjectSessionModel {
        side == .left ? left : right
    }
}

/// What the run-start pass — the second, equally long read of the clip that
/// follows a confirmed pick — is doing right now.
///
/// It exists because `SubjectPickSheet.onConfirm` returns immediately and the
/// work that follows takes about as long as the analysis did. Without a state
/// to show, the sheet would sit on the segment grid, unresponsive to the
/// button the operator just pressed, for twenty seconds.
enum RunStartPhase: Equatable {
    case notRunning
    case working
    case failed(String)
}

/// Composition only. Everything that used to be inline here — the panes, the
/// timeline, the transport, the blend controls — is one file each now; see the
/// spec's "Structure" table. Side-by-side is two rows of chrome, overlay three.
struct ComparisonView: View {
    @StateObject private var model: ComparisonModel
    @StateObject private var subjects = SubjectSessions()
    /// How this pair lines up spatially. One per window, like `subjects`: a
    /// track describes a *pair*, so it belongs to the comparison and not to
    /// either side.
    @StateObject private var alignment = AlignmentSessionModel()
    /// How a pane materialises a cloud clip it was just given. Threaded down
    /// to `ComparisonVideos`, and from there to every `ClipSourceMenu` — see
    /// `SecondaryScreenPresenter.presentComparison`, which is where this
    /// closure comes from, for why it exists and why it is a closure and not
    /// a `ViewerModel`.
    let prepare: ClipPreparer
    let closeWindow: () -> Void

    /// Non-nil while the subject sheet is up, and the side it is up for.
    @State private var picking: PickingSide?
    @State private var runStart: RunStartPhase = .notRunning
    @State private var runStartTask: Task<Void, Never>?
    @State private var alignmentTask: Task<Void, Never>?
    /// The pending write of a corrected start; see `scheduleCorrectionWrite`.
    @State private var correctionTask: Task<Void, Never>?
    /// A sidecar that could not be written. Surfaced once, plainly; the pick
    /// itself is kept and the sync still applies.
    @State private var sidecarWarning: String?

    init(
        initialLeftVideo: URL?,
        openLibrary: [ComparisonAthleteChoice],
        input: PlaybackInputSource,
        folderPicker: FolderPicker,
        prepare: ClipPreparer,
        closeWindow: @escaping () -> Void
    ) {
        _model = StateObject(
            wrappedValue: ComparisonModel(
                initialLeftVideo: initialLeftVideo,
                openLibrary: openLibrary,
                input: input,
                folderPicker: folderPicker
            )
        )
        self.prepare = prepare
        self.closeWindow = closeWindow
    }

    var body: some View {
        VStack(spacing: 0) {
            videos
                // Over the video rather than in a row of its own; see
                // `ComparisonStatusChip` for why, and for why its width is a
                // constant. The 8pt inset lives here because it is a placement
                // decision, not part of the pill.
                .overlay(alignment: .topTrailing) {
                    ComparisonStatusChip(status: model.status, alignmentNote: alignmentNote)
                        .padding(8)
                }

            // One surface for the chrome, as every deleted control row had.
            // Applied to the group rather than per row so the scrubber, the
            // blend bar and the control bar cannot end up on different
            // backgrounds; it changes no height.
            VStack(spacing: 0) {
                if model.layout == .overlay {
                    OverlayBlendBar(
                        model: model,
                        alignment: alignment,
                        canComputeAlignment: canComputeAlignment,
                        onComputeAlignment: { computeAlignment() }
                    )
                }
                ComparisonScrubber(model: model)
                    .padding(.horizontal, 12)
                ComparisonControlBar(
                    model: model,
                    analysableSides: analysableSides,
                    canSyncFromDetectedStarts: runStarts != nil,
                    onFindSubject: { side in openSubjectSheet(side) },
                    onSyncFromDetectedStarts: { syncFromDetectedStarts() }
                )
            }
            .background(.bar)
        }
        // Reads the sidecar whenever a side's clip changes, which is what
        // makes "Sync from detected starts" available on a reopened window
        // without a second analysis. Keyed on the published name because the
        // URL itself is not published; `load` sets both together.
        .task(id: model.leftName) { loadStoredSubject(.left) }
        .task(id: model.rightName) { loadStoredSubject(.right) }
        // Keyed on the pair *and* the run starts, because a track is only
        // meaningful for the starts it was measured against — picking the
        // subject again on one side is exactly the event that makes a stored
        // track stale, and the sidecar has to be re-read against the new
        // number for `isStale` to say so.
        .task(id: alignmentKey) { loadStoredAlignment() }
        // The anchor moving is the only signal that the operator corrected a
        // start — `scrub` and `nudge` both express a correction by carrying the
        // sync point — so the write hangs off that rather than off any one
        // control.
        .onChange(of: model.syncPoints) { _ in scheduleCorrectionWrite() }
        .sheet(item: $picking) { picking in
            SubjectSheet(
                session: subjects.session(for: picking.side),
                clip: picking.clip,
                sideTitle: picking.side == .left ? "Left clip" : "Right clip",
                phase: runStart,
                onConfirm: {
                    confirmSubject(
                        side: picking.side, clip: picking.clip,
                        identity: picking.identity, segmentIDs: $0
                    )
                },
                onCancelRunStart: { cancelRunStart() },
                onDone: { dismissSubjectSheet() }
            )
        }
        .alert(
            "The pick could not be saved",
            isPresented: Binding(
                get: { sidecarWarning != nil },
                set: { if !$0 { sidecarWarning = nil } }
            )
        ) {
            Button("OK") { sidecarWarning = nil }
        } message: {
            Text(sidecarWarning ?? "")
        }
        // Its own alert rather than folded into the one above: the two fail
        // for different reasons and are recovered from differently, and the
        // pick alert's title names the pick.
        .alert(
            "The alignment could not be saved",
            isPresented: Binding(
                get: { alignment.saveWarning != nil },
                set: { if !$0 { alignment.dismissSaveWarning() } }
            )
        ) {
            Button("OK") { alignment.dismissSaveWarning() }
        } message: {
            Text(alignment.saveWarning ?? "")
        }
        // An 11-inch iPad is 834pt wide in portrait, so a hard 1000pt minimum
        // clips. macOS keeps it: the Compare window is resizable and needs a
        // floor. Same shape as `ContentView`'s minimum-size conditional.
        #if os(macOS)
        .frame(minWidth: 1000, minHeight: 680)
        #endif
        // macOS drops the Close button — the window has one. iPad needs it,
        // because a full-screen cover has no chrome of its own, and it goes
        // over the video rather than into a row.
        #if os(iOS)
        .overlay(alignment: .topLeading) { closeButton }
        #endif
        .onDisappear {
            // Flushed, not merely cancelled: closing the window within 0.3s of
            // the last adjustment is an ordinary thing to do — correct the
            // start, look at it, close — and the debounce must not be the
            // reason that correction is lost.
            correctionTask?.cancel()
            persistCorrections()
            runStartTask?.cancel()
            alignmentTask?.cancel()
            alignment.cancel()
            model.close()
        }
    }

    // MARK: - Alignment

    /// Everything a stored track has to be checked against. A `.task(id:)` key
    /// rather than three separate tasks, because the load is one decision made
    /// from all four values and re-running it on each in turn would read the
    /// sidecar against a half-updated pair.
    private var alignmentKey: String {
        let starts = runStarts
        return [
            model.leftName,
            model.rightName,
            starts.map { String($0.left) } ?? "-",
            starts.map { String($0.right) } ?? "-",
        ].joined(separator: "|")
    }

    /// The pass needs a local file on each side and a run start on each. The
    /// same two conditions gate the Compute button, so it cannot offer work
    /// that `computeAlignment` would then decline to start.
    private var canComputeAlignment: Bool {
        clip(for: .left) != nil && clip(for: .right) != nil && runStarts != nil
    }

    private func loadStoredAlignment() {
        guard
            clip(for: .left) != nil,
            clip(for: .right) != nil,
            let leftIdentity = model.identity(for: .left),
            let rightIdentity = model.identity(for: .right),
            let starts = runStarts
        else {
            // Not merely "leave it alone": a track loaded for the previous pair
            // would go on answering for a comparison it does not describe.
            alignment.reset()
            return
        }
        alignment.loadStored(
            left: leftIdentity, right: rightIdentity,
            leftStart: starts.left, rightStart: starts.right
        )
    }

    private func computeAlignment() {
        guard
            let left = clip(for: .left),
            let right = clip(for: .right),
            let leftIdentity = model.identity(for: .left),
            let rightIdentity = model.identity(for: .right),
            let starts = runStarts
        else { return }
        alignmentTask?.cancel()
        // `@MainActor` explicitly, as `confirmSubject` does and for the same
        // measured reason: the task body starts on the main thread, the pass
        // itself runs off it, and the state writes land back on the actor that
        // owns them.
        alignmentTask = Task { @MainActor in
            // `left`/`right` say where to read the frames from — a cloud clip's
            // cache path, same as always. `leftIdentity`/`rightIdentity` say
            // what to file the result under, so a freshly computed track for a
            // cloud pair lands where `loadStoredAlignment()` above will actually
            // look for it, instead of under a cache-path identity nothing reads
            // by again.
            await alignment.compute(
                left: left, right: right,
                leftIdentity: leftIdentity, rightIdentity: rightIdentity,
                leftStart: starts.left, rightStart: starts.right
            )
        }
    }

    /// Where the playhead is *within the run*, which is the only clock an
    /// alignment track is indexed by.
    ///
    /// Measured from the left clip, because that is the reference side: the
    /// pass records each sample's time as the left clip's own offset from its
    /// run start. While the pair is synced the right clip is at the same run
    /// phase by construction, so either would do; taking it from one side means
    /// there is no second answer to disagree with.
    private var runPhase: TimeInterval? {
        guard let starts = runStarts else { return nil }
        return model.leftTime - starts.left
    }

    /// What the renderer is handed. `.zero` for every reason the gate says
    /// identity — Align off, no track, a stale track, outside the measured
    /// span, or a stretch the gate disengaged on.
    private var alignmentTranslation: CGVector {
        guard let runPhase else { return .zero }
        return alignment.translation(at: runPhase) ?? .zero
    }

    /// Said only when alignment is on and this instant *was* measured, so the
    /// operator reads an unaligned stretch as a decision the pass made rather
    /// than as the feature having quietly failed. Outside the measured span
    /// there is nothing to explain and the chip stays as it was.
    private var alignmentNote: String? {
        guard model.layout == .overlay, let runPhase else { return nil }
        guard alignment.isDisengaged(at: runPhase) else { return nil }
        return "Not aligned here — the cameras share too little of the view."
    }

    // MARK: - Subjects

    /// The clip a side is playing. Read back off the player rather than
    /// tracked separately: `ComparisonModel` publishes the *name* but keeps
    /// the URL to itself, and `load` builds its `AVPlayerItem` from a URL, so
    /// the asset is the one place both `load(_ url:)` and
    /// `load(_ choice:)` agree on.
    private func clip(for side: ComparisonSide) -> URL? {
        let player = side == .left ? model.leftPlayer : model.rightPlayer
        guard let url = (player.currentItem?.asset as? AVURLAsset)?.url else { return nil }
        // A Drive stream has no frames to read locally; analysis needs a file.
        return url.isFileURL ? url : nil
    }

    private var analysableSides: Set<ComparisonSide> {
        var sides: Set<ComparisonSide> = []
        if clip(for: .left) != nil { sides.insert(.left) }
        if clip(for: .right) != nil { sides.insert(.right) }
        return sides
    }

    /// The pair of stored run starts, or nil unless *both* sides have one.
    /// Also what gates the secondary menu, so the menu cannot offer a sync it
    /// would then decline to perform.
    ///
    /// `SubjectPick.syncTime`, not `runStart.syncTime`: the start that applies
    /// is the operator's correction wherever they made one. That is what makes
    /// a correction survive a reopen without re-analysis, and it feeds
    /// `alignmentKey` too — so correcting a start marks a track measured
    /// against the old one as no longer describing this pair, which is exactly
    /// what it is.
    private var runStarts: (left: TimeInterval, right: TimeInterval)? {
        guard
            let left = subjects.left.pickedSubject?.syncTime,
            let right = subjects.right.pickedSubject?.syncTime
        else { return nil }
        return (left, right)
    }

    /// Whether either side's start is a correction rather than a measurement.
    /// Only the status sentence reads it — see `ComparisonModel.applySync`.
    private var startsAreCorrected: Bool {
        subjects.left.pickedSubject?.correctedRunStart != nil
            || subjects.right.pickedSubject?.correctedRunStart != nil
    }

    private func loadStoredSubject(_ side: ComparisonSide) {
        guard clip(for: side) != nil, let identity = model.identity(for: side) else { return }
        subjects.session(for: side).loadStored(for: identity)
    }

    private func openSubjectSheet(_ side: ComparisonSide) {
        guard let clip = clip(for: side), let identity = model.identity(for: side) else { return }
        runStart = .notRunning
        picking = PickingSide(side: side, clip: clip, identity: identity)
    }

    private func dismissSubjectSheet() {
        cancelRunStart()
        picking = nil
    }

    private func cancelRunStart() {
        runStartTask?.cancel()
        runStartTask = nil
        runStart = .notRunning
    }

    /// The shape of `SubjectAnalyzer.runStart`, as `record` calls it.
    ///
    /// Injectable for the same reason `SubjectSessionModel.AnalyseFunction` is:
    /// the pass is a ~20s read of the whole clip, and the assertion that an
    /// unchanged pick does **not** run it has to be a call count, not a
    /// stopwatch. A test that timed it would pass on a fast machine and on a
    /// cached read whether or not the reuse rule existed.
    typealias RunStartMeasurement = (URL, ClipAnalysis, [Int]) async throws -> SubjectRunStart.Outcome

    /// The stored pick that already answers for `segmentIDs`, or nil when the
    /// question has changed and the previous answer does not apply.
    ///
    /// **Sets, not ordered arrays.** `selectedInTimeOrder` is deterministic, so
    /// two picks made through the sheet usually produce the same array — but the
    /// operator's own C0094 sidecar stores `[15, 8, 6, 3, 4, 5, 1]`, which is
    /// not time order, so an ordered comparison would have recomputed that clip
    /// on every confirm forever. The same segments in a different order are the
    /// same subject.
    ///
    /// A stale analysis is not reused: `parameters` changing means the segment
    /// ids themselves were produced by different settings, so "segment 6" in the
    /// stored pick and "segment 6" in the list the operator just picked from are
    /// not necessarily the same detections. That is a different question, not the
    /// same one asked twice.
    static func reusablePick(
        in analysis: ClipAnalysis, isStale: Bool, segmentIDs: [Int]
    ) -> SubjectPick? {
        guard !isStale, let stored = analysis.subject else { return nil }
        guard Set(stored.segmentIDs) == Set(segmentIDs), !segmentIDs.isEmpty else { return nil }
        return stored
    }

    /// What confirming a pick did, and the start it left in force.
    ///
    /// The two cases are kept apart rather than collapsed into a time because
    /// the sheet must not claim work it did not do: `.reused` completes with no
    /// spinner at all, and telling the operator "finding the run start, about
    /// twenty seconds" for a pass that never ran is the report of a lie.
    enum ConfirmOutcome: Equatable {
        /// The stored answer applied. No pass was run; the payload is the
        /// effective start, which is the operator's correction wherever they
        /// made one.
        case reused(TimeInterval)
        /// A fresh pass measured this start.
        case measured(TimeInterval)
        /// The pass ran and found no start to sync on. The payload is what to
        /// tell the operator.
        case unmeasurable(String)
    }

    /// Records a confirmed pick on `session`, running the run-start pass only
    /// when the stored answer does not apply.
    ///
    /// **Static and internal so the decision can be driven from a test.**
    /// `ComparisonView` builds its own `ComparisonModel` in `init`, so a
    /// rendered one cannot be handed a session that already holds a pick — the
    /// same reason `correction(for:anchoredAt:)` and `stored(_:)` are static.
    /// And this is the path that reported "it recomputes every time".
    ///
    /// The reuse branch re-confirms with **`stored.correctedRunStart`**, not
    /// with nothing. `confirm`'s parameter defaults to nil precisely so that a
    /// *fresh* detection drops a correction that no longer describes it — which
    /// makes omitting it here a silent revert. On the operator's C0094 that is a
    /// drop from a corrected 18.290s back to a detected 0.640s: not a slow path,
    /// a lost eighteen seconds of judgement.
    ///
    /// `identity` defaults to nil and, when omitted, falls back to
    /// `ClipIdentity(clip)` — exactly what `session.confirm(…, for: clip)`
    /// already did, so a caller that only has a URL (every pre-existing test
    /// of this function) keeps its old behaviour unchanged. `ComparisonView`
    /// itself always passes the side's real identity, which is what makes a
    /// cloud clip's pick land in the keyed store instead of beside its cache
    /// path.
    @MainActor
    static func record(
        segmentIDs: [Int], clip: URL, identity: ClipIdentity? = nil, in session: SubjectSessionModel,
        measuringWith measure: RunStartMeasurement,
        reportingSaveFailure onSaveFailure: (Error) -> Void = { _ in }
    ) async throws -> ConfirmOutcome {
        guard let analysis = session.analysis else { throw SubjectSessionModel.SessionError.noAnalysis }

        let stored: StoredRunStart
        let corrected: TimeInterval?
        let outcome: ConfirmOutcome

        if let reusable = reusablePick(in: analysis, isStale: session.isStale, segmentIDs: segmentIDs) {
            stored = reusable.runStart
            corrected = reusable.correctedRunStart
            outcome = .reused(reusable.syncTime)
        } else {
            let measured = try await measure(clip, analysis, segmentIDs)
            // Before the write, not after: the operator's Cancel means "do not
            // record this pick", and a cancellation that arrived while the pass
            // was unwinding must not still reach the sidecar.
            try Task.checkCancellation()
            guard let time = Self.stored(measured) else {
                return .unmeasurable(Self.message(for: measured))
            }
            stored = time
            // Deliberately nil: a correction is to a particular detected start,
            // and this is not that start.
            corrected = nil
            outcome = .measured(time.syncTime)
        }

        do {
            try session.confirm(
                segmentIDs: segmentIDs, runStart: stored,
                correctedRunStart: corrected, for: identity ?? ClipIdentity(clip)
            )
        } catch {
            // Surfaced once and moved past: the pick is in memory and good for
            // this session, and refusing the sync because a sidecar could not be
            // written would throw away twenty seconds of the operator's work
            // over a file permission.
            onSaveFailure(error)
        }
        return outcome
    }

    /// The half of the interaction the sheet deliberately does not own: a
    /// second full read of the clip to find where the picked subject's run
    /// begins — *unless the sidecar already answers for exactly these
    /// segments*, in which case there is nothing to read.
    ///
    /// When the pass does run the sheet stays up in `.working` for all of it.
    /// That is the point — `onConfirm` returns instantly and this takes about as
    /// long as the analysis did, so dismissing here would leave the operator
    /// looking at a window that does nothing for twenty seconds. When the stored
    /// answer is reused, `.working` is never entered at all: the decision is made
    /// here, synchronously, before any task is started, so the operator does not
    /// see a spinner flash for work that did not happen.
    private func confirmSubject(
        side: ComparisonSide, clip: URL, identity: ClipIdentity, segmentIDs: [Int]
    ) {
        let session = subjects.session(for: side)
        // Unreachable in practice — the confirm button only exists in the
        // `.ready` state, and `analysis` is exactly what that state carries —
        // but a bare `return` here would read to the operator as a button that
        // does nothing, which is the failure this whole path is written to
        // avoid. So it says so instead.
        guard let analysis = session.analysis else {
            runStart = .failed("The analysis for this clip is no longer loaded. Find the subject again.")
            return
        }
        runStartTask?.cancel()
        let reusing = Self.reusablePick(
            in: analysis, isStale: session.isStale, segmentIDs: segmentIDs
        ) != nil
        runStart = reusing ? .notRunning : .working
        // `@MainActor` explicitly, though a `Task` started from here inherits
        // it anyway. Measured with a probe of this exact shape — a `Task`
        // spawned inside a `View`'s method — rather than assumed: the task
        // body starts on the main thread, `SubjectAnalyzer.runStart` (a
        // nonisolated `async` function) runs on a background one, and control
        // is back on main after the `await`. So the twenty seconds do not
        // block the sheet's spinner, and the state writes below are on the
        // actor that owns them.
        runStartTask = Task { @MainActor in
            do {
                let outcome = try await Self.record(
                    segmentIDs: segmentIDs, clip: clip, identity: identity, in: session,
                    measuringWith: { clip, analysis, ids in
                        try await SubjectAnalyzer.runStart(
                            clip: clip, analysis: analysis, segmentIDs: ids
                        )
                    },
                    reportingSaveFailure: { error in
                        sidecarWarning = "\(clip.lastPathComponent): \(error). The pick still applies for this session."
                    }
                )
                if Task.isCancelled { return }
                if case let .unmeasurable(message) = outcome {
                    runStart = .failed(message)
                    return
                }
                runStart = .notRunning
                runStartTask = nil
                picking = nil
                syncFromDetectedStarts()
            } catch is CancellationError {
                runStart = .notRunning
            } catch {
                runStart = .failed(String(describing: error))
            }
        }
    }

    /// Applies the sync the moment both sides have one, per the spec — the
    /// operator does not have to ask again after the second pick. Also the
    /// secondary menu's action, for the reopened-window case where both picks
    /// were already stored.
    ///
    /// `alreadyRunning` is applied like any other: its `syncTime` is that
    /// clip's first sample. `ComparisonModel.applySync` records the origin, so
    /// the status says the sync came from detected starts.
    private func syncFromDetectedStarts() {
        guard let starts = runStarts else { return }
        model.applySync(left: starts.left, right: starts.right, corrected: startsAreCorrected)
    }

    // MARK: - Keeping the operator's correction

    /// How far the pair's anchor must move before it counts as a correction.
    ///
    /// Not zero: `applySync` latches its anchor as
    /// `CMTime(seconds:preferredTimescale: 600)`, so a start that was merely
    /// re-applied can differ from the stored one by up to 1/600s. 10ms is
    /// comfortably above that and comfortably below one frame at 50fps (20ms),
    /// so no real correction is filtered out and no rounding is written back.
    private static let correctionEpsilon: TimeInterval = 0.01

    /// A correction is written when the operator stops moving, not while they
    /// move.
    ///
    /// A drag emits continuously — `TimelineScrubber` seeks live rather than on
    /// release, deliberately, because finding a frame means watching the frames
    /// go by — so a write per event would be hundreds of sidecar writes per
    /// gesture. `ComparisonScrubber` exposes no drag-end (`TimelineScrubber`
    /// keeps `onEditingChanged` to itself), and threading a new callback
    /// through three views to persist a file is the wrong shape, so this
    /// debounces instead: the last change wins 0.3s after the changes stop.
    /// The release itself re-emits the final position, so the timer is measured
    /// from a settled value.
    private func scheduleCorrectionWrite() {
        correctionTask?.cancel()
        correctionTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            persistCorrections()
        }
    }

    /// Writes each side's corrected start, if it moved.
    ///
    /// Only while the sync came from run starts. A manual `setSyncPoints()`
    /// anchors the pair wherever the operator happened to park it, which is not
    /// a claim about where the run begins, and recording it as one would write
    /// a wrong number into a sidecar that no longer says it is wrong.
    ///
    /// Per side, and only when it actually moved: syncing without correcting
    /// must not rewrite five sidecars, and dragging a start back to the
    /// detected value must clear the correction rather than pin the same number
    /// twice.
    private func persistCorrections() {
        guard case .detected = model.syncOrigin, let points = model.syncPoints else { return }
        persistCorrection(.left, start: points.left)
        persistCorrection(.right, start: points.right)
    }

    /// What a side's sidecar should say, given where the pair is now anchored.
    ///
    /// **Internal and static so the rule can be tested without a window.**
    /// `ComparisonView` builds its own `ComparisonModel` in `init`, so there is
    /// no way to hand a rendered one a corrected pair; the same reason
    /// `stored(_:)` and `message(for:)` are static. And this is the rule that
    /// decides whether the operator's twenty seconds are written or dropped.
    static func correction(for pick: SubjectPick, anchoredAt start: TimeInterval) -> StartCorrection {
        guard abs(pick.syncTime - start) > correctionEpsilon else { return .unchanged }
        // Back to nil rather than to the detected value: "the operator never
        // corrected this" and "the operator dragged it back to where the
        // detector already had it" are the same state, and only one of them
        // belongs on disk — a correction that says nothing is a correction that
        // lies about the detector's error being non-zero.
        return .write(abs(pick.runStart.syncTime - start) > correctionEpsilon ? start : nil)
    }

    /// The outcome of `correction(for:anchoredAt:)`. An enum rather than a
    /// `TimeInterval??`, because the two nils mean opposite things: "leave the
    /// file alone" and "write, clearing the correction".
    enum StartCorrection: Equatable {
        case unchanged
        case write(TimeInterval?)
    }

    private func persistCorrection(_ side: ComparisonSide, start: TimeInterval) {
        guard
            let clip = clip(for: side),
            let identity = model.identity(for: side),
            let pick = subjects.session(for: side).pickedSubject,
            case let .write(corrected) = Self.correction(for: pick, anchoredAt: start)
        else { return }
        do {
            try subjects.session(for: side).confirm(
                segmentIDs: pick.segmentIDs, runStart: pick.runStart,
                correctedRunStart: corrected, for: identity
            )
        } catch {
            // Same rule as a failed pick write, for the same reason: the
            // correction is in memory and good for this session, and refusing
            // it over a file permission would cost the operator the adjustment
            // they just made by eye.
            sidecarWarning = "\(clip.lastPathComponent): \(error). The corrected start still applies for this session."
        }
    }

    /// The outcomes that are a time to sync on, and the two that are not.
    /// Internal and static so the mapping can be tested without a clip: it is
    /// the one place `SubjectRunStart.Outcome` becomes something storable, and
    /// getting `alreadyRunning` wrong would silently sync on zero.
    static func stored(_ outcome: SubjectRunStart.Outcome) -> StoredRunStart? {
        switch outcome {
        case let .started(start):
            return .started(time: start.time, baseline: start.baseline, threshold: start.threshold)
        case let .alreadyRunning(firstSeen):
            return .alreadyRunning(firstSeen: firstSeen)
        case .neverMoves, .noSamples:
            return nil
        }
    }

    /// What to say when there is no run start to store. Both cases mean "this
    /// pick cannot be synced on", and they mean opposite things about why, so
    /// they are not merged into one sentence.
    static func message(for outcome: SubjectRunStart.Outcome) -> String {
        switch outcome {
        case .neverMoves:
            return "This subject never starts moving in the clip, so there is no run start to sync on. Try picking different segments."
        case .noSamples:
            return "The picked segments have no detections to measure, so there is no run start to sync on."
        case .started, .alreadyRunning:
            return ""
        }
    }

    private var videos: some View {
        ComparisonVideos(model: model, translation: alignmentTranslation, prepare: prepare)
    }

    /// What `.sheet(item:)` needs: the side being picked, plus the clip it was
    /// opened for. Carrying the clip means the sheet cannot be re-pointed at a
    /// different file half way through by a load on that side.
    struct PickingSide: Identifiable {
        let side: ComparisonSide
        let clip: URL
        /// Captured alongside `clip` rather than re-read from the model at
        /// confirm time, for the same reason `clip` is captured: the sheet
        /// must not be re-pointed at a different clip's identity half way
        /// through by a load on that side.
        let identity: ClipIdentity
        var id: String { (side == .left ? "left:" : "right:") + clip.path }
    }

    private var closeButton: some View {
        Button {
            closeWindow()
        } label: {
            Image(systemName: "xmark")
                .frame(width: 44, height: 44)
                .darkFrostedBacking(in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(12)
        .accessibilityLabel("Close comparison")
    }
}

/// The video area: whichever layout is selected, and nothing else.
/// `ComparisonView` hangs the status chip on it and puts the chrome below it.
///
/// **Its own view, and internal, so a test can render exactly what ships.**
/// This was a `private var videos` on `ComparisonView`, unreachable from a
/// test: `ComparisonView` owns its model as a `@StateObject` and builds it in
/// `init`, so there is no way to hand it a model with a clip loaded or a layout
/// selected. A test that rebuilt this composition for itself would have gone on
/// passing after the chips below were deleted from the shipped one — which is
/// the mutation `ClipChooserTests` has to be able to catch.
struct ComparisonVideos: View {
    @ObservedObject var model: ComparisonModel

    /// The gated translation for this instant, already resolved by
    /// `ComparisonView` — this view neither owns the track nor consults the
    /// gate. Only the overlay layout uses it: side-by-side draws the two clips
    /// in separate rects, where moving one within its own pane would align
    /// nothing to anything.
    var translation: CGVector = .zero

    /// Forwarded to every `ClipSourceMenu` this view builds — both panes in
    /// the side-by-side layout, both chips in the overlay layout — so a pick
    /// made anywhere fetches the same way. See `ComparisonView.prepare` for
    /// where it comes from.
    ///
    /// Defaulted rather than required: `ClipChooserTests` and `ZoomWiringTests`
    /// build this view directly to measure or drive panes and chips, never to
    /// exercise a pick, so they have no `prepare` closure to supply and must
    /// not need one to keep compiling.
    var prepare: ClipPreparer = .none

    /// Where the overlay's current drag had reached at its previous change, so
    /// that `DragGesture`'s translation-from-the-start becomes a per-change
    /// delta.
    ///
    /// **`@GestureState` rather than `@State` with an `onEnded` reset, which is
    /// a measured bug and not a style preference** — see `ViewerPane.lastDrag`
    /// and `ComparisonPane.lastDrag`, which carry the measurement.
    /// `@GestureState` reverts when the gesture ends *or is cancelled*, and only
    /// the second covers `overlayPan` being removed out from under a live drag,
    /// which happens here whenever the stack drops to 1×. Re-measured for this
    /// gesture rather than taken on trust: 4× in a 400×300 stack, a 60pt
    /// leftward drag torn down mid-flight then a fresh 20pt one, gives 0.5125
    /// as written and 0.475 with `@State` and an `onEnded` reset — a leftward
    /// drag moving the picture 40pt to the right.
    ///
    /// Unused by the side-by-side branch — each `ComparisonPane` is its own
    /// `View` value with its own — but it lives on this type because the
    /// overlay's gesture has to, and for the reason `overlayChoosers` gives:
    /// `OverlayPlayerStack` is a pure renderer and nothing that needs the model
    /// may move into it.
    @GestureState private var lastOverlayDrag: CGSize = .zero

    /// How large the overlay's video area is, which the drag and the zoom chip
    /// both need — `VideoZoom` clamps the pan against it — and which only a
    /// `GeometryReader` can say. The whole video area here rather than half of
    /// it, which is precisely why it cannot be a pane's number.
    ///
    /// **Measured into state through a `.background` rather than read from a
    /// `GeometryReader` wrapped round the branch, and that is a test's
    /// constraint rather than a preference.** `ClipChooserTests` reflects the
    /// *shipped* composition — that is the whole point of `ComparisonVideos`
    /// being its own internal view — and reflection cannot see inside a
    /// `GeometryReader`'s content closure, which is stored unevaluated. Wrapping
    /// this branch in one hid both overlay choosers from
    /// `testEachOverlayChipNamesItsSide`, which found zero where it wanted two.
    /// A `.background` closure is built eagerly and holds nothing but
    /// `Color.clear`, so the choosers stay where a walk of the view tree can
    /// reach them.
    ///
    /// `.zero` for the first pass, before any layout has happened. Both readers
    /// tolerate it by construction: `VideoZoom.pan` refuses a degenerate pane
    /// outright, and `setScale` applies the scale while skipping the re-clamp —
    /// both documented on `VideoZoom` as the pre-layout case rather than as an
    /// edge one.
    @State private var stackSize: CGSize = .zero

    @ViewBuilder
    var body: some View {
        switch model.layout {
        case .sideBySide:
            HStack(spacing: 1) {
                ComparisonPane(model: model, side: .left, prepare: prepare)
                // Constrained deliberately: a bare `Divider()` inside an
                // `HStack` is vertically greedy and squeezes the video.
                Divider().frame(width: 1)
                ComparisonPane(model: model, side: .right, prepare: prepare)
            }
        case .overlay:
            // Both platforms use the SwiftUI stack. macOS previously had its
            // own NSViewRepresentable overlay, whose CALayer.compositingFilter
            // approach is a silent no-op on iOS.
            OverlayPlayerStack(
                bottomPlayer: model.leftPlayer,
                topPlayer: model.rightPlayer,
                topOpacity: model.topLayerOpacity,
                blend: model.blend,
                // The right clip is the floating one — the pass registers it
                // onto the left — and it is the one on top here, so the
                // translation goes to `topPlayer`.
                translation: translation,
                // **The left side's, and only the left side's.** The stack
                // draws both clips into one rect and registers them with a
                // translation in normalised frame widths; two scales would
                // invalidate that registration and the shared-region mask
                // together. `OverlayPlayerStack.zoom` carries the whole
                // argument. Left because the pass makes the left clip the
                // reference, so it is the one the operator is framing.
                zoom: model.zoom(for: .left)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { stackMeasure }
            // Only installed while the stack is zoomed, matching
            // `ComparisonPane`: at 1× there is nothing to pan, and an
            // always-live drag recognizer over the video would be one more
            // thing between the operator and the chooser chips.
            .gesture(model.zoom(for: .left).isZoomed ? overlayPan : nil)
            .overlay(alignment: .bottomLeading) { overlayChoosers }
        }
    }

    /// How far the operator may zoom the overlay in right now, given how far
    /// apart the alignment is currently holding the two clips.
    ///
    /// `OverlayPlayerStack.maximumScale` carries the arithmetic and the reason
    /// there is a bound at all. Three things about *this* end of it:
    ///
    /// **The top clip's presentation size, matching the stack.**
    /// `OverlayPlayerStack.body` takes one video size for the whole geometry and
    /// takes it from `topPlayer`; the cap has to be computed against the same
    /// one or it would bound a picture nobody is drawing. The pair being two
    /// cameras at one resolution is the assumption underneath both.
    ///
    /// **Clamped on the way in rather than shown in the slider.** The chip
    /// should not offer a level it will not honour, and the honest fix is a
    /// range on `ZoomControl` — but that type is settled, shared with the viewer
    /// and both panes, and has no parameter for it, so this clamps the request
    /// instead. What the operator sees: dragging the slider past the cap moves
    /// the thumb and the level readout snaps back to the cap. Acceptable, and
    /// worse than a short slider would be.
    ///
    /// **Only what is asked for now, never what is already set.** A zoom set
    /// legally at 3× while the gate said identity is left at 3× when the gate
    /// engages and drops the cap under it, and left at 3× again when it
    /// disengages and the cap lifts. The alternative — re-clamping the stored
    /// zoom whenever `translation` changes — would take the operator's framing
    /// away mid-run, at a moment they did nothing to cause and while they are
    /// watching the picture rather than the chip. The cost is that the collapse
    /// is unreachable *through the chip* rather than unreachable outright; see
    /// the report's concern about a gate engaging under a zoom that was already
    /// high.
    private var overlayZoomCap: Double {
        OverlayPlayerStack.maximumScale(
            for: translation,
            in: stackSize,
            videoSize: model.rightPlayer.currentItem?.presentationSize ?? .zero
        )
    }

    /// Records the video area's size into `stackSize`. Behind the stack rather
    /// than around it; see `stackSize`.
    private var stackMeasure: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { stackSize = proxy.size }
                .onChange(of: proxy.size) { stackSize = $0 }
        }
    }

    /// A drag pans the whole stack, each step relative to the previous one:
    /// SwiftUI reports the translation from where the drag *began*, so feeding
    /// it straight to `panZoom` would re-apply the whole distance on every
    /// change and run away.
    ///
    /// **One drag for both clips, which is the same argument as one zoom.** The
    /// two are drawn into one rect and registered by a translation the pan does
    /// not touch; moving them by different amounts would take the pair apart.
    /// Panning the left side's zoom moves both by construction, because that is
    /// the single value the stack draws both clips with — there is no second
    /// mutation to keep in step. An operator who can reach 4× and not pan is
    /// stuck looking at the middle of the frame, which is the same dead end the
    /// viewer and the panes each have a drag for.
    ///
    /// `updating`, not `onChanged` with an `onEnded` reset; see
    /// `lastOverlayDrag`.
    private var overlayPan: some Gesture {
        DragGesture()
            .updating($lastOverlayDrag) { value, lastDrag, _ in
                let delta = CGSize(
                    width: value.translation.width - lastDrag.width,
                    height: value.translation.height - lastDrag.height
                )
                lastDrag = value.translation
                model.panZoom(by: delta, in: stackSize, side: .left)
            }
    }

    /// The overlay layout's clip choosers, which it had none of.
    ///
    /// Switching to Overlay with a side empty left no way to load it and no way
    /// to swap either clip: the branch above builds an `OverlayPlayerStack`,
    /// which contains no `chooseVideo` call and no filename menu, so the only
    /// routes to a clip lived in `ComparisonPane` and side-by-side was the only
    /// layout that had one. That is a feature deletion rather than a trade-off,
    /// and it is half of the reported "I don't see a way to select the
    /// comparison video anymore".
    ///
    /// **Here rather than inside `OverlayPlayerStack`.** That view is a pure
    /// renderer — its doc comment is entirely about blend modes and it takes
    /// two players, not a model — and keeping it that way is what lets the
    /// overlay compositing be tested without one.
    ///
    /// Bottom-leading, matching the pane chips, and clear of the status chip,
    /// which is top-*trailing* and a constant 340pt wide precisely so that "it
    /// cannot reach what is under it" is checkable; see `ComparisonStatusChip`,
    /// and the measured case where an unbounded version of it covered a pane's
    /// filename.
    ///
    /// Both clips are drawn into the same rect here, so unlike a pane chip
    /// neither has anything around it to say which clip it swaps — hence
    /// `sidedTitle`, which puts the side in the visible title too.
    ///
    /// **The zoom control is the third chip in this row, not a fourth corner.**
    /// A pane puts its zoom chip bottom-*trailing* because its filename menu
    /// already holds bottom-leading; here the choosers are the only thing on
    /// this edge, so the control joins them and the operator's clip controls
    /// stay in one place. The stack's other corners are not free in any case —
    /// `ComparisonView` overlays the status chip top-trailing and the iPad close
    /// button top-leading.
    ///
    /// One control, because there is one zoom: the whole reason
    /// `OverlayPlayerStack` takes a single `zoom` is that two would break the
    /// registration. That also disposes of the VoiceOver ambiguity
    /// `ComparisonPane.zoomChip` records for side-by-side, where two identical
    /// unnamed sets of zoom controls are audible; there is only one here.
    ///
    /// **`.frame(maxWidth: 220)` is load-bearing for the same reason it is on a
    /// pane's chip**: `ZoomControl`'s slider is greedy and would otherwise take
    /// the whole row and squeeze the two choosers out of it. The cap cannot
    /// squeeze below the control's intrinsic 224pt, so 224 is what renders.
    ///
    /// **Enabled as soon as *either* clip is loaded**, which is the faithful
    /// translation of a pane chip's rule — there, "a clip in this pane to
    /// magnify"; here, "a clip in this stack". Requiring both would leave a dead
    /// control over a picture that is plainly on screen, and the comparison
    /// window opens with both sides empty, so the disabled state is the ordinary
    /// one rather than an edge case.
    private var overlayChoosers: some View {
        HStack(spacing: 8) {
            ClipSourceMenu(
                model: model,
                side: .left,
                appearance: .overlayChip,
                title: ClipSourceMenu.sidedTitle(model, .left),
                prepare: prepare
            )
            ClipSourceMenu(
                model: model,
                side: .right,
                appearance: .overlayChip,
                title: ClipSourceMenu.sidedTitle(model, .right),
                prepare: prepare
            )
            ZoomControl(
                zoom: model.zoom(for: .left),
                isEnabled: ClipSourceMenu.isLoaded(model, .left) || ClipSourceMenu.isLoaded(model, .right),
                // Out-of-*range* requests — the minus button at 1.0×, the plus
                // button at 4.0× — still reach the model unfiltered on purpose:
                // `setScale` clamps to `VideoZoom.range` unconditionally, so the
                // range is enforced in exactly one place. The alignment cap is a
                // different bound and cannot be enforced there, because
                // `VideoZoom` knows nothing about the pair it is one half of.
                onScale: { model.setZoomScale(min($0, overlayZoomCap), in: stackSize, side: .left) },
                onReset: { model.resetZoom(side: .left) }
            )
            .frame(maxWidth: 220)
            .padding(.horizontal, 8)
            .darkFrostedBacking(in: Capsule())
        }
        .padding(8)
    }
}

/// The subject sheet as presented: `SubjectPickSheet` plus the two things it
/// deliberately does not own — a way out, and the run-start pass.
///
/// **The way out is not decoration.** `SubjectPickSheet` never calls
/// `dismiss()` and has no Close of its own in any of its four states, so
/// presenting it bare traps the operator: idle offers only "Start analysis",
/// analysing only "Cancel analysis" (which returns to idle, not out),
/// ready only "Use as subject", and failed only "Retry". Done sits in a header
/// above all four and is the only control that is present in every state.
struct SubjectSheet: View {
    @ObservedObject var session: SubjectSessionModel
    let clip: URL
    let sideTitle: String
    let phase: RunStartPhase
    let onConfirm: ([Int]) -> Void
    let onCancelRunStart: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch phase {
            case .notRunning:
                SubjectPickSheet(session: session, clip: clip, onConfirm: onConfirm)
            case .working:
                working
            case let .failed(message):
                runStartFailed(message)
            }
        }
        .frame(minWidth: 420, minHeight: 400)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sideTitle).font(.headline)
                Text(clip.lastPathComponent)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Done") { onDone() }
                // Escape closes the sheet — except while the analysis is
                // running, where `SubjectPickSheet`'s own Cancel already
                // claims `.cancelAction` and two controls cannot share it.
                // Done stays clickable in that state; only its shortcut steps
                // aside.
                .keyboardShortcut(isAnalysing ? nil : .cancelAction)
                .help("Done")
                .accessibilityLabel("Done")
                .accessibilityIdentifier("Done")
        }
        .padding(16)
    }

    private var isAnalysing: Bool {
        if case .analysing = session.state { return true }
        return false
    }

    /// The second pass, shown rather than hidden.
    ///
    /// Indeterminate, unlike the analysis: `SubjectAnalyzer.runStart` reports
    /// no progress, and a determinate bar that did not move would read as a
    /// hang. The wording says what is happening and roughly how long, which is
    /// the difference between "busy" and "broken".
    private var working: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            ProgressView()
            Text("Finding the run start")
                .font(.title3.bold())
            Text("Reading \(clip.lastPathComponent) a second time to measure when your athlete starts moving. About 20 seconds for a 45-second clip.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Cancel") { onCancelRunStart() }
                .keyboardShortcut(.cancelAction)
                .help("Cancel")
                .accessibilityLabel("Cancel run start")
                .accessibilityIdentifier("Cancel run start")
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A pick with no run start in it is not an error either — it usually
    /// means the wrong segments — so this reads like the sheet's own failed
    /// state and puts the operator back on the grid rather than out of the
    /// sheet.
    private func runStartFailed(_ message: String) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "figure.stand")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.title3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Back to segments") { onCancelRunStart() }
                .buttonStyle(.borderedProminent)
                .help("Back to segments")
                .accessibilityLabel("Back to segments")
                .accessibilityIdentifier("Back to segments")
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
