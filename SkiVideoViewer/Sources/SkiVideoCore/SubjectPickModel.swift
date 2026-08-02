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

    public init(segments: [AnalysedSegment]) {
        self.segments = segments
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
