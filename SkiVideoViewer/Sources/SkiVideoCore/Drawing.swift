import CoreGraphics
import Foundation

public enum DrawingKind: String, Codable, Sendable {
    case pen, line, angle, text
}

/// Four colours chosen to read against snow and sky. White is left out on
/// purpose: most of what this app shows is snow.
public enum DrawingColor: String, Codable, CaseIterable, Sendable {
    case red, yellow, blue, black
}

/// One mark on a clip, over a span of its frames.
///
/// Points are fractions of the video *picture* (0…1, origin top-left), never
/// screen points, so a mark stays on the snow at any zoom, pan or pane size.
/// pen: the stroke; line: `[from, to]`; angle: `[corner, armA, armB]`;
/// text: `[anchor]`.
public struct Drawing: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: DrawingKind
    public var color: DrawingColor
    public var points: [CGPoint]
    public var arrow: Bool
    public var text: String
    /// Clip seconds, frame-snapped. A fresh mark has `start == end`.
    public var start: Double
    public var end: Double

    public init(
        id: UUID = UUID(), kind: DrawingKind, color: DrawingColor, points: [CGPoint],
        arrow: Bool = false, text: String = "", start: Double, end: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.color = color
        self.points = points
        self.arrow = arrow
        self.text = text
        self.start = start
        self.end = end ?? start
    }

    /// Half a frame of margin either side: stepping lands on frame boundaries
    /// and stored times carry rounding, so without it a mark would flicker
    /// off on its own last frame.
    public func isVisible(at time: Double, frameDuration: Double) -> Bool {
        let margin = frameDuration / 2
        return time >= start - margin && time <= end + margin
    }

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(DrawingKind.self, forKey: .kind)
        color = try container.decode(DrawingColor.self, forKey: .color)
        points = try container.decode([CGPoint].self, forKey: .points)
        arrow = try container.decode(Bool.self, forKey: .arrow)
        text = try container.decode(String.self, forKey: .text)
        start = try container.decode(Double.self, forKey: .start)
        end = try container.decode(Double.self, forKey: .end)

        // Validate that start and end are finite
        guard start.isFinite else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath + [CodingKeys.start],
                    debugDescription: "start time must be finite"
                )
            )
        }
        guard end.isFinite else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath + [CodingKeys.end],
                    debugDescription: "end time must be finite"
                )
            )
        }

        // Validate that end >= start
        guard end >= start else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath + [CodingKeys.end],
                    debugDescription: "end time must be >= start time"
                )
            )
        }

        // Validate point count matches kind
        let pointCount = points.count
        switch kind {
        case .pen:
            guard pointCount >= 2 else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath + [CodingKeys.points],
                        debugDescription: "pen drawing must have at least 2 points, got \(pointCount)"
                    )
                )
            }
        case .line:
            guard pointCount == 2 else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath + [CodingKeys.points],
                        debugDescription: "line drawing must have exactly 2 points, got \(pointCount)"
                    )
                )
            }
        case .angle:
            guard pointCount == 3 else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath + [CodingKeys.points],
                        debugDescription: "angle drawing must have exactly 3 points, got \(pointCount)"
                    )
                )
            }
        case .text:
            guard pointCount == 1 else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath + [CodingKeys.points],
                        debugDescription: "text drawing must have exactly 1 point, got \(pointCount)"
                    )
                )
            }
        }

        // Validate that all point coordinates are finite
        for (i, point) in points.enumerated() {
            guard point.x.isFinite else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath + [CodingKeys.points, IndexKey(intValue: i)!],
                        debugDescription: "point [\(i)].x must be finite"
                    )
                )
            }
            guard point.y.isFinite else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath + [CodingKeys.points, IndexKey(intValue: i)!],
                        debugDescription: "point [\(i)].y must be finite"
                    )
                )
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, color, points, arrow, text, start, end
    }

    private struct IndexKey: CodingKey {
        let intValue: Int?
        let stringValue: String

        init?(intValue: Int) {
            self.intValue = intValue
            self.stringValue = "[" + String(intValue) + "]"
        }

        init?(stringValue: String) {
            return nil
        }
    }
}

/// Every mark on one clip — the content of its `.skidrawings.json`.
public struct ClipDrawings: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// For clips whose video track reports no frame rate.
    public static let fallbackFrameDuration = 1.0 / 30

    public var version: Int
    public var drawings: [Drawing]

    public init(drawings: [Drawing] = []) {
        self.version = Self.currentVersion
        self.drawings = drawings
    }

    public var isEmpty: Bool { drawings.isEmpty }

    /// For the timeline's span bars.
    public var spans: [ClosedRange<Double>] { drawings.map { $0.start...$0.end } }

    public static func snap(_ time: Double, frameDuration: Double) -> Double {
        guard frameDuration > 0 else { return time }
        return (time / frameDuration).rounded() * frameDuration
    }

    public func visible(at time: Double, frameDuration: Double) -> [Drawing] {
        drawings.filter { $0.isVisible(at: time, frameDuration: frameDuration) }
    }

    /// A frame step in drawing mode: everything on screen at `from` now also
    /// covers `to`. Returns whether anything changed, so the caller records
    /// an undo step only for a real change.
    @discardableResult
    public mutating func stretch(from: Double, to: Double, frameDuration: Double) -> Bool {
        var changed = false
        for i in drawings.indices where drawings[i].isVisible(at: from, frameDuration: frameDuration) {
            if to > drawings[i].end { drawings[i].end = to; changed = true }
            if to < drawings[i].start { drawings[i].start = to; changed = true }
        }
        return changed
    }

    /// Clear frame: what is visible here stops on the previous frame; on its
    /// own first frame (within half a frame) it is deleted.
    @discardableResult
    public mutating func clear(at time: Double, frameDuration: Double) -> Bool {
        let margin = frameDuration / 2
        var changed = false
        drawings = drawings.compactMap { drawing in
            guard drawing.isVisible(at: time, frameDuration: frameDuration) else { return drawing }
            changed = true
            if time <= drawing.start + margin { return nil }
            var cut = drawing
            cut.end = max(drawing.start, time - frameDuration)
            return cut
        }
        return changed
    }
}
