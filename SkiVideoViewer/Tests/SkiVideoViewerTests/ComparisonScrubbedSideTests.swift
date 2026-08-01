import AVFoundation
import XCTest
@testable import SkiVideoCore
@testable import SkiVideoViewer

/// `ComparisonTarget.scrubbedSide` — the one line that maps what the bar is
/// *targeting* onto the clip the scrubber drags and the time label reads.
///
/// It had no test at all. Task 2 tested `target` inside the model, Task 3
/// assumed that covered the views, and neither tested the mapping between them:
/// inverting it to `self == .right ? .left : .right` left all 116 tests green,
/// while a Right-targeted bar would have dragged the *left* clip under a
/// timeline labelled with the right clip's clock — the exact contradiction the
/// doc comment on the extension forbids.
///
/// Both halves are asserted: the mapping itself, and what the mapping *means* —
/// that handing `scrubbedSide` to `ComparisonModel.scrub(_:to:)` moves the clip
/// the target names to the requested time. The second is the one that would
/// still fail if the mapping were moved somewhere else and quietly inverted on
/// the way.
@MainActor
final class ComparisonScrubbedSideTests: XCTestCase {
    private var temporaryDirectory: URL?

    override func tearDown() async throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testEachTargetNamesTheClipItScrubs() {
        XCTAssertEqual(ComparisonTarget.left.scrubbedSide, .left)
        XCTAssertEqual(ComparisonTarget.right.scrubbedSide, .right)
        // Not arbitrary: while synced the pair is locked, so either playhead
        // names the pair's position, and `scrub` carries the other clip along
        // by the sync-point offset. Left is the one the doc comment commits to.
        XCTAssertEqual(ComparisonTarget.both.scrubbedSide, .left)
    }

    /// Dragging the timeline must move the clip the target names *to the time
    /// under the thumb*, not the other one.
    ///
    /// The pair is deliberately given a non-zero offset first. With both sync
    /// points at zero the two clips move together and land on the same second,
    /// so an inverted mapping is indistinguishable — that is why an assertion
    /// on a freshly synced pair would prove nothing.
    func testDraggingTheTimelineMovesTheClipTheTargetNames() throws {
        // The expected side is stated here, never read back from
        // `scrubbedSide`: deriving it from the thing under test would make
        // every assertion below true by construction, inverted or not.
        let expectations: [(ComparisonTarget, ComparisonSide)] = [(.left, .left), (.right, .right), (.both, .left)]
        for (target, expected) in expectations {
            let model = try makeSyncedModelWithOffset()
            defer { model.close() }
            model.target = target
            XCTAssertEqual(model.target, target, "precondition: \(target) must be selectable")

            model.scrub(target.scrubbedSide, to: 7)

            let landed = expected == .left
                ? model.leftPlayer.currentTime().seconds
                : model.rightPlayer.currentTime().seconds
            let other = expected == .left
                ? model.rightPlayer.currentTime().seconds
                : model.leftPlayer.currentTime().seconds
            XCTAssertEqual(landed, 7, accuracy: 0.01,
                           "targeting \(target) must drag the \(expected) clip to the requested time")
            XCTAssertNotEqual(other, 7, accuracy: 0.01,
                              """
                              targeting \(target) dragged the other clip to the requested time instead; \
                              the timeline and the time label would disagree
                              """)
        }
    }

    /// Two clips, synced, then a nudge so the locked pair keeps a 5s offset
    /// rather than a zero one.
    private func makeSyncedModelWithOffset() throws -> ComparisonModel {
        let model = ComparisonModel()
        model.load(try makeVideoFile("left.mov"), side: .left)
        model.load(try makeVideoFile("right.mov"), side: .right)
        model.setSyncPoints()
        XCTAssertTrue(model.isSynced, "precondition: the pair must be locked")
        model.nudge(.right, by: 5)
        XCTAssertEqual(model.rightSyncPoint.seconds - model.leftSyncPoint.seconds, 5, accuracy: 0.01,
                       "precondition: the pair must keep a non-zero offset, or the sides are indistinguishable")
        return model
    }

    /// `AVPlayerItem` accepts any URL and reports failure asynchronously, so an
    /// empty file gives a player a `currentItem` — all `hasTwoVideos`, and so
    /// `setSyncPoints()`, requires. Seeks land and `currentTime()` reports them.
    private func makeVideoFile(_ name: String) throws -> URL {
        let root = temporaryDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryDirectory = root
        let url = root.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }
}
