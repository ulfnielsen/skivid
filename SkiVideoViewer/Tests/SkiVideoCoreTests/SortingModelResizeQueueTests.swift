import Foundation
import XCTest
@testable import SkiVideoCore

/// Records how many pipeline jobs are in flight simultaneously. The resize
/// queue promises "Only one ffmpeg job runs at once" in the UI copy, and the
/// `async` pipeline seam is bridged back onto the serial `OperationQueue` with
/// a semaphore. If that bridge ever regresses to fire-and-forget, every queued
/// job overlaps and `maxConcurrent` climbs above 1.
final class SerializationProbePipeline: MediaPipeline, @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var highWaterMark = 0
    private var completedResizes = 0
    private var completedMetadataWrites = 0
    private let jobDuration: UInt64
    private let errorToThrow: Error?

    init(jobDurationMilliseconds: UInt64 = 60, errorToThrow: Error? = nil) {
        jobDuration = jobDurationMilliseconds * 1_000_000
        self.errorToThrow = errorToThrow
    }

    var maxConcurrent: Int { synchronized { highWaterMark } }
    var resizeCount: Int { synchronized { completedResizes } }
    var metadataCount: Int { synchronized { completedMetadataWrites } }

    func writeMetadata(athlete: String, to url: URL) async throws {
        try await occupy()
        synchronized { completedMetadataWrites += 1 }
        if let errorToThrow { throw errorToThrow }
    }

    func resize(source: URL, destination: URL, athlete: String) async throws {
        try await occupy()
        synchronized { completedResizes += 1 }
        if let errorToThrow { throw errorToThrow }
    }

    /// Holds the job "busy" long enough that any overlap is observable.
    private func occupy() async throws {
        synchronized {
            active += 1
            highWaterMark = max(highWaterMark, active)
        }
        try? await Task.sleep(nanoseconds: jobDuration)
        synchronized { active -= 1 }
    }

    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@MainActor
final class SortingModelResizeQueueTests: XCTestCase {
    private var workingDirectory: URL!
    private var sourceDirectory: URL!
    private var namesFile: URL!
    private let athletes = ["Alfa", "Bravo", "Charlie"]

    override func setUp() async throws {
        try await super.setUp()
        workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        sourceDirectory = workingDirectory.appendingPathComponent("raw", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        // The pipeline is faked here, so the clips never have to be real video.
        for index in 1...athletes.count {
            let clip = sourceDirectory.appendingPathComponent("clip\(index).mp4")
            try Data("clip\(index)".utf8).write(to: clip)
        }
        namesFile = workingDirectory.appendingPathComponent("athletes.txt")
        try athletes.joined(separator: "\n").write(to: namesFile, atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        if let workingDirectory {
            try? FileManager.default.removeItem(at: workingDirectory)
        }
        try await super.tearDown()
    }

    private func makeModel(_ pipeline: MediaPipeline) -> SortingModel {
        let model = SortingModel(mediaPipeline: pipeline)
        model.sourcePath = sourceDirectory.path
        model.namesPath = namesFile.path
        model.reloadNames()
        model.eventTitle = "Serialization Test"
        return model
    }

    /// Tags every clip, which enqueues one resize job per clip.
    private func tagEveryClip(_ model: SortingModel) {
        for athlete in athletes {
            model.athleteQuery = athlete
            model.tagCurrentVideo()
        }
    }

    private func waitForResizes(_ model: SortingModel, count: Int) async throws {
        let deadline = Date().addingTimeInterval(20)
        while model.completedResizes < count {
            if Date() > deadline {
                XCTFail("timed out with \(model.completedResizes) of \(count) resizes done")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// THE assertion for this task: the serial `OperationQueue` must still
    /// serialize now that the pipeline calls are `async`.
    func testResizeQueueRunsExactlyOneJobAtATime() async throws {
        let pipeline = SerializationProbePipeline()
        let model = makeModel(pipeline)

        model.beginSorting()
        XCTAssertTrue(model.isSorting)
        XCTAssertEqual(model.rawVideos.count, athletes.count)

        tagEveryClip(model)
        XCTAssertEqual(model.queuedResizes, athletes.count)

        try await waitForResizes(model, count: athletes.count)

        XCTAssertEqual(pipeline.maxConcurrent, 1, "ffmpeg jobs overlapped; the queue no longer serializes")
        XCTAssertEqual(pipeline.metadataCount, athletes.count)
        XCTAssertEqual(pipeline.resizeCount, athletes.count)
        XCTAssertEqual(model.completedResizes, athletes.count)
        XCTAssertTrue(model.failedResizes.isEmpty, "unexpected failures: \(model.failedResizes)")
        model.stopPlayback()
    }

    /// The pipeline receives each tagged clip's organized path, its resized
    /// destination, and the athlete name — the arguments the ffmpeg runner used
    /// to build for itself.
    func testPipelineReceivesOrganizedAndResizedPathsPerClip() async throws {
        let pipeline = RecordingPipeline()
        let model = makeModel(pipeline)

        model.beginSorting()
        tagEveryClip(model)
        try await waitForResizes(model, count: athletes.count)

        XCTAssertEqual(pipeline.resizeCalls.map { $0.athlete }, athletes)
        XCTAssertEqual(pipeline.metadataCalls.map { $0.athlete }, athletes)
        for (index, call) in pipeline.resizeCalls.enumerated() {
            let clip = "clip\(index + 1).mp4"
            XCTAssertEqual(call.source.lastPathComponent, clip)
            XCTAssertEqual(call.destination.lastPathComponent, clip)
            XCTAssertTrue(
                call.source.path.contains("/organized/"),
                "metadata is written to the organized copy, got \(call.source.path)"
            )
            XCTAssertTrue(
                call.destination.path.contains("/organized_resize/"),
                "resize output belongs in organized_resize, got \(call.destination.path)"
            )
            XCTAssertEqual(pipeline.metadataCalls[index].url, call.source)
        }
        model.stopPlayback()
    }

    /// A thrown pipeline error must still cross the semaphore hand-off and land
    /// in `failedResizes`, and the run must still be reported as finished.
    func testPipelineFailuresAreRecordedAndStillCompleteTheRun() async throws {
        let failure = NSError(
            domain: "Test",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "ffmpeg exploded"]
        )
        let pipeline = SerializationProbePipeline(jobDurationMilliseconds: 5, errorToThrow: failure)
        let model = makeModel(pipeline)

        model.beginSorting()
        tagEveryClip(model)
        try await waitForResizes(model, count: athletes.count)

        XCTAssertEqual(model.failedResizes.count, athletes.count)
        XCTAssertTrue(model.failedResizes.allSatisfy { $0.contains("ffmpeg exploded") })
        XCTAssertTrue(model.failedResizes[0].hasPrefix("clip1.mp4: "))
        XCTAssertEqual(model.completedOutputDirectory, nil, "a failed run has no ready library")
        XCTAssertEqual(model.status, "Finished with \(athletes.count) resize error(s).")
        model.stopPlayback()
    }

    /// A clean run reports the resized library so the UI can offer to open it.
    func testSuccessfulRunPublishesTheResizedDirectory() async throws {
        let pipeline = SerializationProbePipeline(jobDurationMilliseconds: 5)
        let model = makeModel(pipeline)

        model.beginSorting()
        tagEveryClip(model)
        try await waitForResizes(model, count: athletes.count)

        XCTAssertEqual(
            model.completedOutputDirectory?.lastPathComponent,
            "organized_resize"
        )
        XCTAssertEqual(model.status, "Finished. Your resized library is ready.")
        model.stopPlayback()
    }
}

/// Records the arguments each pipeline call receives.
private final class RecordingPipeline: MediaPipeline, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedResizes: [(source: URL, destination: URL, athlete: String)] = []
    private var recordedMetadata: [(athlete: String, url: URL)] = []

    var resizeCalls: [(source: URL, destination: URL, athlete: String)] {
        lock.lock(); defer { lock.unlock() }
        return recordedResizes
    }

    var metadataCalls: [(athlete: String, url: URL)] {
        lock.lock(); defer { lock.unlock() }
        return recordedMetadata
    }

    func writeMetadata(athlete: String, to url: URL) async throws {
        lock.lock(); defer { lock.unlock() }
        recordedMetadata.append((athlete, url))
    }

    func resize(source: URL, destination: URL, athlete: String) async throws {
        lock.lock(); defer { lock.unlock() }
        recordedResizes.append((source, destination, athlete))
    }
}
