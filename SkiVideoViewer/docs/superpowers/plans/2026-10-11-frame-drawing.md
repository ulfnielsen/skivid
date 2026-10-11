# Draw and Measure on a Frame — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A coach draws, and measures three-point angles, on paused frames in the single-clip viewer; drawings span frames, stretch as the coach steps, are saved beside the clip, and show or hide with one switch.

**Architecture:** All logic is in `SkiVideoCore`, platform-agnostic and unit-tested: value types for marks and spans (`Drawing`, `ClipDrawings`), pure geometry over the existing `VideoZoom.layerFrame` (`DrawingGeometry`), a sidecar store (`ClipDrawingsStore`), an editing session with undo (`DrawingSession`), and a per-clip controller owned by `ViewerModel` (`DrawingController`). The app target adds a thin SwiftUI `Canvas` overlay, a palette that replaces the control bar while drawing, timeline span bars, and the macOS **D** key.

**Tech Stack:** Swift 5 language mode, SwiftUI (macOS 13 / iOS 17), AVFoundation, Combine, XCTest, XCUITest.

**Spec:** `docs/superpowers/specs/2026-10-11-frame-drawing-design.md`

## Global Constraints

- `swift test` must be prefixed: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.
- Iterate with `--filter SkiVideoCoreTests` (opens no windows). Full suite only at final sign-off.
- Nothing under `Sources/SkiVideoCore` may import or name AppKit or UIKit (`CorePurityTests` enforces it).
- Never `git add -A` — stage files by name. `AppBundle/` holds intentionally uncommitted artwork.
- Commit messages: imperative, no `feat:`/`fix:` prefix.
- Document *why* in comments, with measured evidence where there is any; match the surrounding comment density.
- File extension: `skidrawings.json`; JSON `version` field = `1`.
- Colours: red, yellow, blue, black. Arrowhead on by default.
- Visibility margin: half a frame either side of a span. Frame duration = 1 / video track `nominalFrameRate`; `1/30` s when unknown.
- Angle: computed in pixel space (`presentationSize`), 0–180°, shown in whole degrees.
- Unreadable drawings file: never overwritten; drawing on that clip refused; notice text exactly `Drawings for this clip couldn't be read.`
- Save debounce ~1 s; save on leaving drawing mode, on clip change, and on the app leaving the foreground.
- Out of scope: Drive sync of drawings, Compare, image export, circles, reshaping pen strokes, Pencil pressure.

## Review Focus

1. **Stepping at the clip's ends** — a step back at 0 s or forward at the last frame must neither move nor stretch anything. Pinned in Task 5.
2. **Switching clip while a mark is half-drawn or a text is being typed** — the half-drawn mark is dropped, committed marks are saved to the *old* clip, never the new one. Pinned in Task 6.
3. **A remote clip whose bytes land after selection** (`loadCurrentVideo` runs twice for one clip) — must not reload and lose the in-memory session. Pinned in Task 6.
4. **A drawings file from a newer app version** (`version: 2`) — treated as unreadable, never overwritten. Pinned in Task 3.
5. **Clear on a frame inside a span whose first frame is within half a frame** — deletes rather than leaving a zero-or-negative span. Pinned in Task 1.

---

## File Structure

| File | Responsibility |
|---|---|
| Create `Sources/SkiVideoCore/Drawing.swift` | `DrawingKind`, `DrawingColor`, `Drawing`, `ClipDrawings` (spans, visibility, stretch, clear, snap) |
| Create `Sources/SkiVideoCore/DrawingGeometry.swift` | picture ↔ pane mapping, angle, hit-testing |
| Create `Sources/SkiVideoCore/ClipDrawingsStore.swift` | sidecar read/write with the never-overwrite rule |
| Create `Sources/SkiVideoCore/DrawingSession.swift` | `DrawingTool`, editing state machine, undo/redo |
| Create `Sources/SkiVideoCore/DrawingController.swift` | per-clip session, mode, show switch, debounced save, notices |
| Modify `Sources/SkiVideoCore/ViewerModel.swift` | frame duration, picture size, `stepFrame`, `setDrawing`, intent routing, `drawing` controller |
| Modify `Sources/SkiVideoCore/Seams.swift` | `PlaybackIntent.toggleDrawing` |
| Create `Sources/SkiVideoViewer/Shared/DrawingOverlay.swift` | `Canvas` rendering + gestures + text field |
| Create `Sources/SkiVideoViewer/Shared/DrawingPalette.swift` | tool bar shown instead of the control bar |
| Modify `Sources/SkiVideoViewer/Shared/ViewerPane.swift` | overlay, gesture routing in drawing mode |
| Modify `Sources/SkiVideoViewer/Shared/ViewerControlBar.swift` | pencil + Show drawings buttons |
| Modify `Sources/SkiVideoViewer/Shared/ContentView.swift` | swap bar ↔ palette, scenePhase save, timeline marks |
| Modify `Sources/SkiVideoViewer/Shared/TimelineScrubber.swift` | span bars |
| Modify `Sources/SkiVideoViewer/macOS/AppKitInputSource.swift` | **D** key |
| Tests: `Tests/SkiVideoCoreTests/{DrawingTests,DrawingGeometryTests,ClipDrawingsStoreTests,DrawingSessionTests,ViewerFrameStepTests,DrawingControllerTests}.swift`, `Tests/SkiVideoViewerTests/AppKitInputSourceTests.swift`, `Tests/SkiVideoViewerUITests/DrawingUITests.swift` | |

---

### Task 1: Marks and spans

**Files:**
- Create: `Sources/SkiVideoCore/Drawing.swift`
- Test: `Tests/SkiVideoCoreTests/DrawingTests.swift`

**Interfaces:**
- Produces: `DrawingKind { pen, line, angle, text }`, `DrawingColor { red, yellow, blue, black }`, `struct Drawing` (`id`, `kind`, `color`, `points: [CGPoint]`, `arrow`, `text`, `start`, `end`, `isVisible(at:frameDuration:)`), `struct ClipDrawings` (`version`, `drawings`, `isEmpty`, `spans`, `visible(at:frameDuration:)`, `stretch(from:to:frameDuration:) -> Bool`, `clear(at:frameDuration:) -> Bool`, `static snap(_:frameDuration:)`, `static fallbackFrameDuration`, `static currentVersion`).
- Point conventions (later tasks rely on them): `points` are fractions of the picture, 0…1, origin top-left. pen: ≥2 points; line: `[from, to]`; angle: `[corner, armA, armB]` (2 points while the second arm is not placed yet); text: `[anchor]`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import SkiVideoCore

final class DrawingTests: XCTestCase {
    private let frame = 1.0 / 30

    private func line(start: Double, end: Double? = nil) -> Drawing {
        Drawing(kind: .line, color: .red, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.9)],
                arrow: true, start: start, end: end)
    }

    func testAFreshDrawingCoversOnlyItsOwnFrame() {
        let d = line(start: 1.0)
        XCTAssertEqual(d.end, 1.0)
        XCTAssertTrue(d.isVisible(at: 1.0, frameDuration: frame))
        XCTAssertFalse(d.isVisible(at: 1.0 + frame, frameDuration: frame))
    }

    func testVisibilityIncludesHalfAFrameEitherSideAndNoMore() {
        let d = line(start: 1.0, end: 2.0)
        XCTAssertTrue(d.isVisible(at: 1.0 - frame / 2, frameDuration: frame))
        XCTAssertTrue(d.isVisible(at: 2.0 + frame / 2, frameDuration: frame))
        XCTAssertFalse(d.isVisible(at: 1.0 - frame / 2 - 0.001, frameDuration: frame))
        XCTAssertFalse(d.isVisible(at: 2.0 + frame / 2 + 0.001, frameDuration: frame))
    }

    func testStretchingForwardExtendsTheEndOfWhatIsVisible() {
        var all = ClipDrawings(drawings: [line(start: 1.0), line(start: 5.0)])
        XCTAssertTrue(all.stretch(from: 1.0, to: 1.0 + frame, frameDuration: frame))
        XCTAssertEqual(all.drawings[0].end, 1.0 + frame, accuracy: 1e-9)
        XCTAssertEqual(all.drawings[1].start, 5.0, "a drawing not on screen must not stretch")
        XCTAssertEqual(all.drawings[1].end, 5.0)
    }

    func testStretchingBackwardExtendsTheStart() {
        var all = ClipDrawings(drawings: [line(start: 1.0)])
        all.stretch(from: 1.0, to: 1.0 - frame, frameDuration: frame)
        XCTAssertEqual(all.drawings[0].start, 1.0 - frame, accuracy: 1e-9)
        XCTAssertEqual(all.drawings[0].end, 1.0)
    }

    func testStretchingWithNothingVisibleChangesNothing() {
        var all = ClipDrawings(drawings: [line(start: 3.0)])
        XCTAssertFalse(all.stretch(from: 1.0, to: 1.0 + frame, frameDuration: frame))
        XCTAssertEqual(all, ClipDrawings(drawings: [line(start: 3.0)]).withIDs(of: all))
    }

    func testStretchingInsideASpanChangesNothing() {
        var all = ClipDrawings(drawings: [line(start: 1.0, end: 2.0)])
        XCTAssertFalse(all.stretch(from: 1.5, to: 1.5 + frame, frameDuration: frame))
    }

    func testClearOnAFirstFrameDeletes() {
        var all = ClipDrawings(drawings: [line(start: 1.0, end: 2.0)])
        XCTAssertTrue(all.clear(at: 1.0, frameDuration: frame))
        XCTAssertTrue(all.isEmpty)
    }

    /// Review Focus 5: within half a frame of the start counts as the first
    /// frame, so a clear there deletes instead of leaving `end < start`.
    func testClearWithinHalfAFrameOfTheStartDeletes() {
        var all = ClipDrawings(drawings: [line(start: 1.0, end: 2.0)])
        all.clear(at: 1.0 + frame * 0.4, frameDuration: frame)
        XCTAssertTrue(all.isEmpty)
    }

    func testClearLaterInASpanCutsItBackToThePreviousFrame() {
        var all = ClipDrawings(drawings: [line(start: 1.0, end: 2.0)])
        all.clear(at: 1.5, frameDuration: frame)
        XCTAssertEqual(all.drawings.count, 1)
        XCTAssertEqual(all.drawings[0].end, 1.5 - frame, accuracy: 1e-9)
        XCTAssertFalse(all.drawings[0].isVisible(at: 1.5, frameDuration: frame))
    }

    func testClearLeavesDrawingsElsewhereAlone() {
        var all = ClipDrawings(drawings: [line(start: 4.0)])
        XCTAssertFalse(all.clear(at: 1.0, frameDuration: frame))
        XCTAssertEqual(all.drawings.count, 1)
    }

    func testSnapRoundsToTheNearestFrameBoundary() {
        XCTAssertEqual(ClipDrawings.snap(1.0 / 30 * 10 + 0.004, frameDuration: frame), 1.0 / 30 * 10, accuracy: 1e-9)
        XCTAssertEqual(ClipDrawings.snap(0.7, frameDuration: 0), 0.7, "a zero frame duration must not divide by zero")
    }

    func testRoundTripsThroughJSON() throws {
        let all = ClipDrawings(drawings: [
            line(start: 1, end: 2),
            Drawing(kind: .text, color: .yellow, points: [CGPoint(x: 0.5, y: 0.5)], text: "Hips!", start: 3),
        ])
        let decoded = try JSONDecoder().decode(ClipDrawings.self, from: JSONEncoder().encode(all))
        XCTAssertEqual(decoded, all)
        XCTAssertEqual(decoded.version, 1)
    }
}

private extension ClipDrawings {
    /// Equality across two values built separately needs the same ids.
    func withIDs(of other: ClipDrawings) -> ClipDrawings {
        var copy = self
        for i in copy.drawings.indices where other.drawings.indices.contains(i) {
            copy.drawings[i].id = other.drawings[i].id
        }
        return copy
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SkiVideoCoreTests.DrawingTests`
Expected: compile failure — `Drawing` not defined.

- [ ] **Step 3: Implement**

```swift
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
```

- [ ] **Step 4: Run to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SkiVideoCoreTests.DrawingTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SkiVideoCore/Drawing.swift Tests/SkiVideoCoreTests/DrawingTests.swift
git commit -m "Add drawing marks that span frames, stretch and clear"
```

---

### Task 2: Geometry — picture ↔ pane, angles, hit-testing

**Files:**
- Create: `Sources/SkiVideoCore/DrawingGeometry.swift`
- Test: `Tests/SkiVideoCoreTests/DrawingGeometryTests.swift`

**Interfaces:**
- Consumes: `Drawing`, `VideoZoom.layerFrame(in:videoSize:)`, `VideoZoom.setScale(_:in:videoSize:)`, `VideoZoom.pan(by:in:videoSize:)`.
- Produces: `struct DrawingGeometry` with `init(zoom:paneSize:videoSize:)`, `init(pictureFrame:videoSize:)`, `pictureFrame`, `videoSize`, `toPane(_:)`, `toPicture(_:)`, `static angle(corner:a:b:videoSize:) -> Double` (degrees), `hit(_:in:tolerance:) -> UUID?`, `handle(_:of:tolerance:) -> Int?`, `static let touchTolerance: CGFloat = 22`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import SkiVideoCore

final class DrawingGeometryTests: XCTestCase {
    private let video = CGSize(width: 1920, height: 1080)

    func testRoundTripAtSeveralZoomsAndPans() {
        let pane = CGSize(width: 800, height: 600)   // letterboxed: different aspect
        for scale in [1.0, 2.0, 4.0] {
            for pan in [CGSize.zero, CGSize(width: 5000, height: 5000), CGSize(width: -5000, height: -5000)] {
                var zoom = VideoZoom()
                zoom.setScale(scale, in: pane, videoSize: video)
                zoom.pan(by: pan, in: pane, videoSize: video)
                let g = DrawingGeometry(zoom: zoom, paneSize: pane, videoSize: video)
                for p in [CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.8), CGPoint(x: 1, y: 1)] {
                    let back = g.toPicture(g.toPane(p))
                    XCTAssertEqual(back.x, p.x, accuracy: 1e-9, "scale \(scale) pan \(pan)")
                    XCTAssertEqual(back.y, p.y, accuracy: 1e-9, "scale \(scale) pan \(pan)")
                }
            }
        }
    }

    /// The mapping must be the picture's own frame — the one the player layer
    /// is placed at — or marks drift off the snow when zooming.
    func testThePictureFrameIsTheZoomedLayerFrame() {
        let pane = CGSize(width: 800, height: 600)
        var zoom = VideoZoom()
        zoom.setScale(3, in: pane, videoSize: video)
        let g = DrawingGeometry(zoom: zoom, paneSize: pane, videoSize: video)
        XCTAssertEqual(g.pictureFrame, zoom.layerFrame(in: pane, videoSize: video))
        XCTAssertEqual(g.toPane(CGPoint(x: 0, y: 0)), g.pictureFrame.origin)
    }

    func testARightAngle() {
        let a = DrawingGeometry.angle(corner: CGPoint(x: 0.5, y: 0.5), a: CGPoint(x: 0.8, y: 0.5),
                                      b: CGPoint(x: 0.5, y: 0.1), videoSize: video)
        XCTAssertEqual(a, 90, accuracy: 1e-9)
    }

    /// 45° in pixels on a 16:9 picture is NOT 45° in normalized space: equal
    /// pixel offsets are (0.1, 0.1·16/9) in fractions. A normalized-space
    /// computation reads ~29.4° here.
    func testAnAngleIsMeasuredInPixelsNotFractions() {
        let corner = CGPoint(x: 0.5, y: 0.5)
        let a = CGPoint(x: 0.6, y: 0.5)
        let b = CGPoint(x: 0.6, y: 0.5 - 0.1 * 1920 / 1080)
        XCTAssertEqual(DrawingGeometry.angle(corner: corner, a: a, b: b, videoSize: video), 45, accuracy: 1e-6)
    }

    func testADegenerateArmReadsZeroRatherThanNaN() {
        let p = CGPoint(x: 0.5, y: 0.5)
        XCTAssertEqual(DrawingGeometry.angle(corner: p, a: p, b: CGPoint(x: 0.9, y: 0.5), videoSize: video), 0)
    }

    func testHitFindsALineNearItsSegmentAndPrefersTheTopmost() {
        let g = DrawingGeometry(pictureFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000), videoSize: video)
        let under = Drawing(kind: .line, color: .red, points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5)], start: 0)
        let over = Drawing(kind: .line, color: .blue, points: [CGPoint(x: 0.5, y: 0.1), CGPoint(x: 0.5, y: 0.9)], start: 0)
        XCTAssertEqual(g.hit(CGPoint(x: 300, y: 510), in: [under, over]), under.id)
        XCTAssertEqual(g.hit(CGPoint(x: 500, y: 500), in: [under, over]), over.id, "the later mark is drawn on top")
        XCTAssertNil(g.hit(CGPoint(x: 300, y: 600), in: [under, over]))
    }

    func testHitFindsAnAngleByEitherArm() {
        let g = DrawingGeometry(pictureFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000), videoSize: video)
        let angle = Drawing(kind: .angle, color: .red,
                            points: [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.9, y: 0.5), CGPoint(x: 0.5, y: 0.1)], start: 0)
        XCTAssertEqual(g.hit(CGPoint(x: 700, y: 505), in: [angle]), angle.id)
        XCTAssertEqual(g.hit(CGPoint(x: 505, y: 300), in: [angle]), angle.id)
        XCTAssertNil(g.hit(CGPoint(x: 700, y: 300), in: [angle]), "the space between the arms is not the mark")
    }

    func testHandlesAreOfferedForLinesAndAnglesOnly() {
        let g = DrawingGeometry(pictureFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000), videoSize: video)
        let line = Drawing(kind: .line, color: .red, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.9)], start: 0)
        XCTAssertEqual(g.handle(CGPoint(x: 905, y: 895), of: line), 1)
        XCTAssertNil(g.handle(CGPoint(x: 500, y: 500), of: line), "the middle of a line is not a handle")
        let pen = Drawing(kind: .pen, color: .red, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.9)], start: 0)
        XCTAssertNil(g.handle(CGPoint(x: 100, y: 100), of: pen), "pen strokes cannot be reshaped")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SkiVideoCoreTests.DrawingGeometryTests`
Expected: compile failure — `DrawingGeometry` not defined.

- [ ] **Step 3: Implement**

```swift
import CoreGraphics
import Foundation

/// Where the picture is on screen, and the arithmetic that hangs off it.
///
/// Built from `VideoZoom.layerFrame` — the same rectangle the player layer is
/// placed at — so marks and picture cannot drift apart: there is one answer to
/// "where is the picture", and both use it.
public struct DrawingGeometry: Equatable, Sendable {
    /// A fingertip's worth of slack, in screen points, for hits and handles.
    public static let touchTolerance: CGFloat = 22

    public let pictureFrame: CGRect
    public let videoSize: CGSize

    public init(zoom: VideoZoom, paneSize: CGSize, videoSize: CGSize) {
        self.init(pictureFrame: zoom.layerFrame(in: paneSize, videoSize: videoSize), videoSize: videoSize)
    }

    public init(pictureFrame: CGRect, videoSize: CGSize) {
        self.pictureFrame = pictureFrame
        self.videoSize = videoSize
    }

    public func toPane(_ p: CGPoint) -> CGPoint {
        CGPoint(x: pictureFrame.minX + p.x * pictureFrame.width,
                y: pictureFrame.minY + p.y * pictureFrame.height)
    }

    public func toPicture(_ q: CGPoint) -> CGPoint {
        guard pictureFrame.width > 0, pictureFrame.height > 0 else { return .zero }
        return CGPoint(x: (q.x - pictureFrame.minX) / pictureFrame.width,
                       y: (q.y - pictureFrame.minY) / pictureFrame.height)
    }

    /// Degrees between the two arms, 0…180, in the clip's *pixel* space. In
    /// fractions a 16:9 picture's axes have different units, and the answer
    /// would be skewed — see `testAnAngleIsMeasuredInPixelsNotFractions`.
    public static func angle(corner: CGPoint, a: CGPoint, b: CGPoint, videoSize: CGSize) -> Double {
        let u = CGVector(dx: (a.x - corner.x) * videoSize.width, dy: (a.y - corner.y) * videoSize.height)
        let v = CGVector(dx: (b.x - corner.x) * videoSize.width, dy: (b.y - corner.y) * videoSize.height)
        let lu = hypot(u.dx, u.dy), lv = hypot(v.dx, v.dy)
        guard lu > 0, lv > 0 else { return 0 }
        let cosine = max(-1, min(1, (u.dx * v.dx + u.dy * v.dy) / (lu * lv)))
        return acos(Double(cosine)) * 180 / .pi
    }

    /// The topmost mark within `tolerance` screen points of `q`. Later marks
    /// are drawn over earlier ones, so the search runs backwards.
    public func hit(_ q: CGPoint, in drawings: [Drawing], tolerance: CGFloat = touchTolerance) -> UUID? {
        drawings.reversed().first { distance(from: q, to: $0) <= tolerance }?.id
    }

    /// Which point of a line or angle `q` grabs. Pen strokes and text have
    /// none: reshaping a stroke is out of scope.
    public func handle(_ q: CGPoint, of drawing: Drawing, tolerance: CGFloat = touchTolerance) -> Int? {
        guard drawing.kind == .line || drawing.kind == .angle else { return nil }
        let distances = drawing.points.map { hypot(toPane($0).x - q.x, toPane($0).y - q.y) }
        guard let best = distances.indices.min(by: { distances[$0] < distances[$1] }),
              distances[best] <= tolerance else { return nil }
        return best
    }

    private func distance(from q: CGPoint, to drawing: Drawing) -> CGFloat {
        let points = drawing.points.map(toPane)
        switch drawing.kind {
        case .text:
            // Text is drawn centred on its anchor; about 5pt per character
            // either side is the half-width at the overlay's font size.
            guard let anchor = points.first else { return .infinity }
            let halfWidth = max(Self.touchTolerance, CGFloat(drawing.text.count) * 5)
            return abs(q.x - anchor.x) <= halfWidth ? abs(q.y - anchor.y) : .infinity
        case .angle:
            guard let corner = points.first else { return .infinity }
            return points.dropFirst().map { Self.distance(q, corner, $0) }.min() ?? .infinity
        case .line, .pen:
            guard points.count > 1 else { return points.first.map { hypot($0.x - q.x, $0.y - q.y) } ?? .infinity }
            return zip(points, points.dropFirst()).map { Self.distance(q, $0, $1) }.min() ?? .infinity
        }
    }

    private static func distance(_ q: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = CGVector(dx: b.x - a.x, dy: b.y - a.y)
        let lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy
        guard lengthSquared > 0 else { return hypot(q.x - a.x, q.y - a.y) }
        let t = max(0, min(1, ((q.x - a.x) * ab.dx + (q.y - a.y) * ab.dy) / lengthSquared))
        return hypot(q.x - (a.x + t * ab.dx), q.y - (a.y + t * ab.dy))
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SkiVideoCoreTests.DrawingGeometryTests`
Expected: all pass. If `testRoundTripAtSeveralZoomsAndPans` fails only at the letterboxed scale-1 case, check `layerFrame` returns a non-zero size for that pane before changing anything.

- [ ] **Step 5: Commit**

```bash
git add Sources/SkiVideoCore/DrawingGeometry.swift Tests/SkiVideoCoreTests/DrawingGeometryTests.swift
git commit -m "Map drawings through the zoomed picture frame and measure angles in pixels"
```

---

### Task 3: The drawings file

**Files:**
- Create: `Sources/SkiVideoCore/ClipDrawingsStore.swift`
- Test: `Tests/SkiVideoCoreTests/ClipDrawingsStoreTests.swift`

**Interfaces:**
- Consumes: `ClipDrawings`, `ClipIdentity` (`.local(URL)`, `.remote(provider:fileID:)`, `storeKey`, `pairKey`, `ClipIdentity.keyedStoreRoot` — a settable `static var`).
- Produces: `enum ClipDrawingsLoad: Equatable { case none, drawings(ClipDrawings), unreadable }`, `enum ClipDrawingsStore` with `fileExtension`, `fileURL(for:)`, `load(for:) -> ClipDrawingsLoad`, `save(_:for:) throws`; `enum ClipDrawingsStoreError: Error { case wouldOverwriteUnreadable }`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import SkiVideoCore

final class ClipDrawingsStoreTests: XCTestCase {
    private var directory: URL!
    private var savedKeyedRoot: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        savedKeyedRoot = ClipIdentity.keyedStoreRoot
        ClipIdentity.keyedStoreRoot = directory.appendingPathComponent("keyed", isDirectory: true)
    }

    override func tearDownWithError() throws {
        ClipIdentity.keyedStoreRoot = savedKeyedRoot
        try? FileManager.default.removeItem(at: directory)
    }

    private var clip: ClipIdentity { ClipIdentity(directory.appendingPathComponent("C0094.MP4")) }
    private var sample: ClipDrawings {
        ClipDrawings(drawings: [Drawing(kind: .line, color: .red,
                                        points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)], start: 1)])
    }

    func testALocalClipsFileSitsBesideItByStem() {
        XCTAssertEqual(ClipDrawingsStore.fileURL(for: clip).lastPathComponent, "C0094.skidrawings.json")
        XCTAssertEqual(ClipDrawingsStore.fileURL(for: clip).deletingLastPathComponent().standardizedFileURL,
                       directory.standardizedFileURL)
    }

    func testNoFileReadsAsNone() {
        XCTAssertEqual(ClipDrawingsStore.load(for: clip), .none)
    }

    func testRoundTrip() throws {
        try ClipDrawingsStore.save(sample, for: clip)
        XCTAssertEqual(ClipDrawingsStore.load(for: clip), .drawings(sample))
    }

    func testADriveClipGoesToTheKeyedStore() throws {
        let remote = ClipIdentity.remote(provider: "drive", fileID: "abc")
        try ClipDrawingsStore.save(sample, for: remote)
        XCTAssertTrue(ClipDrawingsStore.fileURL(for: remote).path.hasPrefix(ClipIdentity.keyedStoreRoot.path))
        XCTAssertEqual(ClipDrawingsStore.load(for: remote), .drawings(sample))
    }

    func testSavingNothingDeletesTheFile() throws {
        try ClipDrawingsStore.save(sample, for: clip)
        try ClipDrawingsStore.save(ClipDrawings(), for: clip)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ClipDrawingsStore.fileURL(for: clip).path))
        XCTAssertEqual(ClipDrawingsStore.load(for: clip), .none)
    }

    func testAGarbledFileIsUnreadableAndNeverOverwritten() throws {
        let url = ClipDrawingsStore.fileURL(for: clip)
        try Data("{ not json".utf8).write(to: url)
        XCTAssertEqual(ClipDrawingsStore.load(for: clip), .unreadable)
        XCTAssertThrowsError(try ClipDrawingsStore.save(sample, for: clip)) {
            XCTAssertEqual($0 as? ClipDrawingsStoreError, .wouldOverwriteUnreadable)
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("{ not json".utf8))
    }

    /// Review Focus 4: a newer app's file must survive this one.
    func testAFileFromANewerVersionIsUnreadable() throws {
        let url = ClipDrawingsStore.fileURL(for: clip)
        try Data(#"{"version":2,"drawings":[]}"#.utf8).write(to: url)
        XCTAssertEqual(ClipDrawingsStore.load(for: clip), .unreadable)
        XCTAssertThrowsError(try ClipDrawingsStore.save(ClipDrawings(), for: clip))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "deleting is overwriting too")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SkiVideoCoreTests.ClipDrawingsStoreTests`
Expected: compile failure.

- [ ] **Step 3: Implement**

```swift
import Foundation

public enum ClipDrawingsLoad: Equatable, Sendable {
    case none
    case drawings(ClipDrawings)
    /// Present but not parseable by this version — damaged, hand-edited, or
    /// written by a newer app. Never overwritten.
    case unreadable
}

public enum ClipDrawingsStoreError: Error, Equatable {
    case wouldOverwriteUnreadable
}

/// Reads and writes `<stem>.skidrawings.json`, shaped like
/// `ClipAnalysisStore`: beside a local clip so it travels with the footage
/// (and moves with it on an event rename, which carries every `<stem>.` file),
/// in the keyed store for a Drive clip, which has no folder of its own here.
public enum ClipDrawingsStore {
    public static let fileExtension = "skidrawings.json"

    public static func fileURL(for identity: ClipIdentity) -> URL {
        switch identity {
        case let .local(clip):
            return clip.deletingPathExtension().appendingPathExtension(fileExtension)
        case .remote:
            return ClipIdentity.keyedStoreRoot
                .appendingPathComponent(identity.pairKey)
                .appendingPathExtension(fileExtension)
        }
    }

    public static func load(for identity: ClipIdentity) -> ClipDrawingsLoad {
        let url = fileURL(for: identity)
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        guard let data = try? Data(contentsOf: url),
              let drawings = try? JSONDecoder().decode(ClipDrawings.self, from: data),
              drawings.version <= ClipDrawings.currentVersion
        else { return .unreadable }
        return .drawings(drawings)
    }

    /// Atomic. An empty set deletes the file rather than leaving `[]` behind.
    /// Refuses to replace or delete a file `load` could not read: it may be a
    /// newer version's, and this one cannot know what it would destroy.
    public static func save(_ drawings: ClipDrawings, for identity: ClipIdentity) throws {
        if load(for: identity) == .unreadable { throw ClipDrawingsStoreError.wouldOverwriteUnreadable }
        let url = fileURL(for: identity)
        if drawings.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        if identity.storeKey != nil {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(drawings).write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: Run to verify they pass** — same command; all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SkiVideoCore/ClipDrawingsStore.swift Tests/SkiVideoCoreTests/ClipDrawingsStoreTests.swift
git commit -m "Save a clip's drawings beside it and never overwrite one it cannot read"
```

---

### Task 4: The editing session

**Files:**
- Create: `Sources/SkiVideoCore/DrawingSession.swift`
- Test: `Tests/SkiVideoCoreTests/DrawingSessionTests.swift`

**Interfaces:**
- Consumes: `Drawing`, `ClipDrawings`, `DrawingGeometry`.
- Produces: `enum DrawingTool: String, CaseIterable { case move, pen, line, angle, text }`; `@MainActor final class DrawingSession: ObservableObject` with published `tool`, `color`, `arrowheads`, `drawings` (private set), `inProgress: Drawing?`, `selection: UUID?`, `editingText: Drawing?`, `awaitingSecondArm: Bool`; `canUndo`, `canRedo`; methods `dragBegan(at:geometry:time:)`, `dragChanged(to:geometry:)`, `dragEnded(at:geometry:)`, `tapped(at:geometry:time:frameDuration:)`, `finishText(_:)`, `deleteSelection()`, `stretch(from:to:frameDuration:)`, `clear(at:frameDuration:)`, `cancelInProgress()`, `undo()`, `redo()`. All gesture points are **pane** points; `time` is the frame-snapped playhead.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import SkiVideoCore

@MainActor
final class DrawingSessionTests: XCTestCase {
    private let frame = 1.0 / 30
    /// A 1000×1000 picture at the pane's origin: pane points / 1000 = fractions.
    private let g = DrawingGeometry(pictureFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                                    videoSize: CGSize(width: 1000, height: 1000))

    private func drag(_ s: DrawingSession, _ from: CGPoint, _ to: CGPoint, time: Double = 1) {
        s.dragBegan(at: from, geometry: g, time: time)
        s.dragChanged(to: CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2), geometry: g)
        s.dragEnded(at: to, geometry: g)
    }

    func testALineIsCommittedWithTheArrowheadSetting() {
        let s = DrawingSession()
        s.tool = .line
        drag(s, CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 100))
        XCTAssertEqual(s.drawings.drawings.count, 1)
        let line = s.drawings.drawings[0]
        XCTAssertEqual(line.kind, .line)
        XCTAssertTrue(line.arrow, "arrowheads are on by default")
        XCTAssertEqual(line.points, [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.5, y: 0.1)])
        XCTAssertEqual(line.start, 1)
        XCTAssertNil(s.inProgress)
    }

    func testATooShortLineIsDiscarded() {
        let s = DrawingSession()
        s.tool = .line
        drag(s, CGPoint(x: 100, y: 100), CGPoint(x: 104, y: 100))
        XCTAssertTrue(s.drawings.isEmpty)
    }

    func testPenPointsCloserThanTwoScreenPointsAreDropped() {
        let s = DrawingSession()
        s.tool = .pen
        s.dragBegan(at: CGPoint(x: 100, y: 100), geometry: g, time: 0)
        s.dragChanged(to: CGPoint(x: 101, y: 100), geometry: g)   // dropped
        s.dragChanged(to: CGPoint(x: 110, y: 100), geometry: g)
        s.dragEnded(at: CGPoint(x: 110, y: 100), geometry: g)      // same point: dropped
        XCTAssertEqual(s.drawings.drawings.first?.points.count, 2)
    }

    func testAnAngleTakesADragThenATap() {
        let s = DrawingSession()
        s.tool = .angle
        drag(s, CGPoint(x: 500, y: 500), CGPoint(x: 800, y: 500))
        XCTAssertTrue(s.awaitingSecondArm)
        XCTAssertTrue(s.drawings.isEmpty, "not committed until the second arm is placed")
        XCTAssertEqual(s.inProgress?.points.count, 2)
        s.tapped(at: CGPoint(x: 500, y: 100), geometry: g, time: 1, frameDuration: frame)
        XCTAssertFalse(s.awaitingSecondArm)
        let angle = s.drawings.drawings[0]
        XCTAssertEqual(angle.points.count, 3)
        XCTAssertEqual(DrawingGeometry.angle(corner: angle.points[0], a: angle.points[1], b: angle.points[2],
                                             videoSize: g.videoSize), 90, accuracy: 1e-9)
    }

    func testAnAnglesSecondArmCanBeDraggedInstead() {
        let s = DrawingSession()
        s.tool = .angle
        drag(s, CGPoint(x: 500, y: 500), CGPoint(x: 800, y: 500))
        drag(s, CGPoint(x: 500, y: 450), CGPoint(x: 500, y: 100))
        XCTAssertEqual(s.drawings.drawings.first?.points.last, CGPoint(x: 0.5, y: 0.1))
    }

    func testSwitchingToolAbandonsAHalfPlacedAngle() {
        let s = DrawingSession()
        s.tool = .angle
        drag(s, CGPoint(x: 500, y: 500), CGPoint(x: 800, y: 500))
        s.tool = .line
        XCTAssertFalse(s.awaitingSecondArm)
        XCTAssertNil(s.inProgress)
    }

    func testATapSelectsAndATapOnNothingDeselects() {
        let s = DrawingSession()
        s.tool = .line
        drag(s, CGPoint(x: 100, y: 500), CGPoint(x: 900, y: 500))
        s.tapped(at: CGPoint(x: 500, y: 505), geometry: g, time: 1, frameDuration: frame)
        XCTAssertEqual(s.selection, s.drawings.drawings[0].id)
        s.tapped(at: CGPoint(x: 500, y: 900), geometry: g, time: 1, frameDuration: frame)
        XCTAssertNil(s.selection)
    }

    func testOnlyMarksOnThisFrameCanBeSelected() {
        let s = DrawingSession()
        s.tool = .line
        drag(s, CGPoint(x: 100, y: 500), CGPoint(x: 900, y: 500), time: 5)
        s.tapped(at: CGPoint(x: 500, y: 500), geometry: g, time: 1, frameDuration: frame)
        XCTAssertNil(s.selection)
    }

    func testDraggingASelectedLinesHandleMovesThatPoint() {
        let s = DrawingSession()
        s.tool = .line
        drag(s, CGPoint(x: 100, y: 500), CGPoint(x: 900, y: 500))
        s.tapped(at: CGPoint(x: 500, y: 500), geometry: g, time: 1, frameDuration: frame)
        drag(s, CGPoint(x: 900, y: 500), CGPoint(x: 900, y: 200))
        XCTAssertEqual(s.drawings.drawings.count, 1, "a handle drag must not start a new line")
        XCTAssertEqual(s.drawings.drawings[0].points[1], CGPoint(x: 0.9, y: 0.2))
    }

    func testDeleteRemovesTheSelection() {
        let s = DrawingSession()
        s.tool = .line
        drag(s, CGPoint(x: 100, y: 500), CGPoint(x: 900, y: 500))
        s.tapped(at: CGPoint(x: 500, y: 500), geometry: g, time: 1, frameDuration: frame)
        s.deleteSelection()
        XCTAssertTrue(s.drawings.isEmpty)
        XCTAssertNil(s.selection)
    }

    func testTextIsCommittedOnlyWhenItHasWords() {
        let s = DrawingSession()
        s.tool = .text
        s.tapped(at: CGPoint(x: 300, y: 300), geometry: g, time: 1, frameDuration: frame)
        XCTAssertNotNil(s.editingText)
        s.finishText("   ")
        XCTAssertTrue(s.drawings.isEmpty)
        s.tapped(at: CGPoint(x: 300, y: 300), geometry: g, time: 1, frameDuration: frame)
        s.finishText("Hips forward")
        XCTAssertEqual(s.drawings.drawings.first?.text, "Hips forward")
    }

    func testTappingExistingTextEditsItAndEmptyingItDeletesIt() {
        let s = DrawingSession()
        s.tool = .text
        s.tapped(at: CGPoint(x: 300, y: 300), geometry: g, time: 1, frameDuration: frame)
        s.finishText("Edge")
        s.tapped(at: CGPoint(x: 300, y: 300), geometry: g, time: 1, frameDuration: frame)
        XCTAssertEqual(s.editingText?.text, "Edge")
        s.finishText("")
        XCTAssertTrue(s.drawings.isEmpty)
    }

    func testUndoAndRedoCoverDrawStretchAndClear() {
        let s = DrawingSession()
        s.tool = .line
        drag(s, CGPoint(x: 100, y: 500), CGPoint(x: 900, y: 500), time: 1)
        s.stretch(from: 1, to: 1 + frame, frameDuration: frame)
        s.clear(at: 1, frameDuration: frame)
        XCTAssertTrue(s.drawings.isEmpty)
        s.undo()
        XCTAssertEqual(s.drawings.drawings.first?.end ?? 0, 1 + frame, accuracy: 1e-9)
        s.undo()
        XCTAssertEqual(s.drawings.drawings.first?.end, 1)
        s.undo()
        XCTAssertTrue(s.drawings.isEmpty)
        XCTAssertFalse(s.canUndo)
        s.redo()
        XCTAssertEqual(s.drawings.drawings.count, 1)
        XCTAssertTrue(s.canRedo)
    }

    func testAStretchThatChangesNothingIsNotAnUndoStep() {
        let s = DrawingSession()
        s.stretch(from: 1, to: 1 + frame, frameDuration: frame)
        XCTAssertFalse(s.canUndo)
    }

    func testTheMoveToolDrawsNothing() {
        let s = DrawingSession()
        s.tool = .move
        drag(s, CGPoint(x: 100, y: 100), CGPoint(x: 600, y: 600))
        XCTAssertTrue(s.drawings.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SkiVideoCoreTests.DrawingSessionTests`
Expected: compile failure.

- [ ] **Step 3: Implement**

```swift
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
    private var draggedHandle: (id: UUID, index: Int)?
    private var lastPenPoint: CGPoint?

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public init(drawings: ClipDrawings = ClipDrawings()) {
        self.drawings = drawings
    }

    // MARK: Gestures

    public func dragBegan(at q: CGPoint, geometry: DrawingGeometry, time: Double) {
        let p = geometry.toPicture(q)
        if let selection, let selected = drawing(selection), let index = geometry.handle(q, of: selected) {
            record()
            draggedHandle = (selection, index)
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
            awaitingSecondArm = false
            commit(mark)
        case .text:
            inProgress = nil
        }
    }

    public func tapped(at q: CGPoint, geometry: DrawingGeometry, time: Double, frameDuration: Double) {
        let p = geometry.toPicture(q)
        if awaitingSecondArm, var angle = inProgress {
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
```

- [ ] **Step 4: Run to verify they pass** — same command; all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SkiVideoCore/DrawingSession.swift Tests/SkiVideoCoreTests/DrawingSessionTests.swift
git commit -m "Add the drawing session: tools, three-point angles, text, selection and undo"
```

---

### Task 5: Frame stepping, frame duration and picture size in the viewer

**Files:**
- Modify: `Sources/SkiVideoCore/ViewerModel.swift` (published state near `zoom` at ~line 56; `loadCurrentVideo` at ~line 1577; new `stepFrame` beside `scrub(to:)` at ~line 1455)
- Test: `Tests/SkiVideoCoreTests/ViewerFrameStepTests.swift`

**Interfaces:**
- Consumes: `ClipDrawings.snap`, `ClipDrawings.fallbackFrameDuration`, `ScrubDirection`.
- Produces on `ViewerModel`: `@Published public private(set) var frameDuration: Double`, `@Published public private(set) var pictureSize: CGSize`, `public func stepFrame(_ direction: ScrubDirection)`, `var onFrameStep: ((Double, Double) -> Void)?` (internal hook Task 6 uses; arguments `from`, `to`).

- [ ] **Step 1: Write the failing tests**

```swift
import AVFoundation
import XCTest
@testable import SkiVideoCore

/// Against real media: frame rate and presentation size come from the track.
@MainActor
final class ViewerFrameStepTests: XCTestCase {
    private var temporaryDirectory: URL?

    override func tearDown() {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        temporaryDirectory = nil
        super.tearDown()
    }

    private func makeLoadedModel(seconds: Double = 2, fps: Int32 = 25) throws -> ViewerModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        temporaryDirectory = root
        _ = try makeRealVideoFile(in: root.appendingPathComponent("Athlete", isDirectory: true),
                                  name: "run1.mov", seconds: seconds, fps: fps)
        let model = ViewerModel(input: FakeInputSource(), folderPicker: FakeFolderPicker(),
                                oauthPresenter: FakeOAuthPresenter())
        model.openDirectory(root)
        waitUntil("the clip must load") { model.duration > 0 && model.pictureSize != .zero }
        return model
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 20, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition(), message)
    }

    func testFrameDurationAndPictureSizeComeFromTheTrack() throws {
        let model = try makeLoadedModel(fps: 25)
        waitUntil("the frame rate must be read") { abs(model.frameDuration - 1.0 / 25) < 1e-6 }
        XCTAssertEqual(model.pictureSize, CGSize(width: 160, height: 90))
    }

    func testAStepForwardMovesExactlyOneFrame() throws {
        let model = try makeLoadedModel(fps: 25)
        waitUntil("the frame rate must be read") { abs(model.frameDuration - 1.0 / 25) < 1e-6 }
        model.stepFrame(.forward)
        XCTAssertEqual(model.currentTime, 1.0 / 25, accuracy: 1e-9)
        waitUntil("the player must land on the frame") { abs(model.player.currentTime().seconds - 1.0 / 25) < 0.002 }
    }

    /// Review Focus 1: no movement, and no step reported, at either end.
    func testStepsStopAtBothEnds() throws {
        let model = try makeLoadedModel(seconds: 1, fps: 25)
        waitUntil("the frame rate must be read") { abs(model.frameDuration - 1.0 / 25) < 1e-6 }
        var steps: [(Double, Double)] = []
        model.onFrameStep = { steps.append(($0, $1)) }
        model.stepFrame(.backward)
        XCTAssertEqual(model.currentTime, 0)
        XCTAssertTrue(steps.isEmpty)
        model.scrub(to: model.duration)
        model.stepFrame(.forward)
        XCTAssertTrue(steps.isEmpty, "the last frame has no frame after it")
    }

    func testAStepReportsWhereItCameFromAndWentTo() throws {
        let model = try makeLoadedModel(fps: 25)
        waitUntil("the frame rate must be read") { abs(model.frameDuration - 1.0 / 25) < 1e-6 }
        var steps: [(Double, Double)] = []
        model.onFrameStep = { steps.append(($0, $1)) }
        model.stepFrame(.forward)
        model.stepFrame(.forward)
        model.stepFrame(.backward)
        XCTAssertEqual(steps.count, 3)
        for (got, want) in zip(steps.map(\.1), [1.0 / 25, 2.0 / 25, 1.0 / 25]) {
            XCTAssertEqual(got, want, accuracy: 1e-9)
        }
        XCTAssertEqual(steps.first?.0, 0)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SkiVideoCoreTests.ViewerFrameStepTests`
Expected: compile failure — `pictureSize`, `frameDuration`, `stepFrame`, `onFrameStep` missing.

- [ ] **Step 3: Implement**

In `ViewerModel`, after `@Published public private(set) var zoom = VideoZoom()`:

```swift
    /// One frame of the current clip, from its video track's nominal rate;
    /// `ClipDrawings.fallbackFrameDuration` until that is read or when the
    /// track reports none. Drives frame stepping and drawing visibility.
    @Published public private(set) var frameDuration = ClipDrawings.fallbackFrameDuration

    /// The current clip's `presentationSize`, published because the drawing
    /// overlay needs it to place marks and `AVPlayerItem` reports it only by
    /// KVO. `.zero` until the item has loaded — drawing is refused until then.
    @Published public private(set) var pictureSize: CGSize = .zero

    /// Called after every frame step with the frame-snapped times it moved
    /// from and to. The drawing controller stretches marks from here.
    var onFrameStep: ((Double, Double) -> Void)?
```

Add `private var presentationSizeObserver: NSKeyValueObservation?` beside `durationObserver`.

In `loadCurrentVideo`, after `duration = 0` add `pictureSize = .zero` and `frameDuration = ClipDrawings.fallbackFrameDuration`; after `observeDuration(of: item)` add:

```swift
        observePresentationSize(of: item)
        loadFrameDuration(of: playbackURL)
```

Beside `observeDuration`:

```swift
    private func observePresentationSize(of item: AVPlayerItem) {
        presentationSizeObserver = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item else { return }
                self.pictureSize = item.presentationSize
            }
        }
    }

    /// Asynchronous like `checkPlayability`, and guarded the same way: the
    /// coach may have moved on before the track loads.
    private func loadFrameDuration(of url: URL) {
        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let rate = try? await track.load(.nominalFrameRate), rate > 0
            else { return }
            guard let self, self.currentPlaybackURL == url else { return }
            self.frameDuration = 1 / Double(rate)
        }
    }
```

Beside `scrub(to:)`:

```swift
    /// Exactly one frame, as an exact seek to the neighbouring frame boundary.
    /// Not `AVPlayerItem.step(byCount:)`: drawing mode stretches marks from
    /// one frame to the next, and `step` reports neither time.
    public func stepFrame(_ direction: ScrubDirection) {
        guard player.currentItem != nil, duration > 0 else { return }
        if player.rate != 0 { player.pause() }
        let from = ClipDrawings.snap(currentTime, frameDuration: frameDuration)
        let lastFrame = ClipDrawings.snap(max(0, duration - frameDuration), frameDuration: frameDuration)
        let to = min(max(0, from + Double(direction.rawValue) * frameDuration), lastFrame)
        // In the step's own direction only: scrubbed to the very end, `from`
        // can sit past `lastFrame`, and clamping would otherwise turn a step
        // forward into a step back.
        guard (to - from) * Double(direction.rawValue) > frameDuration / 2 else { return }
        scrub(to: to)
        status = "Frame \(Int((to / frameDuration).rounded()) + 1)"
        onFrameStep?(from, to)
    }
```

- [ ] **Step 4: Run to verify they pass** — same command; all pass. Then run `--filter SkiVideoCoreTests.ViewerTransportTests` to confirm nothing regressed.

- [ ] **Step 5: Commit**

```bash
git add Sources/SkiVideoCore/ViewerModel.swift Tests/SkiVideoCoreTests/ViewerFrameStepTests.swift
git commit -m "Step the viewer one frame at a time and publish frame rate and picture size"
```

---

### Task 6: The drawing controller and drawing mode in the viewer

**Files:**
- Create: `Sources/SkiVideoCore/DrawingController.swift`
- Modify: `Sources/SkiVideoCore/Seams.swift` (add `case toggleDrawing` to `PlaybackIntent`)
- Modify: `Sources/SkiVideoCore/ViewerModel.swift` (`init`, `handle(_:)`, `applyTransport`, `loadCurrentVideo`)
- Modify: `Tests/SkiVideoCoreTests/CorePurityTests.swift` (`testSeamsAreReachableFromTests`: add `.toggleDrawing`, count 9)
- Test: `Tests/SkiVideoCoreTests/DrawingControllerTests.swift`

**Interfaces:**
- Consumes: `DrawingSession`, `ClipDrawingsStore`, `ClipIdentity`, `ViewerModel.onFrameStep`, `stepFrame`, `pictureSize`, `frameDuration`, `currentClipIdentity`.
- Produces: `@MainActor final class DrawingController: ObservableObject` — published `isDrawing` (private set), `showsDrawings` (settable, persisted under `"ShowDrawings"`), `session: DrawingSession?` (private set), `notice: String?` (private set); `init(defaults:saveDelay:)`, `load(for:)`, `saveNow()`, `static let unreadableNotice`. On `ViewerModel`: `public let drawing: DrawingController`, `public func setDrawing(_ on: Bool)`, `public var canDraw: Bool`; `init` gains `drawing: DrawingController? = nil`.

- [ ] **Step 1: Write the failing tests**

```swift
import AVFoundation
import XCTest
@testable import SkiVideoCore

@MainActor
final class DrawingControllerTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defaults = UserDefaults(suiteName: "DrawingControllerTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func clip(_ name: String) -> URL { root.appendingPathComponent("Athlete/\(name)") }

    private func makeModel(clips: [String] = ["run1.mov", "run2.mov"]) throws -> ViewerModel {
        for name in clips {
            _ = try makeRealVideoFile(in: root.appendingPathComponent("Athlete", isDirectory: true),
                                      name: name, seconds: 2, fps: 25)
        }
        let model = ViewerModel(input: FakeInputSource(), folderPicker: FakeFolderPicker(),
                                oauthPresenter: FakeOAuthPresenter(),
                                drawing: DrawingController(defaults: defaults, saveDelay: 0.05))
        model.openDirectory(root)
        waitUntil("the clip must load") { model.pictureSize != .zero && abs(model.frameDuration - 0.04) < 1e-6 }
        return model
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 20, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition(), message)
    }

    private let g = DrawingGeometry(pictureFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                                    videoSize: CGSize(width: 160, height: 90))

    private func drawALine(_ model: ViewerModel) {
        let session = model.drawing.session!
        session.tool = .line
        session.dragBegan(at: CGPoint(x: 100, y: 500), geometry: g, time: model.currentTime)
        session.dragEnded(at: CGPoint(x: 900, y: 500), geometry: g)
    }

    func testEnteringDrawingModePauses() throws {
        let model = try makeModel()
        model.applyTransport(.playPause)
        model.setDrawing(true)
        XCTAssertTrue(model.drawing.isDrawing)
        XCTAssertEqual(model.player.rate, 0)
    }

    func testSteppingWhileDrawingStretchesTheMarksOnScreen() throws {
        let model = try makeModel()
        model.setDrawing(true)
        drawALine(model)
        model.stepFrame(.forward)
        model.stepFrame(.forward)
        let line = model.drawing.session!.drawings.drawings[0]
        XCTAssertEqual(line.start, 0)
        XCTAssertEqual(line.end, 0.08, accuracy: 1e-9)
    }

    func testSteppingOutsideDrawingModeStretchesNothing() throws {
        let model = try makeModel()
        model.setDrawing(true)
        drawALine(model)
        model.setDrawing(false)
        model.stepFrame(.forward)
        XCTAssertEqual(model.drawing.session!.drawings.drawings[0].end, 0)
    }

    func testTheArrowKeysStepFramesOnlyWhileDrawing() throws {
        let model = try makeModel()
        model.setDrawing(true)
        model.handle(.seek(.forward))
        XCTAssertEqual(model.currentTime, 0.04, accuracy: 1e-9)
    }

    func testPlayLeavesDrawingModeAndSaves() throws {
        let model = try makeModel()
        model.setDrawing(true)
        drawALine(model)
        model.handle(.togglePlayback)
        XCTAssertFalse(model.drawing.isDrawing)
        XCTAssertNotEqual(model.player.rate, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: clip("run1.skidrawings.json").path))
    }

    func testTheDKeyIntentToggles() throws {
        let model = try makeModel()
        model.handle(.toggleDrawing)
        XCTAssertTrue(model.drawing.isDrawing)
        model.handle(.toggleDrawing)
        XCTAssertFalse(model.drawing.isDrawing)
    }

    func testAChangeIsSavedAfterTheDebounce() throws {
        let model = try makeModel()
        model.setDrawing(true)
        drawALine(model)
        waitUntil("the debounced save must write the file") {
            FileManager.default.fileExists(atPath: self.clip("run1.skidrawings.json").path)
        }
    }

    /// Review Focus 2: the old clip keeps its committed marks; the half-drawn
    /// one is dropped; the new clip starts clean.
    func testSwitchingClipSavesToTheOldClipAndDropsAHalfDrawnMark() throws {
        let model = try makeModel()
        model.setDrawing(true)
        drawALine(model)
        model.drawing.session!.dragBegan(at: CGPoint(x: 10, y: 10), geometry: g, time: 0)
        model.changeVideo(by: 1)
        XCTAssertFalse(model.drawing.isDrawing)
        XCTAssertEqual(ClipDrawingsStore.load(for: ClipIdentity(clip("run1.mov"))).drawingCount, 1)
        XCTAssertTrue(model.drawing.session?.drawings.isEmpty ?? false)
        XCTAssertEqual(ClipDrawingsStore.load(for: ClipIdentity(clip("run2.mov"))), .none)
    }

    func testReopeningAClipBringsItsDrawingsBack() throws {
        let model = try makeModel()
        model.setDrawing(true)
        drawALine(model)
        model.changeVideo(by: 1)
        model.changeVideo(by: -1)
        XCTAssertEqual(model.drawing.session?.drawings.drawings.count, 1)
    }

    /// Review Focus 3: the second `loadCurrentVideo` for the same clip (a
    /// Drive clip's bytes landing) must not reload and lose what is in memory.
    func testLoadingTheSameClipAgainKeepsTheSession() throws {
        let model = try makeModel()
        model.setDrawing(true)
        drawALine(model)
        let session = model.drawing.session
        model.drawing.load(for: model.currentClipIdentity)
        XCTAssertTrue(model.drawing.session === session)
    }

    func testAnUnreadableFileRefusesDrawingAndSaysSo() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Athlete"), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: clip("run1.skidrawings.json"))
        let model = try makeModel()
        XCTAssertNil(model.drawing.session)
        XCTAssertEqual(model.drawing.notice, DrawingController.unreadableNotice)
        model.setDrawing(true)
        XCTAssertFalse(model.drawing.isDrawing)
        XCTAssertEqual(try Data(contentsOf: clip("run1.skidrawings.json")), Data("garbage".utf8))
    }

    func testShowDrawingsIsRememberedAndOnByDefault() {
        let first = DrawingController(defaults: defaults)
        XCTAssertTrue(first.showsDrawings)
        first.showsDrawings = false
        XCTAssertFalse(DrawingController(defaults: defaults).showsDrawings)
    }
}

private extension ClipDrawingsLoad {
    var drawingCount: Int? {
        if case let .drawings(d) = self { return d.drawings.count }
        return nil
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SkiVideoCoreTests.DrawingControllerTests`
Expected: compile failure.

- [ ] **Step 3: Implement**

`Seams.swift`, in `PlaybackIntent` after `case openFolder`:

```swift
    /// Into or out of drawing mode — **D** on macOS.
    case toggleDrawing
```

`CorePurityTests.testSeamsAreReachableFromTests`: add `.toggleDrawing,` to the array and change `XCTAssertEqual(intents.count, 8)` to `9`.

`Sources/SkiVideoCore/DrawingController.swift`:

```swift
import Combine
import Foundation

/// The current clip's drawings: which session is live, whether the coach is
/// drawing, whether saved marks are shown, and getting them to disk.
///
/// Owned by `ViewerModel`, which tells it when the clip changes and when the
/// coach steps; a separate object so the viewer's 1,700-line model gains a
/// handful of calls rather than this whole lifecycle.
@MainActor
public final class DrawingController: ObservableObject {
    public static let unreadableNotice = "Drawings for this clip couldn't be read."
    private static let showKey = "ShowDrawings"

    @Published public private(set) var isDrawing = false
    @Published public var showsDrawings: Bool {
        didSet { defaults.set(showsDrawings, forKey: Self.showKey) }
    }
    /// Nil with no clip, and for a clip whose drawings file is unreadable —
    /// which is what refuses drawing there.
    @Published public private(set) var session: DrawingSession?
    @Published public private(set) var notice: String?

    private let defaults: UserDefaults
    private let saveDelay: TimeInterval
    private var identity: ClipIdentity?
    private var isDirty = false
    private var saveTask: Task<Void, Never>?
    private var observation: AnyCancellable?

    public init(defaults: UserDefaults = .standard, saveDelay: TimeInterval = 1) {
        self.defaults = defaults
        self.saveDelay = saveDelay
        showsDrawings = defaults.object(forKey: Self.showKey) as? Bool ?? true
    }

    /// Saves the previous clip's marks, then reads this one's. The same
    /// identity again is a no-op: a Drive clip's `loadCurrentVideo` runs twice
    /// (selected, then bytes landed), and reloading would discard the session.
    public func load(for identity: ClipIdentity?) {
        if let identity, identity == self.identity { return }
        session?.cancelInProgress()
        saveNow()
        isDrawing = false
        observation = nil
        session = nil
        notice = nil
        isDirty = false
        self.identity = identity
        guard let identity else { return }
        switch ClipDrawingsStore.load(for: identity) {
        case .none: attach(DrawingSession())
        case let .drawings(drawings): attach(DrawingSession(drawings: drawings))
        case .unreadable: notice = Self.unreadableNotice
        }
    }

    func enter() { isDrawing = true }

    func leave() {
        session?.cancelInProgress()
        isDrawing = false
        saveNow()
    }

    public func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard isDirty, let identity, let session else { return }
        do {
            try ClipDrawingsStore.save(session.drawings, for: identity)
            isDirty = false
            if notice?.hasPrefix("Couldn't save") == true { notice = nil }
        } catch {
            // Kept in memory and on screen; the next change retries.
            notice = "Couldn't save drawings: \(error.localizedDescription)"
        }
    }

    private func attach(_ session: DrawingSession) {
        self.session = session
        observation = session.$drawings.dropFirst().sink { [weak self] _ in
            self?.isDirty = true
            self?.scheduleSave()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let delay = UInt64(saveDelay * 1_000_000_000)
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }
}
```

`ViewerModel`:

- Property: `public let drawing: DrawingController`.
- `init` gains a last parameter `drawing: DrawingController? = nil`; body: `self.drawing = drawing ?? DrawingController()` before the `input.onIntent` line, and after `startObservingRate()`:

```swift
        onFrameStep = { [weak self] from, to in
            guard let self, self.drawing.isDrawing else { return }
            self.drawing.session?.cancelInProgress()
            self.drawing.session?.stretch(from: from, to: to, frameDuration: self.frameDuration)
        }
```

- New public API near `togglePlayback`:

```swift
    /// Drawing needs a loaded picture (to place marks) and a readable
    /// drawings file (so a newer app's file is never replaced).
    public var canDraw: Bool {
        currentPlaybackURL != nil && pictureSize != .zero && drawing.session != nil
    }

    public func setDrawing(_ on: Bool) {
        if on {
            guard canDraw, !drawing.isDrawing else { return }
            endSlowMotion()
            player.pause()
            drawing.enter()
            status = "Drawing"
        } else {
            guard drawing.isDrawing else { return }
            drawing.leave()
            status = "Paused"
        }
    }
```

- `handle(_:)`: change `case .togglePlayback:` to

```swift
        case .togglePlayback:
            setDrawing(false)
            togglePlayback()
```

  change `case let .seek(direction):` to

```swift
        case let .seek(direction):
            if drawing.isDrawing {
                stepFrame(direction)
                return
            }
            hold.end()
            performArrowTap(direction)
```

  add `case .toggleDrawing: setDrawing(!drawing.isDrawing)` before `case .focusAthleteSearch, .openFolder:`.

- `applyTransport(_:)`: as its first line, `if action == .playPause || action == .slow { setDrawing(false) }`.
- `loadCurrentVideo()`: as its first line, `drawing.load(for: currentClipIdentity)` (before the `guard currentVideo != nil`, so closing a library saves and clears).

- [ ] **Step 4: Run to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SkiVideoCoreTests`
Expected: the new tests pass and the rest of the core suite is unchanged (842 tests before this plan, 0 failures). `ComparisonModel`/`SortingModel` `handle` switches have `default:` and need no change.

- [ ] **Step 5: Commit**

```bash
git add Sources/SkiVideoCore/DrawingController.swift Sources/SkiVideoCore/Seams.swift Sources/SkiVideoCore/ViewerModel.swift Tests/SkiVideoCoreTests/CorePurityTests.swift Tests/SkiVideoCoreTests/DrawingControllerTests.swift
git commit -m "Add drawing mode to the viewer: per-clip drawings, stretch on step, saved on change"
```

---

### Task 7: The overlay and the palette

**Files:**
- Create: `Sources/SkiVideoViewer/Shared/DrawingOverlay.swift`
- Create: `Sources/SkiVideoViewer/Shared/DrawingPalette.swift`
- Modify: `Sources/SkiVideoViewer/Shared/ViewerPane.swift` (body, ~lines 57–110)
- Modify: `Sources/SkiVideoViewer/Shared/ViewerControlBar.swift`
- Modify: `Sources/SkiVideoViewer/Shared/ContentView.swift` (where `ViewerControlBar(model:)` is placed; app-level `scenePhase`)

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces (accessibility identifiers the UI tests in Task 9 use): `viewer.draw` (pencil), `viewer.showDrawings`, `drawing.overlay` (value `"<n> on this frame"`), `drawing.angleValue.<index>` (label `"<deg>°"`), `drawing.tool.move|pen|line|angle|text`, `drawing.color.red|yellow|blue|black`, `drawing.arrowheads`, `drawing.stepBack`, `drawing.stepForward`, `drawing.clearFrame`, `drawing.undo`, `drawing.redo`, `drawing.delete`, `drawing.done`, `drawing.textField`, `drawing.notice`.

- [ ] **Step 1: `DrawingOverlay.swift`**

```swift
import SkiVideoCore
import SwiftUI

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
    @State private var typed = ""
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
                textField(at: geometry.toPane(editing.points[0]), initial: editing.text)
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

    /// One gesture for taps and drags: under 4pt of travel is a tap. Two
    /// separate SwiftUI gestures would make every tap wait on the drag.
    private var drawGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDragging, hypot(value.translation.width, value.translation.height) >= 4 {
                    session.dragBegan(at: value.startLocation, geometry: geometry, time: time)
                    isDragging = true
                }
                if isDragging { session.dragChanged(to: value.location, geometry: geometry) }
            }
            .onEnded { value in
                if isDragging {
                    session.dragEnded(at: value.location, geometry: geometry)
                } else {
                    session.tapped(at: value.location, geometry: geometry, time: time,
                                   frameDuration: model.frameDuration)
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
                .accessibilityIdentifier("drawing.angleValue.\(index)")
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

    private func textField(at point: CGPoint, initial: String) -> some View {
        TextField("Note", text: $typed)
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
            .position(point)
            .onAppear { typed = initial }
            .onSubmit { session.finishText(typed) }
            .accessibilityIdentifier("drawing.textField")
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
```


- [ ] **Step 2: `DrawingPalette.swift`**

```swift
import SkiVideoCore
import SwiftUI

/// Shown in the control bar's place while drawing: transport is meaningless
/// then, and a phone has no room for both. Wraps to two rows when narrow.
struct DrawingPalette: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var session: DrawingSession

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { tools; Divider().frame(height: 28); colours; Divider().frame(height: 28); actions }
            VStack(spacing: 4) {
                HStack(spacing: 4) { tools; colours }
                HStack(spacing: 4) { actions }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var tools: some View {
        HStack(spacing: 2) {
            tool(.move, "hand.draw", "Move")
            tool(.pen, "scribble", "Pen")
            tool(.line, "arrow.up.right", "Line")
            tool(.angle, "angle", "Angle")
            tool(.text, "textformat", "Text")
            if session.tool == .line {
                toggle(isOn: session.arrowheads, symbol: "arrowhead", label: "Arrowheads", id: "drawing.arrowheads") {
                    session.arrowheads.toggle()
                }
            }
        }
    }

    private var colours: some View {
        HStack(spacing: 2) {
            ForEach(DrawingColor.allCases, id: \.self) { colour in
                Button { session.color = colour } label: {
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
            Button("Done") { model.setDrawing(false) }
                .accessibilityIdentifier("drawing.done")
        }
    }

    private func tool(_ tool: DrawingTool, _ symbol: String, _ label: String) -> some View {
        toggle(isOn: session.tool == tool, symbol: symbol, label: label, id: "drawing.tool.\(tool.rawValue)") {
            session.tool = tool
        }
    }

    private func toggle(isOn: Bool, symbol: String, label: String, id: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
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
        Button(action: perform) {
            Image(systemName: symbol).frame(width: 40, height: 40).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}
```

SF Symbols: before shipping, confirm each symbol name exists on macOS 13 and iOS 17 (`hand.draw`, `scribble`, `arrow.up.right`, `angle`, `textformat`, `arrowhead` — **`arrowhead` may not exist**; substitute `arrowtriangle.right` if not). Check with `grep` against the SF Symbols app or by building and looking for "No symbol named" in the console.

- [ ] **Step 3: Wire `ViewerPane`**

Replace the `SinglePlayerView(...)` chain's tap and pan lines so drawing mode routes gestures:

```swift
                .onTapGesture { if !model.drawing.isDrawing { model.applyTransport(.playPause) } }
```

```swift
                .gesture(model.zoom.isZoomed && (!model.drawing.isDrawing || model.drawing.session?.tool == .move)
                         ? panGesture(in: proxy.size) : nil)
```

Then, between the pan gesture and the zoom chip overlay:

```swift
                .overlay {
                    if let session = model.drawing.session,
                       model.drawing.isDrawing || model.drawing.showsDrawings {
                        DrawingOverlay(model: model, session: session,
                                       isDrawing: model.drawing.isDrawing, paneSize: proxy.size)
                    }
                }
```

`ViewerPane` observes `model` but not `model.drawing`; add `@ObservedObject var drawing: DrawingController` initialised from `model.drawing` — make `ViewerPane`'s init take only `model`/`athleteName` as today and set `_drawing = ObservedObject(wrappedValue: model.drawing)` in a custom init, so existing call sites (`ViewerPane(model:athleteName:)`) keep compiling.

Also add, in the `.overlay(alignment: .top)` banner area, the notice:

```swift
        .overlay(alignment: .bottom) {
            if let notice = drawing.notice {
                Text(notice).font(.caption).padding(6)
                    .background(.thinMaterial, in: Capsule()).padding(.bottom, 56)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("drawing.notice")
            }
        }
```

- [ ] **Step 4: `ViewerControlBar` buttons**

Add `@ObservedObject var drawing: DrawingController` with a custom `init(model:)` setting `_drawing = ObservedObject(wrappedValue: model.drawing)`, and an `HStack` placed before `clipStepping` in both layouts:

```swift
    private var drawingButtons: some View {
        HStack(spacing: 4) {
            Button { model.setDrawing(true) } label: {
                Image(systemName: "pencil.tip.crop.circle").frame(width: 44, height: isShortOnHeight ? 34 : 44).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Draw (D)")
            .accessibilityLabel("Draw")
            .accessibilityIdentifier("viewer.draw")
            .disabled(!model.canDraw)

            Button { drawing.showsDrawings.toggle() } label: {
                Image(systemName: drawing.showsDrawings ? "eye" : "eye.slash")
                    .frame(width: 44, height: isShortOnHeight ? 34 : 44).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(drawing.showsDrawings ? "Hide drawings" : "Show drawings")
            .accessibilityLabel("Show drawings")
            .accessibilityValue(drawing.showsDrawings ? "On" : "Off")
            .accessibilityIdentifier("viewer.showDrawings")
        }
    }
```

`ViewerControlBar` observes `model`, but `canDraw` reads `pictureSize` (published on `model`) and `drawing.session` (published on `drawing`), so both observations are needed — that is why `drawing` is observed here.

- [ ] **Step 5: `ContentView` — swap the bar and save on background**

Find each place `ViewerControlBar(model: model)` is constructed (`grep -n "ViewerControlBar(" Sources/SkiVideoViewer/Shared/ContentView.swift`). Replace each with a `DrawingAwareControlBar(model: model)`, defined at the bottom of `DrawingPalette.swift`:

```swift
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
```

In `ContentView`, add `@Environment(\.scenePhase) private var scenePhase` and on the root view:

```swift
        // Saving on every change is debounced by a second; leaving the
        // foreground must not wait for it, or a swipe-away loses the last mark.
        .onChange(of: scenePhase) { phase in
            if phase != .active { model.drawing.saveNow() }
        }
```

- [ ] **Step 6: Build both platforms**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Run: `xcodegen generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project SkiVideoViewer.xcodeproj -scheme SkiVideoViewer-iPad -destination 'id=D27B52D1-3327-4306-B36B-BC0A1B088B96' build`
Expected: both succeed with no new warnings in the new files.

- [ ] **Step 7: Run the existing view tests that host `ViewerPane`/`ViewerControlBar`**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "SkiVideoViewerTests.ZoomWiringTests|SkiVideoViewerTests.ViewerControlsWiringTests|SkiVideoViewerTests.ViewerLayoutMeasurementTests|SkiVideoViewerTests.ViewerCaptionLayoutTests"`
Expected: same pass/fail set as on `main` before this task (memory: some SkiVideoViewerTests already fail on main — diff against a `main` run before blaming this task). In particular `testTappingTheUnzoomedPaneStillTogglesPlayback` must still pass, and `ViewerLayoutMeasurementTests` must not report the bar's ideal width exceeding its iPad-mini bound because of the two new buttons; if it does, move `drawingButtons` into the wrapped fallback row only and record the measured widths in a comment.

- [ ] **Step 8: Commit**

```bash
git add Sources/SkiVideoViewer/Shared/DrawingOverlay.swift Sources/SkiVideoViewer/Shared/DrawingPalette.swift Sources/SkiVideoViewer/Shared/ViewerPane.swift Sources/SkiVideoViewer/Shared/ViewerControlBar.swift Sources/SkiVideoViewer/Shared/ContentView.swift
git commit -m "Draw on the viewer: overlay, palette in the control bar's place, and save on background"
```

---

### Task 8: Span bars on the timeline, and D on macOS

**Files:**
- Modify: `Sources/SkiVideoViewer/Shared/TimelineScrubber.swift`
- Modify: `Sources/SkiVideoViewer/Shared/ContentView.swift` (the viewer's `TimelineScrubber(` call)
- Modify: `Sources/SkiVideoViewer/macOS/AppKitInputSource.swift` (~line 233 switch)
- Test: `Tests/SkiVideoViewerTests/AppKitInputSourceTests.swift`

**Interfaces:**
- Consumes: `ClipDrawings.spans`, `PlaybackIntent.toggleDrawing`.
- Produces: `TimelineScrubber(time:duration:marks:onScrub:)` with `marks: [ClosedRange<Double>] = []` — existing callers unchanged.

- [ ] **Step 1: Write the failing key test** (append to `AppKitInputSourceTests`)

```swift
    func testDTogglesDrawing() {
        let source = AppKitInputSource()
        var intents: [PlaybackIntent] = []
        source.onIntent = { intents.append($0) }
        XCTAssertTrue(source.handle(key(2)))            // kVK_ANSI_D
        XCTAssertFalse(source.handle(key(2, modifiers: .command)), "⌘D belongs to menus")
        _ = source.handle(key(2, isARepeat: true))
        XCTAssertEqual(intents.count, 1)
        guard case .toggleDrawing = intents.first else { return XCTFail("expected .toggleDrawing") }
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SkiVideoViewerTests.AppKitInputSourceTests/testDTogglesDrawing`
Expected: FAIL — `handle` returns false for keyCode 2.

- [ ] **Step 3: Implement the key** — in `AppKitInputSource.handle`'s `switch event.keyCode`, after the Page Down case:

```swift
        case 2: // D — drawing mode. Below the text-field check, so typing a
                // note's "d" never toggles the mode out from under it.
            if !event.isARepeat { emit(.toggleDrawing) }
```

- [ ] **Step 4: Run to verify it passes** — same command; PASS. Then the whole `AppKitInputSourceTests` class: no new failures.

- [ ] **Step 5: Span bars** — in `TimelineScrubber` add `var marks: [ClosedRange<Double>] = []` after `duration` (a `var` with a default keeps the memberwise init source-compatible for the comparison screen's callers), and on the `Slider` add:

```swift
        .overlay(alignment: .bottom) {
            GeometryReader { proxy in
                ForEach(Array(marks.enumerated()), id: \.offset) { _, span in
                    let x = proxy.size.width * span.lowerBound / max(duration, 0.0001)
                    let width = max(4, proxy.size.width * (span.upperBound - span.lowerBound) / max(duration, 0.0001))
                    Capsule().fill(Color.orange)
                        .frame(width: width, height: 4)
                        .position(x: x + width / 2, y: proxy.size.height - 4)
                        .onTapGesture { onScrub(span.lowerBound) }
                        .accessibilityLabel("Drawing at \(Timecode.string(span.lowerBound))")
                }
            }
        }
```

In `ContentView`, at the viewer's `TimelineScrubber(` call, pass `marks: model.drawing.session?.drawings.spans ?? []`. `ContentView` does not observe `model.drawing`; wrap that scrubber in a small `DrawingAwareScrubber` view in `DrawingPalette.swift` that observes `model.drawing` and its `session` the way `DrawingAwareControlBar` does, and passes the spans through. Because `session` is itself an `ObservableObject`, the wrapper must observe it too: split into an outer view observing `DrawingController` and an inner view taking `@ObservedObject var session: DrawingSession`.

- [ ] **Step 6: Build and run the Mac view tests touched in Task 7 again** — same command as Task 7 Step 7; same expectations.

- [ ] **Step 7: Commit**

```bash
git add Sources/SkiVideoViewer/Shared/TimelineScrubber.swift Sources/SkiVideoViewer/Shared/ContentView.swift Sources/SkiVideoViewer/Shared/DrawingPalette.swift Sources/SkiVideoViewer/macOS/AppKitInputSource.swift Tests/SkiVideoViewerTests/AppKitInputSourceTests.swift
git commit -m "Mark drawn spans on the timeline and toggle drawing with D on macOS"
```

---

### Task 9: UI tests on the phone, with screenshots

**Files:**
- Create: `Tests/SkiVideoViewerUITests/DrawingUITests.swift`

**Interfaces:**
- Consumes: the accessibility identifiers listed in Task 7; the phone walk in `PhoneNavigationUITests.walkToAClip()` (private there — copy it, with its `openTheFixtureFolder`, into this file as private helpers; do not make the other file's helpers shared, it is out of scope).
- Fixture: `Documents/Snow` on the iPhone 17 Pro simulator `D27B52D1-3327-4306-B36B-BC0A1B088B96` (1280×720, 30 fps, 8 s clips; see `ViewerOnIPadUITests.swift:47`).

- [ ] **Step 1: Write the tests**

```swift
import XCTest

final class DrawingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // walkToAClip() and openTheFixtureFolder(in:) — copied verbatim from
    // PhoneNavigationUITests.swift (lines 190–270 at the time of writing).

    private func enterDrawing(_ app: XCUIApplication) -> XCUIElement {
        let draw = app.buttons["viewer.draw"]
        XCTAssertTrue(draw.waitForExistence(timeout: 20))
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: draw)
        waitForExpectations(timeout: 20)
        draw.tap()
        let overlay = app.otherElements["drawing.overlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 10))
        return overlay
    }

    private func drawLine(on overlay: XCUIElement, app: XCUIApplication) {
        app.buttons["drawing.tool.line"].tap()
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testALineStretchesAcrossStepsAndSurvivesReopening() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "this walk is the phone's")
        let app = walkToAClip()
        let overlay = enterDrawing(app)
        drawLine(on: overlay, app: app)
        XCTAssertEqual(overlay.value as? String, "1 on this frame")
        screenshot("01-line-drawn")

        for _ in 0..<3 { app.buttons["drawing.stepForward"].tap() }
        XCTAssertEqual(overlay.value as? String, "1 on this frame", "stepping must carry the line along")
        screenshot("02-after-three-steps")

        app.buttons["drawing.done"].tap()
        app.buttons["Next clip"].tap()
        app.buttons["Previous clip"].tap()
        app.buttons["drawing.done"].waitForNonExistence(timeout: 5)
        // Back on the first clip at 0 s: the line's first frame.
        XCTAssertEqual(app.otherElements["drawing.overlay"].value as? String, "1 on this frame",
                       "reopening the clip must bring the line back")
    }

    func testTheLineStaysOnThePictureWhenZoomed() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "this walk is the phone's")
        let app = walkToAClip()
        let overlay = enterDrawing(app)
        drawLine(on: overlay, app: app)
        screenshot("03-before-zoom")
        let zoomIn = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'zoom in'")).firstMatch
        XCTAssertTrue(zoomIn.waitForExistence(timeout: 5), "the zoom chip's plus button")
        for _ in 0..<4 { zoomIn.tap() }   // 1× → 3× in 0.5 steps
        screenshot("04-at-3x")
    }

    func testARightAngleReadsNinetyDegrees() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "this walk is the phone's")
        let app = walkToAClip()
        let overlay = enterDrawing(app)
        app.buttons["drawing.tool.angle"].tap()
        if app.buttons["OK"].waitForExistence(timeout: 2) { app.buttons["OK"].tap() }   // first-use note
        let corner = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        corner.press(forDuration: 0.1, thenDragTo: overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6)))
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        let value = app.staticTexts["drawing.angleValue.0"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        XCTAssertEqual(value.label, "90°")
        screenshot("05-right-angle")
    }

    func testTappingWhileDrawingDoesNotPlay() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "this walk is the phone's")
        let app = walkToAClip()
        let overlay = enterDrawing(app)
        app.buttons["drawing.tool.pen"].tap()
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        XCTAssertTrue(app.buttons["drawing.done"].exists, "a tap in drawing mode must not leave it or play")
    }
}
```

The zoom chip's plus button label: check `ZoomControl.swift` for its `accessibilityLabel` and use that exact string instead of the `CONTAINS 'zoom in'` predicate if it differs.

- [ ] **Step 2: Run on a freshly booted phone simulator, this class alone**

```bash
xcrun simctl shutdown D27B52D1-3327-4306-B36B-BC0A1B088B96; xcrun simctl boot D27B52D1-3327-4306-B36B-BC0A1B088B96
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project SkiVideoViewer.xcodeproj \
  -scheme SkiVideoViewer-iPad -destination 'id=D27B52D1-3327-4306-B36B-BC0A1B088B96' \
  -only-testing:SkiVideoViewer-iPadUITests/DrawingUITests -resultBundlePath <scratchpad>/drawing.xcresult test
```

Expected: 4 tests pass. Running the whole UI suite on a phone fails iPad-only tests on `main` too — run this class alone.

- [ ] **Step 3: Export and look at the screenshots**

```bash
xcrun xcresulttool export attachments --path <scratchpad>/drawing.xcresult --output-path <scratchpad>/drawing-shots
```

Open `03-before-zoom` and `04-at-3x`: the line must sit on the same picture feature in both (at 3× it is longer and may run off the pane — that is correct). Open `05-right-angle`: the label reads 90° at the corner. **Show every frame used to reach this conclusion to the user, listed by name** (standing preference).

- [ ] **Step 4: Re-run the phone suites that touch the viewer** — `PhoneNavigationUITests` alone on a fresh boot; expect 5/5 as before this plan.

- [ ] **Step 5: Commit**

```bash
git add Tests/SkiVideoViewerUITests/DrawingUITests.swift
git commit -m "Prove drawing on a phone: stretch on step, reopen, zoom and a right angle"
```

---

### Final sign-off (after the last task)

- [ ] `SKI_SLOW_TESTS=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` — compare failures against a `main` run; only pre-existing ones may remain (see memory: viewer wiring tests broken on main).
- [ ] Mac: `./build_app.sh`, then try D, draw, ←/→ stepping, Space to leave, Show drawings toggle, quit and reopen.
- [ ] Update the spec's **Status** line to "implemented" and note any measured deviation.
