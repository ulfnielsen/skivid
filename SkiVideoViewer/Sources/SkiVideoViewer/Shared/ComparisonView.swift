import SkiVideoCore
import SwiftUI

struct ComparisonView: View {
    @StateObject private var model: ComparisonModel
    @State private var leftScrubTime = 0.0
    @State private var rightScrubTime = 0.0
    @State private var isScrubbingLeft = false
    @State private var isScrubbingRight = false
    let closeWindow: () -> Void

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
            layoutPicker

            switch model.layout {
            case .sideBySide:
                HStack(spacing: 1) {
                    videoPane(side: .left)
                    Divider()
                    videoPane(side: .right)
                }
            case .overlay:
                overlayLayout
            }

            synchronizedControls
        }
        // An 11-inch iPad is 834pt wide in portrait, so a hard 1000pt minimum
        // clips. macOS keeps it: the Compare window is resizable and needs a
        // floor. Same shape as `ContentView`'s minimum-size conditional.
        #if os(macOS)
        .frame(minWidth: 1000, minHeight: 680)
        #endif
        .onDisappear { model.close() }
    }

    private var layoutPicker: some View {
        HStack {
            Picker("", selection: $model.layout) {
                ForEach(ComparisonLayout.allCases) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var overlayLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                paneHeader(side: .left)
                Divider()
                paneHeader(side: .right)
            }

            // Both platforms use the SwiftUI stack. macOS previously had its
            // own NSViewRepresentable overlay, whose CALayer.compositingFilter
            // approach is a silent no-op on iOS; the argument list here is
            // unchanged from the one that view was given.
            OverlayPlayerStack(
                bottomPlayer: model.leftPlayer,
                topPlayer: model.rightPlayer,
                topOpacity: model.topLayerOpacity,
                blend: model.blend
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            overlayControls

            HStack(spacing: 1) {
                paneTransport(side: .left)
                Divider()
                paneTransport(side: .right)
            }
        }
    }

    private var overlayControls: some View {
        HStack(spacing: 14) {
            Text("Left")
                .foregroundStyle(.secondary)
            Slider(value: $model.overlayOpacity, in: 0...1)
                .frame(minWidth: 180)
                .disabled(model.blend == .difference)
            Text("Right")
                .foregroundStyle(.secondary)

            Picker("", selection: $model.blend) {
                ForEach(OverlayBlend.allCases) { blend in
                    Text(blend.title).tag(blend)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

            Text(
                model.blend == .difference
                    ? "Difference blending uses full opacity · black where the clips match"
                    : "Right video drawn over left · drag toward a side to favour that clip"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .background(.bar)
    }

    private func videoPane(side: ComparisonSide) -> some View {
        let player = side == .left ? model.leftPlayer : model.rightPlayer

        return VStack(spacing: 0) {
            paneHeader(side: side)

            NativePlayerView(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            paneTransport(side: side)
        }
    }

    private func paneHeader(side: ComparisonSide) -> some View {
        let isLeft = side == .left
        let name = isLeft ? model.leftName : model.rightName

        return HStack {
            Text(isLeft ? "Left" : "Right")
                .font(.headline)
            Text(name)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer()
            if !model.openLibrary.isEmpty {
                Menu("From Open Folder…") {
                    ForEach(model.openLibrary) { athlete in
                        Menu(athlete.name) {
                            ForEach(athlete.videos) { video in
                                Button(video.name) {
                                    model.load(video, side: side)
                                }
                            }
                        }
                    }
                }
            }
            Button("Choose File…") { Task { await model.chooseVideo(side: side) } }
        }
        .padding(12)
        .background(.bar)
    }

    private func paneTransport(side: ComparisonSide) -> some View {
        let isLeft = side == .left
        let time = isLeft ? model.leftTime : model.rightTime
        let duration = isLeft ? model.leftDuration : model.rightDuration
        let scrubTime = isLeft ? leftScrubTime : rightScrubTime
        let isScrubbing = isLeft ? isScrubbingLeft : isScrubbingRight
        let displayedTime = isScrubbing ? scrubTime : time

        return VStack(spacing: 9) {
            Slider(
                value: Binding(
                    get: {
                        min(displayedTime, max(duration, 0))
                    },
                    set: {
                        if isLeft {
                            leftScrubTime = $0
                        } else {
                            rightScrubTime = $0
                        }
                        model.scrub(side, to: $0)
                    }
                ),
                in: 0...max(duration, 0.1),
                onEditingChanged: { editing in
                    if isLeft {
                        if editing {
                            leftScrubTime = time
                            isScrubbingLeft = true
                        } else {
                            isScrubbingLeft = false
                        }
                    } else if editing {
                        rightScrubTime = time
                        isScrubbingRight = true
                    } else {
                        isScrubbingRight = false
                    }
                }
            )
            .disabled(duration <= 0)

            HStack {
                Text("\(ComparisonModel.timecode(displayedTime)) / \(ComparisonModel.timecode(duration))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("−5s") { model.seek(side, by: -5) }
                Button("−1s") { model.seek(side, by: -1) }
                Button("Play / Pause") { model.toggleIndividual(side) }
                Button("Slow 0.25×") { model.playIndividual(side, rate: 0.25) }
                Button("+1s") { model.seek(side, by: 1) }
                Button("+5s") { model.seek(side, by: 5) }
            }
        }
        .padding(12)
        .background(.bar)
    }

    private var synchronizedControls: some View {
        VStack(spacing: 10) {
            HStack {
                Button("Close") { closeWindow() }
                Spacer()
                Label(
                    model.isSynced ? "Linked" : "Independent",
                    systemImage: model.isSynced ? "link" : "link.badge.plus"
                )
                .foregroundStyle(model.isSynced ? .blue : .secondary)
                Text(model.status)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isSynced {
                    Button("Unsync") { model.removeSync() }
                        .buttonStyle(.borderedProminent)
                }
                Button(model.isSynced ? "Update Sync Points" : "Set Sync Points") {
                    model.setSyncPoints()
                }
                    .disabled(!model.hasTwoVideos)
                    .keyboardShortcut(.return, modifiers: [.command])
            }

            HStack(spacing: 10) {
                Button("Back to Sync Points") { model.returnToSyncPoints() }
                Button("Both −5s") { model.seekSynced(by: -5) }
                Button("Play Together") { model.playSynced() }
                Button("Slow Together 0.25×") { model.playSynced(rate: 0.25) }
                Button("Pause / Stop") { model.pauseBoth() }
                Button("Both +5s") { model.seekSynced(by: 5) }
            }

            Text(
                model.isSynced
                    ? "All controls now affect both videos · Unsync restores independent controls · Space plays/pauses · ←/→ moves both one second"
                    : "Align each side independently · ⌘Return sets sync points"
            )
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.regularMaterial)
    }
}
