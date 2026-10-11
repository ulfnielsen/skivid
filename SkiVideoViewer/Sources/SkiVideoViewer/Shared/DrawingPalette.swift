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
            action("backward.frame", "Previous frame", "drawing.stepBack") { model.stepFrame(.backward) }
            action("forward.frame", "Next frame", "drawing.stepForward") { model.stepFrame(.forward) }
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
