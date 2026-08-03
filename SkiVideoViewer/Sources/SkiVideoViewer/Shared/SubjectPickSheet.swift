import CoreGraphics
import SkiVideoCore
import SwiftUI

/// "Which of these people is my athlete?" — the four states of asking that
/// question, and nothing else.
///
/// The sheet is a view over `SubjectSessionModel.State`: it starts the
/// analysis, shows its progress, offers the segments it found, and hands the
/// picked ids back through `onConfirm`. It deliberately does **not** compute
/// the run start from that pick — that is a second, equally long pass over the
/// clip, and putting it here would make this view own a job it cannot report
/// on. Task 4's caller owns it.
///
/// Split into three view types rather than one, for the same reason
/// `SharedControlsWiringTests` splits its wiring into two links: a test that
/// can only reach the whole sheet cannot set up a selection to confirm
/// (`SubjectSessionModel.state` is `private(set)`, and reaching `.ready` means
/// running a real 20-second analysis). `SubjectPickList` takes the pick model
/// it operates on, so a test can hand it one; `ReadySection` is the two-line
/// adapter that owns that model's lifetime for the real sheet.
struct SubjectPickSheet: View {
    @ObservedObject var session: SubjectSessionModel
    let clip: URL
    let onConfirm: ([Int]) -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch session.state {
            case .idle:
                idle
            case let .analysing(progress):
                analysing(progress)
            case let .ready(analysis):
                // Keyed on the segment ids so a re-analysis starts the
                // operator on a clean selection rather than carrying ids over
                // from a list that no longer contains them.
                ReadySection(
                    segments: analysis.segments,
                    // Seeded from the stored pick, so a clip whose sidecar was
                    // read back opens showing the operator's own selection
                    // rather than an empty grid that reads as "the pick was
                    // lost". `SubjectPickModel` filters the ids against the
                    // segments it is given, so a stale one changes nothing.
                    selected: session.pickedSubject?.segmentIDs ?? [],
                    // The whole stored pick, not just its ids: the ready state
                    // is what the operator is looking at when they re-check a
                    // pick, so it is where the detected start and their own
                    // correction can be put side by side.
                    stored: session.pickedSubject,
                    clip: clip,
                    isStale: session.isStale,
                    onConfirm: onConfirm
                )
                .id(analysis.segments.map(\.id))
            case let .failed(message):
                failed(message)
            }
        }
        // Narrow enough for an 11-inch iPad in portrait (768pt) with room to
        // spare, so the sheet never has to shrink its controls to fit. The
        // grid below is adaptive, so extra width becomes more columns.
        .frame(minWidth: 380, minHeight: 340)
    }

    // MARK: - idle

    private var idle: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "figure.skiing.downhill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Find the athlete in this clip")
                .font(.title3.bold())
            Text("Every person in \(clip.lastPathComponent) is detected first, then you pick which one is yours. About 20 seconds for a 45-second clip.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            // **Not "Find subject".** That identifier belongs to the control
            // bar's button, which is what opened this sheet; while the sheet is
            // up both would be in the tree and a UI query for it would match
            // ambiguously. It reads better as "Start analysis" here in any
            // case: by this point the operator has already asked to find a
            // subject, and this button is the long job that follows.
            Button("Start analysis") {
                Task { await session.analyse(clip: clip) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .help("Start analysis")
            .accessibilityLabel("Start analysis")
            .accessibilityIdentifier("Start analysis")
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - analysing

    /// Determinate, and escapable. Both are requirements rather than polish:
    /// the job takes about 16 seconds on real footage, and a spinner with no
    /// Cancel gives the operator nothing to read and nothing to do for all of
    /// it. `SubjectAnalyzer` checks cancellation between frames, so Cancel
    /// lands within one frame.
    private func analysing(_ progress: Double) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Text("Looking for people in \(clip.lastPathComponent)")
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            ProgressView(value: progress)
                .frame(maxWidth: 380)
            Text("\(Int((progress * 100).rounded()))% — about 20 seconds for a 45-second clip")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Cancel analysis") {
                session.cancel()
            }
            .keyboardShortcut(.cancelAction)
            .help("Cancel analysis")
            .accessibilityLabel("Cancel analysis")
            .accessibilityIdentifier("Cancel analysis")
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - failed

    /// Finding nobody is an ordinary outcome — a clip of an empty slope, a
    /// skier too small to detect — not a crash, so this reads as a plain
    /// statement with a way to try again, with nothing red about it.
    private func failed(_ message: String) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(Self.readable(message))
                .font(.title3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry") {
                Task { await session.analyse(clip: clip) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .help("Retry")
            .accessibilityLabel("Retry")
            .accessibilityIdentifier("Retry")
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `SubjectSessionModel.State.failed` carries only a string — the
    /// `AnalysisError`'s own description, which names the file and reads like
    /// a log line. These two are the whole of `AnalysisError`, restated for
    /// someone who is looking at the clip in question and does not need it
    /// named back at them. Anything else is shown as it arrives rather than
    /// swallowed.
    static func readable(_ message: String) -> String {
        if message.hasPrefix("no people were detected") {
            return "No people were detected in this clip."
        }
        if message.hasPrefix("no frames could be read") {
            return "No frames could be read from this clip."
        }
        return message
    }
}

/// Owns the pick model's lifetime for one analysis.
///
/// `SubjectPickModel.segments` is a `let`, so the model cannot be updated in
/// place when a new analysis arrives — it has to be rebuilt, which is what
/// `SubjectPickSheet`'s `.id(...)` on this view does.
///
/// `selected` seeds that model once, when this view is first created, because
/// `@StateObject`'s `wrappedValue` is evaluated only then. That is the wanted
/// behaviour: the stored pick is a starting point, and every tap afterwards
/// belongs to the live model, so a re-render cannot undo the operator's edits
/// by re-seeding from the sidecar.
private struct ReadySection: View {
    @StateObject private var pick: SubjectPickModel
    private let stored: SubjectPick?
    private let clip: URL
    private let isStale: Bool
    private let onConfirm: ([Int]) -> Void

    init(
        segments: [AnalysedSegment], selected: [Int], stored: SubjectPick?,
        clip: URL, isStale: Bool, onConfirm: @escaping ([Int]) -> Void
    ) {
        _pick = StateObject(wrappedValue: SubjectPickModel(segments: segments, selected: selected))
        self.stored = stored
        self.clip = clip
        self.isStale = isStale
        self.onConfirm = onConfirm
    }

    var body: some View {
        SubjectPickList(pick: pick, stored: stored, clip: clip, isStale: isStale, onConfirm: onConfirm)
    }
}

/// The segments, and the one decision to make about them.
///
/// Takes its model rather than making one so that a test can drive a known
/// selection through the real controls — see `SubjectPickSheet`'s note on why
/// the sheet is split here.
struct SubjectPickList: View {
    @ObservedObject var pick: SubjectPickModel
    /// The pick already on disk for this clip, when there is one. Read only for
    /// the caption below the grid; the selection is seeded separately, because
    /// the operator's edits belong to `pick` from the first tap onward.
    var stored: SubjectPick? = nil
    let clip: URL
    var isStale: Bool = false
    let onConfirm: ([Int]) -> Void

    /// Rendered strips, per segment id. Cached here rather than recomputed:
    /// `SegmentThumbnails.strip` does five frame seeks, and `body` runs again
    /// on every tap.
    @State private var strips: [Int: CGImage] = [:]

    var body: some View {
        VStack(spacing: 0) {
            if isStale {
                staleNotice
            }
            ScrollView {
                // Adaptive with a minimum, so one column on an iPad in
                // portrait becomes three or four on a Mac window, without any
                // width being a special case.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .top)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(pick.segments) { segment in
                        SegmentCard(
                            segment: segment,
                            isSelected: pick.isSelected(segment),
                            exclusionReason: pick.exclusionReason(for: segment),
                            strip: strips[segment.id]
                        ) {
                            pick.toggle(segment.id)
                        }
                    }
                }
                .padding(16)
            }
            footer
        }
        // Keyed on the segment ids, not on the selection: a tap must not
        // restart five frame seeks per card. `.task` is cancelled and
        // restarted only when the list itself changes.
        .task(id: pick.segments.map(\.id)) {
            await renderStrips()
        }
    }

    private var staleNotice: some View {
        Text("This analysis was made with different settings than the app uses now.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.quaternary)
    }

    /// Wraps to two lines rather than shrinking, the discipline
    /// `ComparisonControlBar` documents: the button keeps its size at every
    /// width, and the summary moves above it when there is no room beside it.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    summary
                    Spacer(minLength: 8)
                    confirmButton
                }
                VStack(alignment: .leading, spacing: 10) {
                    summary
                    confirmButton
                }
            }
            if let caption = Self.storedStartCaption(for: stored) {
                storedStart(caption)
            }
        }
        .padding(16)
        .background(.bar)
    }

    private var summary: some View {
        Text(summaryText)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A caption in the sheet, deliberately **not** in `ComparisonStatusChip`.
    /// The chip already distinguishes "Synced from corrected starts" from
    /// "Synced from detected starts", it is a constant 340pt clipped to two
    /// lines, and `ComparisonLayoutMeasurementTests` pins its longest reachable
    /// status at 83 characters. This adds the magnitude, which is the part that
    /// says something about the detector, where the operator can act on it.
    private func storedStart(_ caption: String) -> some View {
        Text(caption)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("Stored run start")
    }

    /// The stored run start, and how far the operator moved it.
    ///
    /// Nil with no stored pick: there is nothing measured to report, and a
    /// caption saying "0.0s" would be a claim about the detector rather than the
    /// absence of one.
    ///
    /// **`.alreadyRunning` is not called a detection.** `StoredRunStart`'s own
    /// note is explicit that "the subject was never demonstrably still" is not a
    /// measured start and the UI must not present it as one — so it reads
    /// "already running at", and the uncorrected form does not use the word
    /// "detected" at all.
    ///
    /// One decimal throughout, matching the precision the operator corrects at:
    /// the clip is analysed at 25fps, so a run start is only ever known to 40ms,
    /// and printing three decimals would claim a precision the pass does not
    /// have. The difference is signed, because "the detector was seventeen
    /// seconds early" and "seventeen seconds late" are opposite facts about it
    /// and this caption exists to accumulate exactly that evidence.
    ///
    /// The difference is taken between the **rounded** values, not rounded after
    /// subtracting, so the three numbers on the line add up. Measured, not
    /// supposed: C0094's own `18.29 - 0.64` is 17.649999999999999 as a `Double`,
    /// which `%.1f` prints as 17.6 — a caption reading "18.3s … 0.6s … +17.6s"
    /// on a line whose whole purpose is evidence about the detector.
    static func storedStartCaption(for pick: SubjectPick?) -> String? {
        guard let pick else { return nil }
        let detected = tenths(pick.runStart.syncTime)
        let measurement: String
        switch pick.runStart {
        case .started:
            measurement = "detected \(seconds(detected))"
        case .alreadyRunning:
            measurement = "already running at \(seconds(detected))"
        }
        guard let correction = pick.correctedRunStart else {
            switch pick.runStart {
            case .started: return "Detected run start \(seconds(detected))"
            case .alreadyRunning: return "Already running at \(seconds(detected))"
            }
        }
        let corrected = tenths(correction)
        let difference = String(format: "%+.1f", corrected - detected)
        return "Run start \(seconds(corrected)) — \(measurement), corrected by \(difference)s"
    }

    private static func tenths(_ time: TimeInterval) -> Double {
        (time * 10).rounded() / 10
    }

    private static func seconds(_ time: TimeInterval) -> String {
        String(format: "%.1fs", time)
    }

    private var summaryText: String {
        let picked = pick.selectedInTimeOrder
        guard !picked.isEmpty else {
            return "Tap every segment that is your athlete."
        }
        let names = picked.map(String.init).joined(separator: ", ")
        return picked.count == 1
            ? "Segment \(names) selected."
            : "Segments \(names) selected, in time order."
    }

    private var confirmButton: some View {
        Button("Use as subject") {
            onConfirm(pick.selectedInTimeOrder)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        // Nothing to confirm with an empty selection: the caller would get an
        // empty id list and compute a run start from no samples at all.
        .disabled(pick.selected.isEmpty)
        .help("Use as subject")
        .accessibilityLabel("Use as subject")
        .accessibilityIdentifier("Use as subject")
    }

    /// Draws each missing strip on a background task, publishing them one at a
    /// time so the first cards fill in while the last are still being drawn.
    ///
    /// Off the main thread is the point: five seeks per segment across a dozen
    /// segments is seconds of work, and doing it inside `body` would freeze the
    /// sheet for all of it. A segment whose strip fails to draw keeps its
    /// placeholder — a missing picture is not a reason to fail the pick, since
    /// the range and the sample count are still there to judge it by.
    private func renderStrips() async {
        for segment in pick.segments {
            if strips[segment.id] != nil { continue }
            if Task.isCancelled { return }
            let clip = clip
            let rendered = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                try? SegmentThumbnails.strip(clip: clip, segment: segment)
            }.value
            if Task.isCancelled { return }
            if let rendered {
                strips[segment.id] = rendered
            }
        }
    }
}
