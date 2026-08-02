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
    let closeWindow: () -> Void

    /// Non-nil while the subject sheet is up, and the side it is up for.
    @State private var picking: PickingSide?
    @State private var runStart: RunStartPhase = .notRunning
    @State private var runStartTask: Task<Void, Never>?
    @State private var alignmentTask: Task<Void, Never>?
    /// A sidecar that could not be written. Surfaced once, plainly; the pick
    /// itself is kept and the sync still applies.
    @State private var sidecarWarning: String?

    init(
        initialLeftVideo: URL?,
        openLibrary: [ComparisonAthleteChoice],
        input: PlaybackInputSource,
        folderPicker: FolderPicker,
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
                    canSyncFromDetectedStarts: detectedStarts != nil,
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
        .sheet(item: $picking) { picking in
            SubjectSheet(
                session: subjects.session(for: picking.side),
                clip: picking.clip,
                sideTitle: picking.side == .left ? "Left clip" : "Right clip",
                phase: runStart,
                onConfirm: { confirmSubject(side: picking.side, clip: picking.clip, segmentIDs: $0) },
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
        let starts = detectedStarts
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
        clip(for: .left) != nil && clip(for: .right) != nil && detectedStarts != nil
    }

    private func loadStoredAlignment() {
        guard
            let left = clip(for: .left),
            let right = clip(for: .right),
            let starts = detectedStarts
        else {
            // Not merely "leave it alone": a track loaded for the previous pair
            // would go on answering for a comparison it does not describe.
            alignment.reset()
            return
        }
        alignment.loadStored(
            left: left, right: right,
            leftStart: starts.left, rightStart: starts.right
        )
    }

    private func computeAlignment() {
        guard
            let left = clip(for: .left),
            let right = clip(for: .right),
            let starts = detectedStarts
        else { return }
        alignmentTask?.cancel()
        // `@MainActor` explicitly, as `confirmSubject` does and for the same
        // measured reason: the task body starts on the main thread, the pass
        // itself runs off it, and the state writes land back on the actor that
        // owns them.
        alignmentTask = Task { @MainActor in
            await alignment.compute(
                left: left, right: right,
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
        guard let starts = detectedStarts else { return nil }
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
    private var detectedStarts: (left: TimeInterval, right: TimeInterval)? {
        guard
            let left = subjects.left.pickedSubject?.runStart.syncTime,
            let right = subjects.right.pickedSubject?.runStart.syncTime
        else { return nil }
        return (left, right)
    }

    private func loadStoredSubject(_ side: ComparisonSide) {
        guard let clip = clip(for: side) else { return }
        subjects.session(for: side).loadStored(for: clip)
    }

    private func openSubjectSheet(_ side: ComparisonSide) {
        guard let clip = clip(for: side) else { return }
        runStart = .notRunning
        picking = PickingSide(side: side, clip: clip)
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

    /// The half of the interaction the sheet deliberately does not own: a
    /// second full read of the clip to find where the picked subject's run
    /// begins.
    ///
    /// The sheet stays up in `.working` for all of it. That is the point —
    /// `onConfirm` returns instantly and this takes about as long as the
    /// analysis did, so dismissing here would leave the operator looking at a
    /// window that does nothing for twenty seconds.
    private func confirmSubject(side: ComparisonSide, clip: URL, segmentIDs: [Int]) {
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
        runStart = .working
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
                let outcome = try await SubjectAnalyzer.runStart(
                    clip: clip, analysis: analysis, segmentIDs: segmentIDs
                )
                if Task.isCancelled { return }
                guard let stored = Self.stored(outcome) else {
                    runStart = .failed(Self.message(for: outcome))
                    return
                }
                do {
                    try session.confirm(segmentIDs: segmentIDs, runStart: stored, for: clip)
                } catch {
                    // Surfaced once and moved past: the pick is in memory and
                    // good for this session, and refusing the sync because a
                    // sidecar could not be written would throw away twenty
                    // seconds of the operator's work over a file permission.
                    sidecarWarning = "\(clip.lastPathComponent): \(error). The pick still applies for this session."
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
        guard let starts = detectedStarts else { return }
        model.applySync(left: starts.left, right: starts.right)
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
        ComparisonVideos(model: model, translation: alignmentTranslation)
    }

    /// What `.sheet(item:)` needs: the side being picked, plus the clip it was
    /// opened for. Carrying the clip means the sheet cannot be re-pointed at a
    /// different file half way through by a load on that side.
    struct PickingSide: Identifiable {
        let side: ComparisonSide
        let clip: URL
        var id: String { (side == .left ? "left:" : "right:") + clip.path }
    }

    private var closeButton: some View {
        Button {
            closeWindow()
        } label: {
            Image(systemName: "xmark")
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: Circle())
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

    @ViewBuilder
    var body: some View {
        switch model.layout {
        case .sideBySide:
            HStack(spacing: 1) {
                ComparisonPane(model: model, side: .left)
                // Constrained deliberately: a bare `Divider()` inside an
                // `HStack` is vertically greedy and squeezes the video.
                Divider().frame(width: 1)
                ComparisonPane(model: model, side: .right)
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
                translation: translation
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomLeading) { overlayChoosers }
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
    private var overlayChoosers: some View {
        HStack(spacing: 8) {
            ClipSourceMenu(
                model: model,
                side: .left,
                appearance: .overlayChip,
                title: ClipSourceMenu.sidedTitle(model, .left)
            )
            ClipSourceMenu(
                model: model,
                side: .right,
                appearance: .overlayChip,
                title: ClipSourceMenu.sidedTitle(model, .right)
            )
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
