import SkiVideoCore
import SwiftUI

struct SortingSheet: View {
    @StateObject private var model: SortingModel
    @Binding var isPresented: Bool
    let openResizedLibrary: (URL) -> Void
    @FocusState private var athleteFieldIsFocused: Bool

    init(
        isPresented: Binding<Bool>,
        openResizedLibrary: @escaping (URL) -> Void,
        mediaPipeline: MediaPipeline,
        input: PlaybackInputSource,
        folderPicker: FolderPicker,
        defaultNamesURL: URL?
    ) {
        _isPresented = isPresented
        self.openResizedLibrary = openResizedLibrary
        _model = StateObject(
            wrappedValue: SortingModel(
                mediaPipeline: mediaPipeline,
                input: input,
                folderPicker: folderPicker,
                defaultNamesURL: defaultNamesURL
            )
        )
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

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Sort & Resize Videos")
                .font(.title.bold())
            Text("Choose a flat folder of raw clips. The event date is taken from the first video file. Each tagged clip moves into organized/<event>/<athlete>, gets its athlete metadata written, then is resized into the matching organized_resize folder. Only one resize runs at a time.")
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
                NativePlayerView(player: model.player)
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
                Text(model.progressLabel)
                    .foregroundStyle(.secondary)
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
