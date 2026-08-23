import SkiVideoCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: ViewerModel
    let initialDirectory: URL?
    @FocusState private var athleteSearchIsFocused: Bool
    @State private var isShowingGoogleDriveSheet = false

    /// Which sidebar sections the coach has folded away.
    ///
    /// Collapsed rather than expanded ids, so a library opens fully visible
    /// and a new event that appears after a refresh is never hidden by a
    /// preference the coach never expressed.
    ///
    /// Section ids differ between the two groupings — `LibraryGrouping` tags
    /// them by dimension — so flipping the picker leaves these stale entries
    /// matching nothing, and each view keeps its own folds without either
    /// having to be reset.
    ///
    /// SwiftUI's own `Section(isExpanded:)` would give this for free with
    /// platform-standard animation, but it needs macOS 14 and this package
    /// targets 13 — not worth cutting a coach on Ventura loose over a
    /// chevron.
    @State private var collapsedSections: Set<String> = []
    /// Backs the Google Drive sheet's `chooseRoot`. A `@State`, not a plain
    /// `let`: the actor must survive `ContentView`'s `body` re-evaluating —
    /// which happens on every `ViewerModel` publish, including the playback
    /// clock — or a download in flight would lose its cache the moment a
    /// clip started playing.
    @State private var clipCache = ContentView.makeClipCache()
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

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// True where there is only ever one column on screen. macOS has no size
    /// class and never answers yes, which is what keeps every compact branch
    /// below out of the Mac's way.
    @Environment(\.isShortOnHeight) private var isShortOnHeight

    private var isCompact: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    /// Where a phone is in its three-screen stack. A split view needs no such
    /// state — both columns are always on screen — so this is empty and unread
    /// on a Mac or an iPad.
    enum PhoneScreen: Hashable {
        case athletes
        case viewer
    }
    @State private var phonePath: [PhoneScreen] = []

    var body: some View {
        Group {
            if isCompact {
                phoneStack
            } else {
                splitView
            }
        }
        .onAppear {
            model.start(initialDirectory: initialDirectory)
        }
        .onChange(of: model.selectedAthleteID) { newValue in
            model.selectAthlete(newValue)
        }
        .onChange(of: model.athleteQuery) { _ in
            model.selectFirstMatchingAthlete()
        }
        // The search field auto-selects as you type, so the operator never has
        // to press Return and focus would otherwise sit in the field forever —
        // swallowing Space, the play/pause key, as a literal space. Starting
        // playback is the operator saying they have moved on to watching, so
        // the field gives the focus up then.
        //
        // On `true` only. Becoming false must leave focus alone: pausing in
        // order to type is exactly when the operator wants the field, and
        // reacting to every change would fight them for it.
        .onChange(of: model.isPlaying) { isPlaying in
            if isPlaying {
                athleteSearchIsFocused = false
            }
        }
        // A library opening is the phone's cue to move on; the split view
        // needs no equivalent because its second column was already there.
        // Only from the root, so reopening the same library from Back does not
        // stack a second copy of the athlete list on top of the first.
        .onChange(of: model.openLibraryID) { id in
            if isCompact, id != nil, phonePath.isEmpty {
                phonePath.append(.athletes)
            }
        }
        .sheet(isPresented: $isShowingGoogleDriveSheet) {
            GoogleDriveSheet(model: model, isPresented: $isShowingGoogleDriveSheet, cache: clipCache)
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

    /// Two columns, and the platforms that have room for them.
    private var splitView: some View {
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
    }

    /// One column, three deep: the libraries you have, the athletes in the one
    /// you opened, the clip you picked.
    ///
    /// A `NavigationSplitView` on a phone collapses to its sidebar, which put
    /// the libraries list — the only way to open anything — in the detail
    /// column that nothing could push. The app launched, showed "Athletes",
    /// and offered no way in. A stack says the same three things in the order a
    /// phone can actually show them.
    private var phoneStack: some View {
        NavigationStack(path: $phonePath) {
            LibrariesView(
                model: model,
                cache: clipCache,
                makeProvider: GoogleDriveSheet.makeConfiguredProvider,
                onConnectDrive: { isShowingGoogleDriveSheet = true }
            )
            .navigationDestination(for: PhoneScreen.self) { screen in
                switch screen {
                case .athletes: sidebar
                case .viewer:   detail
                }
            }
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
        // Absent on a phone rather than present and broken. `ComparisonView`
        // declares `.frame(minWidth: 1000)` and an iPhone offers 402, so the
        // button would open a screen two and a half times too wide for it.
        //
        // Gated here and not in `IOSSecondaryScreenPresenter`, which answers
        // "can this platform present a second screen at all" — still true of a
        // phone. The reason to hide the button is width, and width belongs to
        // the view.
        if secondaryScreens.canPresentComparison, !isCompact {
            ToolbarItem {
                Button {
                    model.setKeyboardControlsEnabled(false)
                    secondaryScreens.presentComparison(
                        initialLeftVideo: model.currentPlaybackURL,
                        openLibrary: model.comparisonLibrary,
                        // The only place `ViewerModel` is captured for the
                        // comparison screen's benefit — everything downstream
                        // of `presentComparison` (the window controller, the
                        // full-screen cover, `ComparisonView`, `ComparisonPane`,
                        // `ClipSourceMenu`) only ever sees this closure, never
                        // `model` itself.
                        prepare: ClipPreparer { choice in await model.prepareClip(choice) },
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
                        libraryAthletes: model.athletes,
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
                // "Connect" rather than "Open": this is the rare, heavyweight
                // trip through Google's consent screen and a drive listing.
                // Opening one already connected is a row on the landing list.
                Label("Connect Google Drive…", systemImage: "externaldrive.connected.to.line.below")
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
            Button("Add Folder…") {
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
                        // Return is optional here — the `athleteQuery` change
                        // above already selects as you type — but an operator
                        // who presses it means "I am done searching", and
                        // honouring that costs nothing.
                        athleteSearchIsFocused = false
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

            // "How is Ada progressing?" and "who did what at Neuss?" are both
            // legitimate readings of one library — a preference, not a
            // correction — so this is a control the coach can flip at any
            // time, not a setting buried in a menu.
            Picker("Group sidebar by", selection: $model.sidebarGrouping) {
                Text("By Event").tag(SidebarGrouping.event)
                Text("By Athlete").tag(SidebarGrouping.athlete)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)

            List(selection: $model.selectedAthleteID) {
                ForEach(model.events) { event in
                    // A `Section` without a header renders as a plain run of
                    // rows, so a library with no event folders looks exactly as
                    // it did before events existed.
                    Section {
                        ForEach(collapsedSections.contains(event.id) ? [] : event.athletes) { athlete in
                            athleteRow(athlete)
                        }
                    } header: {
                        if let name = event.name {
                            // Styled rather than left to the platform default,
                            // which is small, grey and low-contrast — fine for
                            // a header that merely labels a group, wrong for
                            // one carrying the name a coach navigates by. It
                            // now reads as larger than the rows beneath it.
                            //
                            // `.textCase(nil)` because iOS uppercases section
                            // headers by default, which mangles a
                            // date-prefixed folder like `2026-08-08_Wittenburg`
                            // — and the date is the part that makes one
                            // session tell itself apart from another.
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    if collapsedSections.contains(event.id) {
                                        collapsedSections.remove(event.id)
                                    } else {
                                        collapsedSections.insert(event.id)
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.right")
                                        // Rotated rather than swapped for a
                                        // second glyph, so the turn animates
                                        // and reads as one control changing
                                        // state instead of two icons.
                                        .rotationEffect(
                                            .degrees(collapsedSections.contains(event.id) ? 0 : 90)
                                        )
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(name)
                                        .font(.title3.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .textCase(nil)
                                    Spacer()
                                }
                                // The whole row is the target, not just the
                                // glyph — a chevron alone is a small thing to
                                // hit repeatedly across a season of sessions.
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 6)
                            .padding(.bottom, 2)
                        }
                    }
                }
            }
        }
        .navigationTitle("Athletes")
        .overlay {
            if model.athletes.isEmpty {
                // The sidebar no longer tells the coach to go and open
                // something: the pane beside it is a list of the libraries
                // they have, and pointing at it beats repeating the ask.
                emptyState(
                    title: "No Library Open",
                    systemImage: "film.stack",
                    // There is no "right" on a phone: the libraries are the
                    // screen behind this one, not the column beside it.
                    description: isCompact ? "Go back to choose one." : "Choose one on the right."
                )
            }
        }
    }

    /// One athlete, reached two ways.
    ///
    /// In a split view the sidebar's selection *is* the navigation — SwiftUI
    /// fills the column beside it — so a tagged row is the whole story on a Mac
    /// or an iPad. A phone has no column to fill, and a tagged row in a plain
    /// stack is a row that looks interactive and does nothing, so there the row
    /// is a real button that selects and pushes. Same content either way; only
    /// the thing that makes it respond differs.
    @ViewBuilder
    private func athleteRow(_ athlete: AthleteGroup) -> some View {
        // The section header already names the leading dimension, so each row
        // spells out the other one — the athlete's event when the sidebar is
        // athlete-led, same as it always has when it is event-led.
        let content = HStack {
            Text(
                model.sidebarGrouping == .event
                    ? athlete.name
                    : (athlete.event ?? "No event")
            )
            Spacer()
            Text("\(athlete.videos.count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }

        if isCompact {
            Button {
                model.selectedAthleteID = athlete.id
                phonePath.append(.viewer)
            } label: {
                content.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The spoken label is the name and the clip count together, which
            // a test would have to reassemble. The identifier is the name.
            .accessibilityIdentifier("sidebar.athlete.\(athlete.name)")
        } else {
            content.tag(athlete.id)
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            if let athlete = model.currentAthlete {
                ViewerPane(model: model, athleteName: athlete.name)

                VStack(spacing: 0) {
                    TimelineScrubber(
                        time: model.currentTime,
                        duration: model.duration,
                        onScrub: { model.scrub(to: $0) }
                    )
                    .accessibilityIdentifier("Viewer timeline")
                    .padding(.horizontal, 12)

                    ViewerControlBar(model: model)
                }
                .background(.bar)
            } else {
                // What used to be an empty pane telling the coach to go and
                // find a folder. The libraries they already have are a better
                // answer to "nothing is open" than an instruction is.
                LibrariesView(
                    model: model,
                    cache: clipCache,
                    makeProvider: GoogleDriveSheet.makeConfiguredProvider,
                    onConnectDrive: { isShowingGoogleDriveSheet = true }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(model.libraryTitle)
        #if os(macOS)
        // Which drive, and how much of it — the title alone says "Videos", and
        // two clubs can both have a folder called that.
        .navigationSubtitle(model.librarySummary ?? "")
        #endif
        // iPadOS renders a toolbar attached to a column, not one attached to
        // the split view, so the items hang off the detail column's navigation
        // bar here. macOS keeps its attachment in `body`; putting the macOS
        // toolbar here too would move its buttons within the window toolbar,
        // and no automated check in this repo would catch that.
        #if os(iOS)
        .toolbar { toolbarContent }
        // Sideways on a phone the navigation bar is a title and a row of
        // buttons sitting on top of the thing the phone was turned sideways to
        // see. Hidden there and nowhere else: turning back upright brings it
        // straight back, which is also how the coach reaches those buttons.
        .toolbar(isShortOnHeight ? .hidden : .visible, for: .navigationBar)
        #endif
    }

    /// Ordinary cached clips live under `Caches`, so the OS may reclaim them
    /// under storage pressure — correct for a cache, and what matters most on
    /// an iPad. Budget is the design spec's default: 20 GB on macOS, 5 GB on
    /// iPadOS, since a full-size iPad's storage is far smaller than a Mac's.
    ///
    /// `ClipCache`'s current API takes a single `root:` — there is no second
    /// parameter for the spec's separate, backup-excluded
    /// `Application Support/PinnedClips` location pinned clips are meant to
    /// live in. Adding one belongs to `ClipCache.swift`, which is outside
    /// this task's file list; pinning has no control that calls it yet
    /// regardless (see "What this plan does not do"), so nothing here
    /// regresses by leaving pinned and ordinary clips sharing one root.
    private static func makeClipCache() -> ClipCache {
        let fileManager = FileManager.default
        let cachesDirectory = (try? fileManager.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? fileManager.temporaryDirectory
        let root = cachesDirectory.appendingPathComponent("CloudClips", isDirectory: true)
        #if os(iOS)
        let budget: Int64 = 5_000_000_000
        #else
        let budget: Int64 = 20_000_000_000
        #endif
        return ClipCache(root: root, downloader: URLSessionClipDownloader(), budget: budget)
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
