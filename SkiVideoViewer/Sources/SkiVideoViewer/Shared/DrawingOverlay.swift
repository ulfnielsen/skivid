import SkiVideoCore
import SwiftUI

/// The text being typed into a label, shared between the overlay (which owns
/// the field) and the palette (whose buttons would otherwise discard it).
///
/// `DrawingSession.cancelInProgress` clears `editingText` without committing,
/// and a tool change, frame step or undo all reach it. The palette is a
/// different view from the overlay, so the typed string cannot be the
/// overlay's private `@State`; every action that would end an edit commits
/// through here first.
final class DrawingTyping: ObservableObject {
    @Published var text = ""

    /// Keeps what was typed. A no-op when nothing is being edited.
    @MainActor func commit(into session: DrawingSession) {
        if session.editingText != nil { session.finishText(text) }
    }

    /// For the app going away — to the background, or quitting on macOS:
    /// keeps the open label, then writes now rather than after the debounce,
    /// which would never run. The label first, or the save would miss it.
    @MainActor func keepAndSave(_ drawing: DrawingController) {
        if let session = drawing.session { commit(into: session) }
        drawing.saveNow()
    }
}

private struct DrawingTypingKey: EnvironmentKey {
    static let defaultValue = DrawingTyping()
}

extension EnvironmentValues {
    var drawingTyping: DrawingTyping {
        get { self[DrawingTypingKey.self] }
        set { self[DrawingTypingKey.self] = newValue }
    }
}

/// The marks over the video, and — in drawing mode — the gestures that make
/// them. Everything it knows about where things are comes from
/// `DrawingGeometry`, built from the same `VideoZoom` the picture is placed
/// with, so the marks stay on the snow at any zoom.
struct DrawingOverlay: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var session: DrawingSession
    let isDrawing: Bool
    let paneSize: CGSize

    @State private var isDragging = false
    @Environment(\.drawingTyping) private var typing
    @AppStorage("drawing.angleNoteShown") private var angleNoteShown = false

    /// Screen points, constant at any zoom.
    private let lineWidth: CGFloat = 4

    private var geometry: DrawingGeometry {
        DrawingGeometry(zoom: model.zoom, paneSize: paneSize, videoSize: model.pictureSize)
    }

    private var time: Double { ClipDrawings.snap(model.currentTime, frameDuration: model.frameDuration) }

    private var visible: [Drawing] {
        session.drawings.visible(at: model.currentTime, frameDuration: model.frameDuration)
            + [session.inProgress].compactMap { $0 }
    }

    var body: some View {
        // After a same-clip reload `isDrawing` can be true while the picture
        // size is still unknown; the geometry would divide by zero, so
        // nothing is drawn and no gesture is installed until it is known.
        if model.pictureSize != .zero {
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for mark in visible { draw(mark, in: &context) }
                }
                .allowsHitTesting(false)

                ForEach(Array(visible.enumerated()), id: \.element.id) { index, mark in
                    labels(for: mark, index: index)
                }

                if isDrawing, session.tool != .move {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(drawGesture)
                }

                if let editing = session.editingText {
                    textField(at: geometry.toPane(editing.points[0]), editing: editing)
                }

                if isDrawing, session.tool == .angle, !angleNoteShown {
                    angleNote
                }
            }
            .frame(width: paneSize.width, height: paneSize.height)
            .clipped()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("drawing.overlay")
            .accessibilityValue("\(session.drawings.visible(at: model.currentTime, frameDuration: model.frameDuration).count) on this frame")
        }
    }

    /// One gesture for taps and drags: under 4pt of travel is a tap. Two
    /// separate SwiftUI gestures would make every tap wait on the drag.
    private var drawGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDragging, hypot(value.translation.width, value.translation.height) >= 4 {
                    typing.commit(into: session)
                    session.dragBegan(at: value.startLocation, geometry: geometry, time: time,
                                      frameDuration: model.frameDuration)
                    isDragging = true
                }
                if isDragging { session.dragChanged(to: value.location, geometry: geometry) }
            }
            .onEnded { value in
                if isDragging {
                    session.dragEnded(at: value.location, geometry: geometry)
                } else {
                    typing.commit(into: session)
                    session.tapped(at: value.location, geometry: geometry, time: time,
                                   frameDuration: model.frameDuration)
                    // The field may be reused when the same label reopens in
                    // the same update, so `onAppear` alone could miss it.
                    if let editing = session.editingText { typing.text = editing.text }
                }
                isDragging = false
            }
    }

    private func draw(_ mark: Drawing, in context: inout GraphicsContext) {
        let points = mark.points.map(geometry.toPane)
        let colour = Self.colour(mark.color)
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        let selected = mark.id == session.selection
        var path = Path()
        switch mark.kind {
        case .pen:
            // Smoothed through midpoints: each sample becomes a control point.
            guard let first = points.first else { return }
            path.move(to: first)
            for (a, b) in zip(points, points.dropFirst()) {
                path.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
            }
            if let last = points.last { path.addLine(to: last) }
        case .line:
            path.move(to: points[0])
            path.addLine(to: points[1])
            if mark.arrow { path.addPath(Self.arrowhead(from: points[0], to: points[1])) }
        case .angle:
            path.move(to: points[1])
            path.addLine(to: points[0])
            if points.count > 2 { path.addLine(to: points[2]) }
        case .text:
            return
        }
        context.stroke(path, with: .color(.black.opacity(0.5)), style: StrokeStyle(lineWidth: lineWidth + 2, lineCap: .round, lineJoin: .round))
        context.stroke(path, with: .color(colour), style: style)
        if selected, mark.kind == .line || mark.kind == .angle {
            for p in points {
                context.fill(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)), with: .color(.white))
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)), with: .color(colour), lineWidth: 2)
            }
        }
    }

    @ViewBuilder
    private func labels(for mark: Drawing, index: Int) -> some View {
        let points = mark.points.map(geometry.toPane)
        // Angles only, so `angleValue.0` is the first angle on the frame
        // whatever marks were drawn before it.
        let angleNumber = visible.prefix(index).filter { $0.kind == .angle }.count
        switch mark.kind {
        case .angle where points.count == 3:
            let degrees = DrawingGeometry.angle(corner: mark.points[0], a: mark.points[1], b: mark.points[2],
                                                videoSize: model.pictureSize)
            Text("\(Int(degrees.rounded()))°")
                .font(.headline.monospacedDigit())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Self.colour(mark.color).opacity(0.85), in: Capsule())
                .foregroundStyle(mark.color == .yellow ? .black : .white)
                .position(x: points[0].x, y: points[0].y - 22)
                .allowsHitTesting(false)
                .accessibilityIdentifier("drawing.angleValue.\(angleNumber)")
        case .text where mark.id != session.editingText?.id:
            Text(mark.text)
                .font(.headline)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Self.colour(mark.color).opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(mark.color == .yellow ? .black : .white)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white, lineWidth: mark.id == session.selection ? 2 : 0))
                .position(points[0])
                .allowsHitTesting(false)
        default:
            EmptyView()
        }
    }

    private func textField(at point: CGPoint, editing: Drawing) -> some View {
        DrawingTextField(typing: typing, initial: editing.text) { session.finishText(typing.text) }
            .position(point)
            // Keyed by the mark: `onAppear` does not refire when the field is
            // reused for a different label, so the old text would carry over.
            .id(editing.id)
    }

    private var angleNote: some View {
        HStack(spacing: 8) {
            Text("Angles are measured as filmed: they match the real angle only when the camera is square-on to it.")
                .font(.caption)
            Button("OK") { angleNoteShown = true }
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
    }

    static func colour(_ colour: DrawingColor) -> Color {
        switch colour {
        case .red: return .red
        case .yellow: return .yellow
        case .blue: return .blue
        case .black: return .black
        }
    }

    private static func arrowhead(from a: CGPoint, to b: CGPoint) -> Path {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let length: CGFloat = 16, spread: CGFloat = .pi / 7
        var path = Path()
        path.move(to: CGPoint(x: b.x - length * cos(angle - spread), y: b.y - length * sin(angle - spread)))
        path.addLine(to: b)
        path.addLine(to: CGPoint(x: b.x - length * cos(angle + spread), y: b.y - length * sin(angle + spread)))
        return path
    }
}

/// Observes the shared typing buffer so each keystroke redraws only the field.
private struct DrawingTextField: View {
    @ObservedObject var typing: DrawingTyping
    let initial: String
    let onSubmit: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Note", text: $typing.text)
            .focused($isFocused)
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
            .onAppear {
                typing.text = initial
                // So the coach can type straight away rather than tap the field.
                isFocused = true
            }
            .onSubmit(onSubmit)
            .accessibilityIdentifier("drawing.textField")
    }
}
