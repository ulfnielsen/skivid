import Combine
import Foundation

/// The operator's segment selection, and the rule that keeps it coherent.
///
/// Segments overlapping in time are mutually exclusive. This is not a nicety:
/// C0082 produced 779 detections over 776 samples because two picked segments
/// overlapped, which is only possible if one of them is a different person. The
/// union then silently blends two athletes into one trajectory that looks
/// entirely plausible. Making the overlapping option unavailable turns that
/// into something the UI will not offer.
public final class SubjectPickModel: ObservableObject {
    public let segments: [AnalysedSegment]
    @Published public private(set) var selected: [Int] = []

    /// `selected` seeds the model from a stored pick, so reopening the sheet
    /// shows the operator's own judgement back rather than an empty grid that
    /// reads as "your pick was lost".
    ///
    /// **A stored selection is filtered, not trusted.** A sidecar can name an
    /// id that no longer exists (re-analysed with different settings, or
    /// hand-edited) or two ids that overlap in time, which the interactive path
    /// cannot produce and the rest of this type's invariants assume away — the
    /// union of two overlapping segments is two people blended into one
    /// trajectory, which is the failure this class exists to prevent. So each
    /// id goes through the same gates `toggle` applies, **in the order given**:
    /// unknown ids are dropped, duplicates are dropped, and of two overlapping
    /// ids the first named wins and the later one is simply not selected —
    /// where it then reports its own `exclusionReason` like any other clash.
    /// The alternative is trusting a file over the invariant.
    public init(segments: [AnalysedSegment], selected: [Int] = []) {
        self.segments = segments
        for id in selected {
            guard let segment = segments.first(where: { $0.id == id }) else { continue }
            guard !self.selected.contains(id) else { continue }
            guard isSelectable(segment) else { continue }
            self.selected.append(id)
        }
    }

    public var selectedInTimeOrder: [Int] {
        segments.sorted { $0.firstSeen < $1.firstSeen }
            .filter { selected.contains($0.id) }
            .map(\.id)
    }

    public func isSelected(_ segment: AnalysedSegment) -> Bool {
        selected.contains(segment.id)
    }

    public func isSelectable(_ segment: AnalysedSegment) -> Bool {
        isSelected(segment) || exclusionReason(for: segment) == nil
    }

    /// Why this segment cannot be picked, phrased for the operator, or nil.
    public func exclusionReason(for segment: AnalysedSegment) -> String? {
        guard !isSelected(segment) else { return nil }
        guard let clash = segments.first(where: {
            selected.contains($0.id) && $0.overlaps(segment)
        }) else { return nil }
        return "Overlaps segment \(clash.id) in time, so they cannot be the same person"
    }

    public func toggle(_ id: Int) {
        guard let segment = segments.first(where: { $0.id == id }) else { return }
        if let index = selected.firstIndex(of: id) {
            selected.remove(at: index)
        } else if isSelectable(segment) {
            selected.append(id)
        }
    }
}
