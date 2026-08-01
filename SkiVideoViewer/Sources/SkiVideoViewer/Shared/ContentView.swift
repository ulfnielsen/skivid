import SkiVideoCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: ViewerModel
    let initialDirectory: URL?
    @FocusState private var athleteSearchIsFocused: Bool
    @State private var isShowingGoogleDriveSheet = false
    /// The platform's Compare and Sort presentation. macOS opens windows; iPad
    /// uses a full-screen cover for Compare only. Each screen is gated by its
    /// own flag, so a platform that cannot present one hides just that button
    /// rather than offering a dead control.
    private let secondaryScreens: SecondaryScreenPresenter

    init(
        model: ViewerModel,
        initialDirectory: URL?,
        secondaryScreens: SecondaryScreenPresenter
    ) {
        _model = ObservedObject(wrappedValue: model)
        self.initialDirectory = initialDirectory
        self.secondaryScreens = secondaryScreens
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detail
        }
        #if os(macOS)
        .frame(minWidth: 980, minHeight: 640)
        // macOS resolves a toolbar on the split view into the window toolbar.
        // iPadOS drops it — see `detail`, which carries the same content there.
        .toolbar { toolbarContent }
        #endif
        .onAppear {
            model.start(initialDirectory: initialDirectory)
        }
        .onChange(of: model.selectedAthleteID) { newValue in
            model.selectAthlete(newValue)
        }
        .onChange(of: model.athleteQuery) { _ in
            model.selectFirstMatchingAthlete()
        }
        .sheet(isPresented: $isShowingGoogleDriveSheet) {
            GoogleDriveSheet(model: model, isPresented: $isShowingGoogleDriveSheet)
        }
        .alert(
            "Could Not Open Videos",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    /// One definition, two attachment points. A `.toolbar` on the
    /// `NavigationSplitView` populates the macOS window toolbar but renders
    /// nothing on iPadOS, where the items have to hang off the detail column's
    /// navigation bar instead. Verified on an iPad Pro 11-inch (M5) simulator:
    /// attached to the split view the bar shows only the title; attached to
    /// `detail` all three items appear. Sharing the builder keeps the two
    /// platforms from drifting apart.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if secondaryScreens.canPresentComparison {
            ToolbarItem {
                Button {
                    model.setKeyboardControlsEnabled(false)
                    secondaryScreens.presentComparison(
                        initialLeftVideo: model.currentPlaybackURL,
                        openLibrary: model.comparisonLibrary,
                        onClose: {
                            model.setKeyboardControlsEnabled(true)
                        }
                    )
                } label: {
                    Label("Compare Videos…", systemImage: "rectangle.split.2x1")
                }
            }
        }
        if secondaryScreens.canPresentSorting {
            ToolbarItem {
                Button {
                    model.setKeyboardControlsEnabled(false)
                    secondaryScreens.presentSorting(
                        openResizedLibrary: { outputDirectory in
                            model.openDirectory(outputDirectory)
                        },
                        onClose: {
                            model.setKeyboardControlsEnabled(true)
                        }
                    )
                } label: {
                    Label("Sort & Resize…", systemImage: "tag")
                }
            }
        }
        ToolbarItem {
            Button {
                isShowingGoogleDriveSheet = true
            } label: {
                Label("Open Google Drive…", systemImage: "externaldrive.connected.to.line.below")
            }
        }
        ToolbarItem {
            Button {
                athleteSearchIsFocused = true
            } label: {
                Label("Find Athlete", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: .command)
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Open Folder…") {
                Task { await model.chooseDirectory() }
            }
            .keyboardShortcut("o", modifiers: .command)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField("Jump to athlete…", text: $model.athleteQuery)
                    .textFieldStyle(.roundedBorder)
                    .focused($athleteSearchIsFocused)
                    .onSubmit {
                        model.selectFirstMatchingAthlete()
                    }
                if !model.athleteQuery.isEmpty {
                    Button {
                        model.athleteQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear athlete search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            List(model.filteredAthletes, selection: $model.selectedAthleteID) { athlete in
                HStack {
                    Text(athlete.name)
                    Spacer()
                    Text("\(athlete.videos.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .tag(athlete.id)
            }
        }
        .navigationTitle("Athletes")
        .overlay {
            if model.isConnectingToDrive {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(model.status)
                        .foregroundStyle(.secondary)
                }
                .padding()
            } else if model.athletes.isEmpty {
                emptyState(
                    title: "No Folder Open",
                    systemImage: "folder",
                    description: "Open an organized video directory."
                )
            }
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            if let athlete = model.currentAthlete {
                NativePlayerView(player: model.player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(athlete.name)
                                .font(.title2.bold())
                            Text(model.clipDescription)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(model.status)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button {
                            model.changeVideo(by: -1)
                        } label: {
                            Label("Previous", systemImage: "backward.end.fill")
                        }
                        Button {
                            model.togglePlayback()
                        } label: {
                            Label("Play / Pause", systemImage: "playpause.fill")
                        }
                        Button {
                            model.changeVideo(by: 1)
                        } label: {
                            Label("Next", systemImage: "forward.end.fill")
                        }
                        Spacer()
                        Text("↑/↓ clips  ·  Page Up/Down athletes  ·  ⌘F find athlete  ·  Space play/pause  ·  ←/→ tap, double-tap, or hold")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background(.bar)
            } else {
                emptyState(
                    title: "Choose a Video Folder",
                    systemImage: "play.rectangle",
                    description: "Athletes will appear in the sidebar."
                )
            }
        }
        .navigationTitle(model.directory?.lastPathComponent ?? (model.isUsingGoogleDrive ? "Google Drive" : "Ski Video Viewer"))
        // iPadOS renders a toolbar attached to a column, not one attached to
        // the split view, so the items hang off the detail column's navigation
        // bar here. macOS keeps its attachment in `body`; putting the macOS
        // toolbar here too would move its buttons within the window toolbar,
        // and no automated check in this repo would catch that.
        #if os(iOS)
        .toolbar { toolbarContent }
        #endif
    }

    private func emptyState(
        title: String,
        systemImage: String,
        description: String
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.bold())
            Text(description)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
