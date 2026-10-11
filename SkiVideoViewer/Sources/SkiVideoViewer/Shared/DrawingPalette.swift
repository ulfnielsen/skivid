import Combine
import SkiVideoCore
import SwiftUI

/// Shown in the control bar's place while drawing: transport is meaningless
/// then, and a phone has no room for both. Wraps to two rows when narrow.
struct DrawingPalette: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var session: DrawingSession
    @Environment(\.drawingTyping) private var typing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { tools; Divider().frame(height: 28); colours; Divider().frame(height: 28); actions }
            VStack(spacing: 4) {
                HStack(spacing: 4) { tools; colours }
                HStack(spacing: 4) { actions }
            }
            // A phone in portrait: the row above measures about 420pt against
            // a 393pt screen, so tools, colours and actions each get a row.
            VStack(spacing: 4) {
                HStack(spacing: 4) { tools }
                HStack(spacing: 4) { colours }
                HStack(spacing: 4) { actions }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// Every button that would end an open text edit goes through here: a tool
    /// change, a frame step and undo all reach `cancelInProgress`, which drops
    /// the typing without keeping it.
    private func keepingText(_ perform: () -> Void) {
        typing.commit(into: session)
        perform()
    }

    private var tools: some View {
        HStack(spacing: 2) {
            tool(.move, "hand.draw", "Move")
            tool(.pen, "scribble", "Pen")
            tool(.line, "arrow.up.right", "Line")
            tool(.angle, "angle", "Angle")
            tool(.text, "textformat", "Text")
            if session.tool == .line {
                // `arrowhead` is not an SF Symbol; this one is, from 2019.
                toggle(isOn: session.arrowheads, symbol: "arrowtriangle.right", label: "Arrowheads", id: "drawing.arrowheads") {
                    session.arrowheads.toggle()
                }
            }
        }
    }

    private var colours: some View {
        HStack(spacing: 2) {
            ForEach(DrawingColor.allCases, id: \.self) { colour in
                Button { keepingText { session.color = colour } } label: {
                    Circle().fill(DrawingOverlay.colour(colour))
                        .overlay(Circle().stroke(.white, lineWidth: session.color == colour ? 3 : 0))
                        .frame(width: 24, height: 24)
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(colour.rawValue.capitalized)
                .accessibilityIdentifier("drawing.color.\(colour.rawValue)")
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            HoldToRepeatButton(symbol: "backward.frame", label: "Previous frame", id: "drawing.stepBack") {
                keepingText { model.stepFrame(.backward) }
            }
            HoldToRepeatButton(symbol: "forward.frame", label: "Next frame", id: "drawing.stepForward") {
                keepingText { model.stepFrame(.forward) }
            }
            action("eraser", "Clear frame", "drawing.clearFrame") {
                session.clear(at: model.currentTime, frameDuration: model.frameDuration)
            }
            if session.selection != nil {
                action("trash", "Delete", "drawing.delete") { session.deleteSelection() }
            }
            action("arrow.uturn.backward", "Undo", "drawing.undo") { session.undo() }
                .disabled(!session.canUndo)
            action("arrow.uturn.forward", "Redo", "drawing.redo") { session.redo() }
                .disabled(!session.canRedo)
            Button("Done") { keepingText { model.setDrawing(false) } }
                .accessibilityIdentifier("drawing.done")
        }
    }

    private func tool(_ tool: DrawingTool, _ symbol: String, _ label: String) -> some View {
        toggle(isOn: session.tool == tool, symbol: symbol, label: label, id: "drawing.tool.\(tool.rawValue)") {
            session.tool = tool
        }
    }

    private func toggle(isOn: Bool, symbol: String, label: String, id: String, perform: @escaping () -> Void) -> some View {
        Button { keepingText(perform) } label: {
            Image(systemName: symbol)
                .frame(width: 40, height: 40)
                .background(isOn ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    private func action(_ symbol: String, _ label: String, _ id: String, perform: @escaping () -> Void) -> some View {
        Button { keepingText(perform) } label: {
            Image(systemName: symbol).frame(width: 40, height: 40).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// A palette button that steps once when pressed and keeps stepping while
/// held: 0.4 s before the first repeat, so a click is still exactly one frame,
/// then every 0.1 s — ten frames a second, a third of real time at 30 fps,
/// slow enough to watch the marks stretch frame by frame.
///
/// **The first step happens on press, not on release**, because the repeat
/// has to start from the press; a step on release as well would make every
/// click two frames. So the press marks `latch`, and the button's own action —
/// which fires on release — only steps when no press did. That is the path
/// VoiceOver and keyboard activation take: they call the action without ever
/// setting `isPressed`. The press is seen in `onChange`, synchronously, so it
/// is always recorded before the release can ask.
struct HoldToRepeatButton: View {
    let symbol: String
    let label: String
    let id: String
    let step: () -> Void

    private final class Latch { var pressed = false }
    @State private var latch = Latch()

    var body: some View {
        Button {
            if latch.pressed { latch.pressed = false } else { step() }
        } label: {
            Image(systemName: symbol).frame(width: 40, height: 40).contentShape(Rectangle())
        }
        .buttonStyle(RepeatingStyle(latch: latch, step: step))
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private struct RepeatingStyle: ButtonStyle {
        let latch: Latch
        let step: () -> Void

        func makeBody(configuration: Configuration) -> some View {
            PressWatcher(configuration: configuration, latch: latch, step: step)
        }

        private struct PressWatcher: View {
            let configuration: Configuration
            let latch: Latch
            let step: () -> Void
            @State private var repeating: Task<Void, Never>?

            var body: some View {
                configuration.label
                    .foregroundStyle(Color.accentColor)
                    .opacity(configuration.isPressed ? 0.5 : 1)
                    .onChange(of: configuration.isPressed) { pressed in
                        repeating?.cancel()
                        repeating = nil
                        guard pressed else { return }
                        latch.pressed = true
                        step()
                        repeating = Task { @MainActor in
                            var delay: UInt64 = 400_000_000
                            while true {
                                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                                step()
                                delay = 100_000_000
                            }
                        }
                    }
                    .onDisappear { repeating?.cancel() }
            }
        }
    }
}

/// The control bar, or the palette while drawing. Its own view so it can
/// observe the drawing controller, which `ContentView` does not.
struct DrawingAwareControlBar: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var drawing: DrawingController

    init(model: ViewerModel) {
        self.model = model
        _drawing = ObservedObject(wrappedValue: model.drawing)
    }

    var body: some View {
        if drawing.isDrawing, let session = drawing.session {
            DrawingPalette(model: model, session: session)
        } else {
            ViewerControlBar(model: model)
        }
    }
}

/// The viewer's timeline with the drawn spans marked. Its own view for the same
/// reason as `DrawingAwareControlBar`: `ContentView` does not observe the
/// drawing controller.
struct DrawingAwareScrubber: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var drawing: DrawingController

    init(model: ViewerModel) {
        self.model = model
        _drawing = ObservedObject(wrappedValue: model.drawing)
    }

    var body: some View {
        Inner(model: model, session: drawing.session)
    }

    /// `DrawingSession` is itself an `ObservableObject`: observing only the
    /// controller would leave the bars stale when a mark is added or removed.
    /// The session is optional, so it cannot be an `@ObservedObject`; and a
    /// nil/non-nil branch would swap the `TimelineScrubber`'s identity and drop
    /// its mid-drag state. Instead one scrubber is always rendered, and the
    /// session's change signal bumps a counter to re-render it. `objectWillChange`
    /// fires before the mutation, but the `@State` write re-renders afterwards,
    /// so `spans` is read post-change.
    private struct Inner: View {
        @ObservedObject var model: ViewerModel
        let session: DrawingSession?
        @State private var changes = 0
        /// The row's width, for turning `ClipDrawings.scrubSnapReach` points
        /// into seconds. Read from a background so measuring cannot change
        /// the row's height the way a `GeometryReader` around it would.
        @State private var width = 0.0

        var body: some View {
            let _ = changes
            let spans = session?.drawings.spans ?? []
            TimelineScrubber(
                time: model.currentTime, duration: model.duration,
                marks: spans,
                onScrub: { time in
                    // Pulled onto a drawing within reach: the bars cannot be
                    // tapped, so this is how a coach lands on a one-frame mark.
                    if let landing = ClipDrawings.scrubLanding(
                        for: time, spans: spans, duration: model.duration, width: width
                    ) {
                        model.scrub(toFrameAt: landing)
                    } else {
                        model.scrub(to: time)
                    }
                }
            )
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { width = proxy.size.width }
                    .onChange(of: proxy.size.width) { width = $0 }
            })
            .onReceive(session?.objectWillChange.eraseToAnyPublisher()
                       ?? Empty<Void, Never>().eraseToAnyPublisher()) { changes &+= 1 }
        }
    }
}
