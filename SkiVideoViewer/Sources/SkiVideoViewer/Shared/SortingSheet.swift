import SkiVideoCore
import SwiftUI

struct SortingSheet: View {
    @StateObject private var model: SortingModel
    @Binding var isPresented: Bool
    let openResizedLibrary: (URL) -> Void
    @FocusState private var athleteFieldIsFocused: Bool

    /// `keepsSourceIntact` and `outputRoot` have no default here, deliberately:
    /// `outputRoot` on `SortingModel` is silently ignored whenever
    /// `keepsSourceIntact` is false, so a default for one and not the other
    /// would let a call site set just one and never notice the other was
    /// wrong. Requiring both forces every call site — the Mac window
    /// controller included — to state the pairing outright, even when the
    /// answer is `(false, SortingModel.defaultOutputRoot())`, same as before.
    init(
        isPresented: Binding<Bool>,
        openResizedLibrary: @escaping (URL) -> Void,
        mediaPipeline: MediaPipeline,
        input: PlaybackInputSource,
        folderPicker: FolderPicker,
        defaultNamesURL: URL?,
        keepsSourceIntact: Bool,
        outputRoot: URL
    ) {
        _isPresented = isPresented
        self.openResizedLibrary = openResizedLibrary
        // Built inside `StateObject`'s autoclosure so it only runs once, the
        // first time this view is materialised. `SortingSheet` is created
        // fresh from `.fullScreenCover(item:)`'s content closure on iPad,
        // which SwiftUI can re-evaluate more than once per presentation —
        // wrapped, a model, an `AVPlayer`, and a picker were being
        // constructed and immediately discarded on every such re-evaluation.
        _model = StateObject(wrappedValue: {
            let sortingModel = SortingModel(
                mediaPipeline: mediaPipeline,
                input: input,
                folderPicker: folderPicker,
                defaultNamesURL: defaultNamesURL
            )
            sortingModel.keepsSourceIntact = keepsSourceIntact
            sortingModel.outputRoot = outputRoot
            return sortingModel
        }())
    }

    var body: some View {
        Group {
            if model.isSorting {
                taggingView
            } else {
                setupView
            }
        }
        .frame(minWidth: 820, minHeight: 640)
        .onDisappear {
            model.stopPlayback()
        }
        .alert(
            "Sorting could not continue",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    /// What the setup screen tells the coach the session is about to do —
    /// which differs by `keepsSourceIntact`, because on iPad this is the one
    /// screen where a coach could reassure themselves the card is safe. The
    /// two variants must not drift from `SortingModel.beginSorting`'s actual
    /// choice of `ClipPublisher`.
    private var setupDescription: String {
        if model.keepsSourceIntact {
            return "Choose a flat folder of raw clips. The event date is taken from the first video file. The source is left exactly as it is — nothing there is moved, renamed, or edited. Each tagged clip is resized into a copy under organized_resize/<event>/<athlete> in this app's storage, and only that copy carries the athlete metadata. Only one resize runs at a time."
        }
        return "Choose a flat folder of raw clips. The event date is taken from the first video file. Each tagged clip moves into organized/<event>/<athlete>, gets its athlete metadata written, then is resized into the matching organized_resize folder. Only one resize runs at a time."
    }

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Sort & Resize Videos")
                .font(.title.bold())
            Text(setupDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 14) {
                GridRow {
                    Text("Raw clips")
                    HStack {
                        TextField("Choose a source folder…", text: $model.sourcePath)
                        Button("Choose…") {
                            Task { await model.chooseSourceDirectory() }
                        }
                    }
                }
                GridRow {
                    Text("Event date")
                    DatePicker("", selection: $model.eventDate, displayedComponents: .date)
                        .labelsHidden()
                }
                GridRow {
                    Text("Event title")
                    TextField("e.g. Neuss", text: $model.eventTitle)
                }
                GridRow {
                    Text("Athlete list")
                    HStack {
                        TextField("Optional athletes.txt", text: $model.namesPath)
                            .onSubmit { model.reloadNames() }
                        Button("Choose…") {
                            Task { await model.chooseNamesFile() }
                        }
                    }
                }
            }

            if !model.athleteNames.isEmpty {
                Text("\(model.athleteNames.count) athlete names loaded for autocomplete.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Start Tagging") { model.beginSorting() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28)
    }

    private var taggingView: some View {
        VStack(spacing: 0) {
            if model.currentVideo != nil {
                // A bare layer with no transport controls of its own, which
                // is what this preview needs and what the viewer now uses too.
                // The AVKit-backed view this replaced went when the viewer
                // gained zoom. No zoom is passed, so the layer fills the pane
                // exactly as it did before; the one visible change is gravity —
                // that view used `.resizeAspectFill` on macOS, this
                // letterboxes, which is the right default for judging a clip
                // you are about to tag.
                SinglePlayerView(player: model.player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    ProgressView(value: Double(model.completedResizes), total: Double(max(model.queuedResizes, 1)))
                        .frame(maxWidth: 380)
                    Text(model.status)
                        .foregroundStyle(.secondary)
                    if !model.failedResizes.isEmpty {
                        Text(model.failedResizes.joined(separator: "\n"))
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.leading)
                    }
                    if let output = model.completedOutputDirectory {
                        Button("Open Resized Library") {
                            openResizedLibrary(output)
                            isPresented = false
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(model.progressLabel)
                        .foregroundStyle(.secondary)
                    Spacer()
                    // The one always-available way out once tagging has
                    // started: `fullScreenCover` has no interactive
                    // dismissal of its own, and every other exit on this
                    // screen is conditional — "Open Resized Library" only
                    // appears once every resize has succeeded, so a single
                    // failed clip left nothing on screen to tap before this
                    // existed. Placed here, outside the `if`/`else` above, so
                    // it survives both while a clip is loaded and once
                    // tagging has finished.
                    Button("Close") { isPresented = false }
                }
                if model.currentVideo != nil {
                    HStack {
                        TextField("Type athlete name, then Return", text: $model.athleteQuery)
                            .textFieldStyle(.roundedBorder)
                            .focused($athleteFieldIsFocused)
                            .onSubmit { model.tagCurrentVideo() }
                        Button(model.resolvedAthlete.map { "Tag \($0)" } ?? "Tag & Next") {
                            model.tagCurrentVideo()
                        }
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.resolvedAthlete == nil)
                        Button("Skip") { model.skipCurrentVideo() }
                    }
                    if !model.matchingAthletes.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(model.matchingAthletes, id: \.self) { athlete in
                                Button(athlete) {
                                    model.selectSuggestedAthlete(athlete)
                                    athleteFieldIsFocused = true
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .lineLimit(1)
                    }
                    if let candidate = model.newAthleteCandidate {
                        Button("Add “\(candidate)” & Tag") {
                            model.addNewAthleteAndTag()
                        }
                    } else if model.resolvedAthlete == nil {
                        Text("Keep typing until exactly one athlete remains.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Previous Clip") { model.moveCurrentVideo(by: -1) }
                        Button("Next Clip") { model.moveCurrentVideo(by: 1) }
                        Spacer()
                        Text("←/→ seek 5s · Return tags · Resize queue: one at a time")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .background(.bar)
        }
        .onAppear { athleteFieldIsFocused = true }
        .onChange(of: model.currentVideo) { _ in
            athleteFieldIsFocused = true
        }
    }
}
