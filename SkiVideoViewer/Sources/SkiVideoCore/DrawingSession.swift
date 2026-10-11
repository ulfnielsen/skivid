import Combine
import CoreGraphics
import Foundation

public enum DrawingTool: String, CaseIterable, Sendable {
    /// Pans while zoomed — the view handles it; the session ignores the drag.
    case move
    case pen, line, angle, text
}

/// One clip's marks while a coach edits them: the tool, the mark under the
/// finger, selection, and undo. Gesture points arrive in pane points with the
/// geometry they were measured against; marks are stored in picture fractions.
@MainActor
public final class DrawingSession: ObservableObject {
    /// Shorter than this on screen, a line or angle arm is a slip, not a mark.
    public static let minimumStrokeLength: CGFloat = 8
    /// Pen samples closer than this are dropped — what keeps a shaky stroke smooth.
    public static let penSpacing: CGFloat = 2

    @Published public var tool: DrawingTool = .pen {
        didSet { if tool != oldValue { cancelInProgress() } }
    }
    @Published public var color: DrawingColor = .red
    @Published public var arrowheads = true
    @Published public private(set) var drawings: ClipDrawings
    @Published public private(set) var inProgress: Drawing?
    @Published public private(set) var selection: UUID?
    /// A text mark being typed — new (not yet in `drawings`) or existing.
    @Published public private(set) var editingText: Drawing?
    @Published public private(set) var awaitingSecondArm = false

    private var undoStack: [ClipDrawings] = []
    private var redoStack: [ClipDrawings] = []
    /// `recorded` flips on the first real move, so a press-and-release on a
    /// handle leaves no undo step behind.
    private var draggedHandle: (id: UUID, index: Int, recorded: Bool)?
    private var lastPenPoint: CGPoint?

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public init(drawings: ClipDrawings = ClipDrawings()) {
        self.drawings = drawings
    }

    // MARK: Gestures

    public func dragBegan(at q: CGPoint, geometry: DrawingGeometry, time: Double, frameDuration: Double) {
        let p = geometry.toPicture(q)
        // A selection can outlive a frame step; its handles must not grab
        // from a frame where the mark is not even on screen.
        if let selection, let selected = drawing(selection),
           selected.isVisible(at: time, frameDuration: frameDuration),
           let index = geometry.handle(q, of: selected) {
            draggedHandle = (selection, index, false)
            return
        }
        switch tool {
        case .move, .text:
            return
        case .pen:
            lastPenPoint = q
            inProgress = Drawing(kind: .pen, color: color, points: [p], start: time)
        case .line:
            inProgress = Drawing(kind: .line, color: color, points: [p, p], arrow: arrowheads, start: time)
        case .angle:
            if awaitingSecondArm, var angle = inProgress {
                angle.points.append(p)
                inProgress = angle
            } else {
                inProgress = Drawing(kind: .angle, color: color, points: [p, p], start: time)
            }
        }
    }

    public func dragChanged(to q: CGPoint, geometry: DrawingGeometry) {
        let p = geometry.toPicture(q)
        if let handle = draggedHandle, let i = drawings.drawings.firstIndex(where: { $0.id == handle.id }) {
            guard drawings.drawings[i].points[handle.index] != p else { return }
            if !handle.recorded {
                record()
                draggedHandle?.recorded = true
            }
            drawings.drawings[i].points[handle.index] = p
            return
        }
        guard var mark = inProgress else { return }
        switch mark.kind {
        case .pen:
            if let last = lastPenPoint, hypot(q.x - last.x, q.y - last.y) < Self.penSpacing { return }
            mark.points.append(p)
            lastPenPoint = q
        case .line, .angle:
            mark.points[mark.points.count - 1] = p
        case .text:
            return
        }
        inProgress = mark
    }

    public func dragEnded(at q: CGPoint, geometry: DrawingGeometry) {
        dragChanged(to: q, geometry: geometry)
        if draggedHandle != nil {
            draggedHandle = nil
            return
        }
        guard let mark = inProgress else { return }
        let lastArmIsLongEnough = mark.points.count >= 2 && paneLength(
            mark.points[mark.kind == .angle ? 0 : mark.points.count - 2], mark.points[mark.points.count - 1], geometry
        ) >= Self.minimumStrokeLength
        switch mark.kind {
        case .pen:
            if mark.points.count >= 2 { commit(mark) } else { inProgress = nil }
        case .line:
            if lastArmIsLongEnough { commit(mark) } else { inProgress = nil }
        case .angle where mark.points.count == 2:
            if lastArmIsLongEnough { awaitingSecondArm = true } else { inProgress = nil }
        case .angle:
            if lastArmIsLongEnough {
                awaitingSecondArm = false
                commit(mark)
            } else {
                // A slip: drop the third point and keep waiting for a real arm.
                var pending = mark
                pending.points.removeLast()
                inProgress = pending
            }
        case .text:
            inProgress = nil
        }
    }

    public func tapped(at q: CGPoint, geometry: DrawingGeometry, time: Double, frameDuration: Double) {
        let p = geometry.toPicture(q)
        if awaitingSecondArm, var angle = inProgress {
            guard paneLength(angle.points[0], p, geometry) >= Self.minimumStrokeLength else { return }
            angle.points.append(p)
            awaitingSecondArm = false
            commit(angle)
            return
        }
        let hit = geometry.hit(q, in: drawings.visible(at: time, frameDuration: frameDuration))
        if tool == .text {
            if let hit, let existing = drawing(hit), existing.kind == .text {
                editingText = existing
            } else {
                editingText = Drawing(kind: .text, color: color, points: [p], start: time)
            }
            return
        }
        selection = hit
    }

    // MARK: Edits

    /// Ends typing. Empty text deletes an existing label and drops a new one.
    public func finishText(_ text: String) {
        guard var mark = editingText else { return }
        editingText = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = drawings.drawings.firstIndex { $0.id == mark.id }
        if let existing, drawings.drawings[existing].text == trimmed { return }
        if trimmed.isEmpty {
            guard let existing else { return }
            record()
            drawings.drawings.remove(at: existing)
            return
        }
        mark.text = trimmed
        record()
        if let existing { drawings.drawings[existing] = mark } else { drawings.drawings.append(mark) }
    }

    /// A scrub in drawing mode moves to a frame where the selected mark may
    /// not be; dropping the selection keeps Delete from removing it unseen.
    public func clearSelection() {
        selection = nil
    }

    public func deleteSelection() {
        guard let selection, let i = drawings.drawings.firstIndex(where: { $0.id == selection }) else { return }
        record()
        drawings.drawings.remove(at: i)
        self.selection = nil
    }

    public func stretch(from: Double, to: Double, frameDuration: Double) {
        var copy = drawings
        guard copy.stretch(from: from, to: to, frameDuration: frameDuration) else { return }
        record()
        drawings = copy
    }

    public func clear(at time: Double, frameDuration: Double) {
        var copy = drawings
        guard copy.clear(at: time, frameDuration: frameDuration) else { return }
        record()
        drawings = copy
        selection = nil
    }

    /// Drops a half-drawn mark and any typing. Called on tool change, frame
    /// step and clip change.
    public func cancelInProgress() {
        inProgress = nil
        awaitingSecondArm = false
        draggedHandle = nil
        editingText = nil
        selection = nil
    }

    /// A drag that turned out to be the first finger of a pinch: undoes only
    /// what that drag did. A moved handle goes back; an angle's second arm
    /// being placed is dropped but the first arm stays, still waiting; any
    /// other half-drawn mark is dropped. Unlike `cancelInProgress`, a
    /// selection and an angle waiting for its second arm survive the zoom.
    public func abandonDrag() {
        if let handle = draggedHandle {
            if handle.recorded, let previous = undoStack.popLast() { drawings = previous }
            draggedHandle = nil
            return
        }
        guard var mark = inProgress else { return }
        if mark.kind == .angle, awaitingSecondArm {
            if mark.points.count == 3 { mark.points.removeLast() }
            inProgress = mark
        } else {
            inProgress = nil
        }
        lastPenPoint = nil
    }

    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(drawings)
        drawings = previous
        selection = nil
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(drawings)
        drawings = next
        selection = nil
    }

    // MARK: Private

    private func drawing(_ id: UUID) -> Drawing? {
        drawings.drawings.first { $0.id == id }
    }

    private func record() {
        undoStack.append(drawings)
        redoStack.removeAll()
    }

    private func commit(_ mark: Drawing) {
        record()
        drawings.drawings.append(mark)
        inProgress = nil
    }

    private func paneLength(_ a: CGPoint, _ b: CGPoint, _ geometry: DrawingGeometry) -> CGFloat {
        let pa = geometry.toPane(a), pb = geometry.toPane(b)
        return hypot(pa.x - pb.x, pa.y - pb.y)
    }
}
