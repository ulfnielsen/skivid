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
    /// `libraryAthletes` has no default, unlike `SortingModel`'s own
    /// parameter of the same name: both call sites — `SortingWindowController`
    /// on macOS and `SkiVideoViewerApp_iOS`'s full-screen cover — have an open
    /// `ViewerModel` in scope and must state its `athletes` outright rather
    /// than silently falling back to an empty roster.
    init(
        isPresented: Binding<Bool>,
        openResizedLibrary: @escaping (URL) -> Void,
        mediaPipeline: MediaPipeline,
        input: PlaybackInputSource,
        folderPicker: FolderPicker,
        defaultNamesURL: URL?,
        libraryAthletes: [AthleteGroup],
        keepsSourceIntact: Bool,
        outputRoot: URL,
        photosImporter: PhotosImporting? = nil
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
                defaultNamesURL: defaultNamesURL,
                libraryAthletes: libraryAthletes,
                photosImporter: photosImporter
            )
            sortingModel.keepsSourceIntact = keepsSourceIntact
            sortingModel.outputRoot = outputRoot
            return sortingModel
        }())
    }

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    private var isCompact: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if model.isSorting {
                taggingView
            } else {
                setupView
            }
        }
        // 820 is the width the two-column setup grid and the tagging row need
        // side by side. A phone has 402 and cannot be talked into more, so at
        // compact the screen sizes itself and the layouts below stack instead.
        .frame(minWidth: isCompact ? nil : 820, minHeight: isCompact ? nil : 640)
        .onDisappear {
            model.stopPlayback()
            model.discardPhotosScratchIfIdle()
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
            return "Choose a flat folder of raw clips. The event date is taken from the first video file. The source is left exactly as it is — nothing there is moved, renamed, or edited. Each tagged clip is resized into a copy under Sorted/<event>/<athlete> in this app's Documents, and only that copy carries the athlete metadata. Only one resize runs at a time."
        }
        return "Choose a flat folder of raw clips. The event date is taken from the first video file. Each tagged clip moves into organized/<event>/<athlete>, gets its athlete metadata written, then is resized into the matching organized_resize folder. Only one resize runs at a time."
    }

    @ViewBuilder
    private var setupView: some View {
        if isCompact {
            // Scrolling, with the actions riding above the keyboard.
            //
            // Both problems were the same problem: a fixed column as tall as
            // its content. The title sat under the status bar because nothing
            // was insetting it, and Cancel and Start Tagging sat under the
            // keyboard the moment the coach typed an event title — a tap aimed
            // at Start Tagging landed on the letter O. A `safeAreaInset` bar is
            // moved up by the keyboard; a `VStack` at the bottom of a fixed
            // frame is not.
            ScrollView {
                setupForm.padding(20)
            }
            .safeAreaInset(edge: .bottom) {
                setupActions
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .background(.bar)
            }
        } else {
            VStack(alignment: .leading, spacing: 20) {
                setupForm
                Spacer()
                setupActions
            }
            .padding(28)
        }
    }

    private var setupForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Sort & Resize Videos")
                .font(.title.bold())
            Text(setupDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isCompact {
                // Label over control. A label column costs about a third of a
                // phone's width and leaves the path field too narrow to show
                // the end of a path, which is the part that says which card.
                VStack(alignment: .leading, spacing: 14) {
                    stacked("Raw clips") { rawClipsField }
                    stacked("Event date") { eventDateField }
                    stacked("Event title") { eventTitleField }
                    stacked("Athlete list") { athleteListField }
                }
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 14) {
                    GridRow {
                        Text("Raw clips")
                        rawClipsField
                    }
                    GridRow {
                        Text("Event date")
                        eventDateField
                    }
                    GridRow {
                        Text("Event title")
                        eventTitleField
                    }
                    GridRow {
                        Text("Athlete list")
                        athleteListField
                    }
                }
            }

            if !model.athleteNames.isEmpty {
                Text("\(model.athleteNames.count) athlete "
                     + "\(model.athleteNames.count == 1 ? "name" : "names") loaded for autocomplete.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var setupActions: some View {
        HStack {
            Spacer()
            Button("Cancel") { isPresented = false }
                // Disabled until the sort can actually start. `beginSorting`
                // needs a title as much as a source — `eventFolder(date:title:)`
                // throws without one — but only the source gated this button,
                // so the coach got an enabled control that answered with
                // "Sorting could not continue. Enter an event title". A button
                // that refuses is worse than one that waits.
                Button("Start Tagging") { model.beginSorting() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStartSorting)
        }
    }

    /// A label above its control, for the width where a label beside it does
    /// not fit.
    private func stacked<Content: View>(_ label: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            content()
        }
    }

    /// What `beginSorting` needs before it will run: somewhere to read, and a
    /// name for what is being read. Kept beside the button that asks for them.
    private var canStartSorting: Bool {
        !model.sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.eventTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The tag button, which both layouts need and neither should define.
    private var tagButton: some View {
        Button(model.resolvedAthlete.map { "Tag \($0)" } ?? "Tag & Next") {
            model.tagCurrentVideo()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(model.resolvedAthlete == nil)
    }

    private var rawClipsField: some View {
        HStack {
            TextField("Choose a source folder…", text: $model.sourcePath)
            Button("Choose…") {
                Task { await model.chooseSourceDirectory() }
            }
            .accessibilityIdentifier("sorting.chooseSource")
            if model.canChooseFromPhotos {
                Button("From Photos…") {
                    Task { await model.chooseFromPhotos() }
                }
                .accessibilityIdentifier("sorting.chooseFromPhotos")
            }
        }
    }

    private var eventDateField: some View {
        DatePicker("", selection: $model.eventDate, displayedComponents: .date)
            .labelsHidden()
    }

    private var eventTitleField: some View {
        TextField("e.g. Neuss", text: $model.eventTitle)
    }

    private var athleteListField: some View {
        HStack {
            TextField("Optional athletes.txt", text: $model.namesPath)
                .onSubmit { model.reloadNames() }
            Button("Choose…") {
                Task { await model.chooseNamesFile() }
            }
            .accessibilityIdentifier("sorting.chooseNames")
        }
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
                    // The field and its two buttons want about 520pt together.
                    // On a phone the field is a row of its own and the buttons
                    // sit under it, rather than all three sharing 402 and the
                    // name being typed into a sliver.
                    if isCompact {
                        TextField("Type athlete name", text: $model.athleteQuery)
                            .textFieldStyle(.roundedBorder)
                            .focused($athleteFieldIsFocused)
                            .onSubmit { model.tagCurrentVideo() }
                        HStack {
                            tagButton
                            Button("Skip") { model.skipCurrentVideo() }
                        }
                    } else {
                        HStack {
                            TextField("Type athlete name, then Return", text: $model.athleteQuery)
                                .textFieldStyle(.roundedBorder)
                                .focused($athleteFieldIsFocused)
                                .onSubmit { model.tagCurrentVideo() }
                            tagButton
                            Button("Skip") { model.skipCurrentVideo() }
                        }
                    }
                    if !model.matchingAthletes.isEmpty {
                        // Scrolls rather than clips. A club of forty runs off
                        // any width, and `lineLimit(1)` on a row of buttons
                        // hides the ones past the edge instead of reaching
                        // them — on a Mac too, so this is not a phone fix.
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(model.matchingAthletes, id: \.self) { athlete in
                                    Button(athlete) {
                                        model.selectSuggestedAthlete(athlete)
                                        athleteFieldIsFocused = true
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 2)
                        }
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
                        // The keyboard half of this names keys a phone has not
                        // got. What is left is the part that is true whatever
                        // is plugged in, and the part a coach watching a queue
                        // of resizes actually needs.
                        Text(isCompact
                             ? "Resize queue: one at a time"
                             : "←/→ seek 5s · Return tags · Resize queue: one at a time")
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
