import XCTest
@testable import SkiVideoCore

/// The tray and its batch, against an in-memory Drive. What the tray shows is
/// read from the sorted output on disk and from Drive — never from anything
/// the app remembered — so every test here builds a real directory.
@MainActor
final class UploadBatchModelTests: XCTestCase {
    private var root: URL!
    private var drive: FakeDriveWriter!
    private let event = "2026-01-14_Brunni"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UploadBatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        drive = FakeDriveWriter()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func sortedClip(_ name: String, athlete: String, event: String? = nil,
                            bytes: Int = 10) throws -> URL {
        let folder = root.appendingPathComponent(event ?? self.event)
            .appendingPathComponent(athlete)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    private func makeModel(_ convention: FolderConvention = .eventThenAthlete) throws -> UploadBatchModel {
        let destination = try UploadDestination.resolve(
            library: Library(name: "Club Drive", kind: .drive(rootID: "root-1"), convention: convention),
            indexConvention: nil)
        return UploadBatchModel(
            root: root,
            target: UploadTarget(destination: destination, provider: drive, presenter: FakeOAuthPresenter()))
    }

    private func states(_ model: UploadBatchModel) -> [String: UploadBatchModel.ClipState] {
        Dictionary(uniqueKeysWithValues: model.entries.map { ($0.clip.file.lastPathComponent, $0.state) })
    }

    // MARK: - The tray

    func testTheTrayListsEachSortedClipWithAthleteEventAndSize() async throws {
        try sortedClip("IMG_1.mov", athlete: "Ada", bytes: 1234)
        try sortedClip("IMG_2.mov", athlete: "Bo", bytes: 99)
        let model = try makeModel()

        await model.refresh().value

        XCTAssertEqual(model.entries.map(\.clip.file.lastPathComponent), ["IMG_1.mov", "IMG_2.mov"])
        XCTAssertEqual(model.entries.map(\.clip.athlete), ["Ada", "Bo"])
        XCTAssertEqual(model.entries.map(\.clip.event), [event, event])
        XCTAssertEqual(model.entries.map(\.size), [1234, 99])
        XCTAssertEqual(model.waitingCount, 2)
        XCTAssertEqual(model.libraryName, "Club Drive")
    }

    // MARK: - One session's event

    private func makeEventModel(_ event: String) throws -> UploadBatchModel {
        let destination = try UploadDestination.resolve(
            library: Library(name: "Club Drive", kind: .drive(rootID: "root-1"), convention: .eventThenAthlete),
            indexConvention: nil)
        return UploadBatchModel(
            source: .eventFolder(root.appendingPathComponent(event)),
            target: UploadTarget(destination: destination, provider: drive, presenter: FakeOAuthPresenter()))
    }

    /// The tray at the end of tagging is about this session. Last season's
    /// clips under the same output root must not appear, be checked against
    /// Drive, or be swept into "Upload N" — a historical clip an admin has
    /// since moved would otherwise be uploaded again.
    func testATrayOverOneEventFolderNeitherListsNorChecksAnotherEvent() async throws {
        let old = "2025-12-20_Flumserberg"
        try sortedClip("OLD_1.mov", athlete: "Ada", event: old)
        try sortedClip("IMG_1.mov", athlete: "Ada")
        let model = try makeEventModel(event)

        await model.refresh().value

        XCTAssertEqual(model.entries.map(\.clip.file.lastPathComponent), ["IMG_1.mov"])
        XCTAssertEqual(model.entries.first?.clip.event, event)
        XCTAssertFalse(drive.findFolderNames.contains(old), "\(drive.findFolderNames)")

        await model.uploadWaiting().value

        XCTAssertEqual(drive.uploadedNames, ["IMG_1.mov"])
        XCTAssertEqual(drive.path(ofFile: "IMG_1.mov"), [event, "Ada"])
        XCTAssertFalse(drive.findFolderNames.contains(old))
    }

    func testASessionTrayRebuiltAfterAKillAsksDriveWhatIsDone() async throws {
        try sortedClip("IMG_1.mov", athlete: "Ada")
        try sortedClip("IMG_2.mov", athlete: "Ada")
        drive.seedFile("IMG_1.mov", at: [event, "Ada"])

        let reopened = try makeEventModel(event)
        await reopened.refresh().value

        XCTAssertEqual(states(reopened), ["IMG_1.mov": .alreadyInDrive, "IMG_2.mov": .waiting])
    }

    /// A sorted output that cannot be read must say so, not read as "nothing
    /// sorted yet" — the Drive check that follows must not wipe the message.
    func testAnUnreadableSortedOutputStaysReported() async throws {
        let notADirectory = root.appendingPathComponent("file-not-folder")
        try Data([1]).write(to: notADirectory)
        let destination = try UploadDestination.resolve(
            library: Library(name: "Club Drive", kind: .drive(rootID: "root-1"), convention: .eventThenAthlete),
            indexConvention: nil)
        let model = UploadBatchModel(
            source: .outputRoot(notADirectory),
            target: UploadTarget(destination: destination, provider: drive, presenter: FakeOAuthPresenter()))

        await model.refresh().value

        XCTAssertEqual(model.entries, [])
        XCTAssertNotNil(model.readProblem)
    }

    // MARK: - Uploading

    func testEachClipUploadsIntoItsEventAndAthleteFoldersCreatingEachOnce() async throws {
        try sortedClip("IMG_1.mov", athlete: "Ada")
        try sortedClip("IMG_2.mov", athlete: "Ada")
        try sortedClip("IMG_3.mov", athlete: "Bo")
        let model = try makeModel(.eventThenAthlete)
        await model.refresh().value

        await model.uploadWaiting().value

        XCTAssertEqual(drive.path(ofFile: "IMG_1.mov"), [event, "Ada"])
        XCTAssertEqual(drive.path(ofFile: "IMG_2.mov"), [event, "Ada"])
        XCTAssertEqual(drive.path(ofFile: "IMG_3.mov"), [event, "Bo"])
        XCTAssertEqual(drive.createdFolderNames, [event, "Ada", "Bo"])
        XCTAssertEqual(Set(states(model).values), [.uploaded])
        XCTAssertEqual(model.waitingCount, 0)
        XCTAssertNil(model.stopReason)
    }

    func testAthleteFirstLibrariesNestTheOtherWayRound() async throws {
        try sortedClip("IMG_1.mov", athlete: "Ada")
        let model = try makeModel(.athleteThenEvent)
        await model.refresh().value

        await model.uploadWaiting().value

        XCTAssertEqual(drive.path(ofFile: "IMG_1.mov"), ["Ada", event])
    }

    func testWritesAreAuthorisedOnceBeforeTheBatch() async throws {
        try sortedClip("IMG_1.mov", athlete: "Ada")
        try sortedClip("IMG_2.mov", athlete: "Bo")
        let model = try makeModel()
        await model.refresh().value

        await model.uploadWaiting().value

        XCTAssertEqual(drive.authorizeCount, 1)
        XCTAssertEqual(drive.uploadedNames.count, 2)
    }

    func testDeclinedConsentUploadsNothingAndSaysWhy() async throws {
        try sortedClip("IMG_1.mov", athlete: "Ada")
        drive.authorizeError = RemoteLibraryError.api("The coach said no.")
        let model = try makeModel()
        await model.refresh().value

        await model.uploadWaiting().value

        XCTAssertEqual(drive.uploadedNames, [])
        XCTAssertEqual(states(model)["IMG_1.mov"], .waiting)
        XCTAssertEqual(model.stopReason, "The coach said no.")
    }

    func testUploadingLeavesTheLocalClipInPlace() async throws {
        let file = try sortedClip("IMG_1.mov", athlete: "Ada")
        let model = try makeModel()
        await model.refresh().value

        await model.uploadWaiting().value

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Nothing uploads twice

    func testAClipAlreadyInItsDriveFolderIsSkippedNotUploadedAgain() async throws {
        try sortedClip("IMG_1.mov", athlete: "Ada")
        try sortedClip("IMG_2.mov", athlete: "Ada")
        let model = try makeModel()
        await model.refresh().value
        // Arrives after the tray looked: only the check made immediately
        // before the upload can see it.
        drive.seedFile("IMG_1.mov", at: [event, "Ada"])

        await model.uploadWaiting().value

        XCTAssertEqual(states(model)["IMG_1.mov"], .alreadyInDrive)
        XCTAssertEqual(states(model)["IMG_2.mov"], .uploaded)
        XCTAssertEqual(drive.uploadedNames, ["IMG_2.mov"])
        XCTAssertEqual(drive.fileCount(named: "IMG_1.mov"), 1)
    }

    /// A coach in a lift queue presses Upload again: once while the batch is
    /// still running, and once after it was cancelled mid-clip. Neither press
    /// may send a clip that is already up, or start a second batch beside the
    /// first.
    func testPressingUploadAgainDuringOrAfterABatchUploadsNothingTwice() async throws {
        try sortedClip("IMG_1.mov", athlete: "Ada")
        try sortedClip("IMG_2.mov", athlete: "Ada")
        try sortedClip("IMG_3.mov", athlete: "Ada")
        drive.hangUpload(of: "IMG_2.mov")
        let model = try makeModel()
        await model.refresh().value

        let batch = model.uploadWaiting()
        try await waitUntil { self.drive.uploadHasStarted("IMG_2.mov") }
        try await finish(model.uploadWaiting())
        XCTAssertEqual(drive.uploadedNames, ["IMG_1.mov"], "a press during a batch must not start another")
        XCTAssertTrue(model.isUploading)

        model.cancel()
        // Every wait below is bounded. Without the guard, the second press
        // replaces the model's batch task, so `cancel()` reaches only that one
        // and the first batch stays parked in the hung upload — measured: an
        // unbounded `await batch.value` here hung the run for days instead of
        // failing it.
        try await finish(batch)
        drive.stopHanging()
        try await finish(model.uploadWaiting())

        XCTAssertEqual(drive.uploadedNames, ["IMG_1.mov", "IMG_2.mov", "IMG_3.mov"])
        for name in ["IMG_1.mov", "IMG_2.mov", "IMG_3.mov"] {
            XCTAssertEqual(drive.fileCount(named: name), 1, "\(name) must be in Drive exactly once")
        }
    }

    func testTheSameNameUnderAnotherAthleteIsNotASkip() async throws {
        try sortedClip("IMG_1.mov", athlete: "Ada")
        drive.seedFile("IMG_1.mov", at: [event, "Bo"])
        let model = try makeModel()
        await model.refresh().value

        await model.uploadWaiting().value

        XCTAssertEqual(states(model)["IMG_1.mov"], .uploaded)
    }

    /// The app being killed mid-batch is normal. A tray built afresh over the
    /// same folder must learn from Drive which clips are done, because
    /// nothing in memory survived to tell it.
    func testATrayRebuiltAfterTheAppWasKilledAsksDriveWhatIsDone() async throws {
        try sortedClip("IMG_1.mov", athlete: "Ada")
        try sortedClip("IMG_2.mov", athlete: "Ada")
        try sortedClip("IMG_3.mov", athlete: "Bo")
        let first = try makeModel()
        await first.refresh().value
        drive.hangUpload(of: "IMG_3.mov")
        let batch = first.uploadWaiting()
        try await waitUntil { self.drive.uploadHasStarted("IMG_3.mov") }
        batch.cancel()          // the kill: nothing after this runs to completion
        await batch.value

        let reopened = try makeModel()
        await reopened.refresh().value

        XCTAssertEqual(states(reopened), [
            "IMG_1.mov": .alreadyInDrive, "IMG_2.mov": .alreadyInDrive, "IMG_3.mov": .waiting,
        ])
        XCTAssertEqual(reopened.waitingCount, 1)
        XCTAssertNil(reopened.checkProblem)
    }

    func testCheckingDriveCreatesNoFolders() async throws {
        try sortedClip("IMG_1.mov", athlete: "Ada")
        let model = try makeModel()

        await model.refresh().value

        XCTAssertEqual(drive.createdFolderNames, [])
        XCTAssertEqual(states(model)["IMG_1.mov"], .waiting)
    }

    func testACheckThatCannotReachDriveLeavesClipsWaitingAndSaysSo() async throws {
        try sortedClip("IMG_1.mov", athlete: "Ada")
        drive.failFindFolder(named: event, with: RemoteLibraryError.api("offline"))
        let model = try makeModel()

        await model.refresh().value

        XCTAssertEqual(states(model)["IMG_1.mov"], .waiting)
        XCTAssertNotNil(model.checkProblem)
    }

    // MARK: - Failures

    func testARetryableFailureFailsThatClipAndTheBatchGoesOn() async throws {
        try sortedClip("IMG_1.mov", athlete: "Ada")
        try sortedClip("IMG_2.mov", athlete: "Ada")
        drive.failUpload(of: "IMG_1.mov", with: RemoteUploadError.retryClip("Signal dropped."))
        let model = try makeModel()
        await model.refresh().value

        await model.uploadWaiting().value

        XCTAssertEqual(states(model)["IMG_1.mov"], .failed("Signal dropped."))
        XCTAssertEqual(states(model)["IMG_2.mov"], .uploaded)
        XCTAssertNil(model.stopReason)
        XCTAssertEqual(model.failedCount, 1)
    }

    func testAnUntypedErrorFailsJustThatClip() async throws {
        try sortedClip("IMG_1.mov", athlete: "Ada")
        try sortedClip("IMG_2.mov", athlete: "Ada")
        drive.failUpload(of: "IMG_1.mov", with: RemoteLibraryError.api("Drive did not return an upload address."))
        let model = try makeModel()
        await model.refresh().value

        await model.uploadWaiting().value

        XCTAssertEqual(states(model)["IMG_1.mov"], .failed("Drive did not return an upload address."))
        XCTAssertEqual(states(model)["IMG_2.mov"], .uploaded)
    }

    /// Drive's find path reports a 403 as an untyped `.api`, so a folder the
    /// coach may not create fails the clip that needed it, not the batch.
    func testAFolderThatCannotBeFoundOrCreatedFailsOnlyTheClipsThatNeedIt() async throws {
        try sortedClip("IMG_1.mov", athlete: "Ada")
        try sortedClip("IMG_2.mov", athlete: "Bo")
        drive.failFindFolder(named: "Ada", with: RemoteLibraryError.api("No access to Ada."))
        let model = try makeModel()
        await model.refresh().value

        await model.uploadWaiting().value

        XCTAssertEqual(states(model)["IMG_1.mov"], .failed("No access to Ada."))
        XCTAssertEqual(states(model)["IMG_2.mov"], .uploaded)
    }

    func testAStopStopsTheBatchAndLeavesTheRestWaiting() async throws {
        try sortedClip("IMG_1.mov", athlete: "Ada")
        try sortedClip("IMG_2.mov", athlete: "Ada")
        try sortedClip("IMG_3.mov", athlete: "Bo")
        drive.failUpload(of: "IMG_2.mov", with: RemoteUploadError.stopBatch("You cannot add files to Club Drive."))
        let model = try makeModel()
        await model.refresh().value

        await model.uploadWaiting().value

        XCTAssertEqual(states(model)["IMG_1.mov"], .uploaded)
        XCTAssertEqual(states(model)["IMG_2.mov"], .waiting)
        XCTAssertEqual(states(model)["IMG_3.mov"], .waiting)
        XCTAssertEqual(drive.uploadedNames, ["IMG_1.mov"])
        let reason = try XCTUnwrap(model.stopReason)
        XCTAssertTrue(reason.contains("You cannot add files to Club Drive."), reason)
        XCTAssertTrue(reason.contains("IMG_2.mov"), "the stop names the clip it happened at: \(reason)")
        XCTAssertFalse(model.isUploading)
    }

    func testBeingSignedOutStopsTheBatch() async throws {
        try sortedClip("IMG_1.mov", athlete: "Ada")
        try sortedClip("IMG_2.mov", athlete: "Ada")
        drive.failUpload(of: "IMG_1.mov", with: RemoteLibraryError.notSignedIn)
        let model = try makeModel()
        await model.refresh().value

        await model.uploadWaiting().value

        XCTAssertEqual(states(model)["IMG_1.mov"], .waiting)
        XCTAssertEqual(states(model)["IMG_2.mov"], .waiting)
        XCTAssertEqual(drive.uploadedNames, [])
        XCTAssertNotNil(model.stopReason)
    }

    func testRetryingAFailedClipUploadsItWithoutTouchingTheOthers() async throws {
        try sortedClip("IMG_1.mov", athlete: "Ada")
        try sortedClip("IMG_2.mov", athlete: "Ada")
        drive.failUpload(of: "IMG_1.mov", with: RemoteUploadError.retryClip("Signal dropped."))
        let model = try makeModel()
        await model.refresh().value
        await model.uploadWaiting().value
        let failed = try XCTUnwrap(model.entries.first { $0.clip.file.lastPathComponent == "IMG_1.mov" })

        await model.retry(failed.id).value

        XCTAssertEqual(states(model)["IMG_1.mov"], .uploaded)
        XCTAssertEqual(drive.uploadedNames, ["IMG_2.mov", "IMG_1.mov"])
        XCTAssertEqual(model.failedCount, 0)
    }

    func testRetryFailedRetriesEveryFailedClip() async throws {
        try sortedClip("IMG_1.mov", athlete: "Ada")
        try sortedClip("IMG_2.mov", athlete: "Bo")
        drive.failUpload(of: "IMG_1.mov", with: RemoteUploadError.retryClip("x"))
        drive.failUpload(of: "IMG_2.mov", with: RemoteLibraryError.api("y"))
        let model = try makeModel()
        await model.refresh().value
        await model.uploadWaiting().value
        XCTAssertEqual(model.failedCount, 2)

        await model.retryFailed().value

        XCTAssertEqual(Set(states(model).values), [.uploaded])
    }

    // MARK: - Cancelling

    func testCancellingReturnsTheClipInFlightToWaitingAndStops() async throws {
        try sortedClip("IMG_1.mov", athlete: "Ada")
        try sortedClip("IMG_2.mov", athlete: "Ada")
        try sortedClip("IMG_3.mov", athlete: "Ada")
        drive.hangUpload(of: "IMG_2.mov")
        let model = try makeModel()
        await model.refresh().value

        let batch = model.uploadWaiting()
        try await waitUntil { self.drive.uploadHasStarted("IMG_2.mov") }
        XCTAssertEqual(states(model)["IMG_2.mov"], .uploading)
        model.cancel()
        await batch.value

        XCTAssertEqual(states(model)["IMG_1.mov"], .uploaded)
        XCTAssertEqual(states(model)["IMG_2.mov"], .waiting)
        XCTAssertEqual(states(model)["IMG_3.mov"], .waiting)
        XCTAssertFalse(drive.uploadHasStarted("IMG_3.mov"))
        XCTAssertNil(model.stopReason, "cancelling is the coach's choice, not a failure")
        XCTAssertFalse(model.isUploading)
    }

    // MARK: - What the open library offers

    func testAnOpenDriveThatCanWriteOffersItselfAsTheTarget() async throws {
        let writer = drive!
        writer.listedFiles = [remoteFile("1", "run.mov", ["2026-02-25_Hoch-Ybrig", "Anna"])]
        var model: ViewerModel!
        try await withTemporaryIndexStore {
            model = ViewerModel(input: FakeInputSource(), folderPicker: FakeFolderPicker(),
                                oauthPresenter: FakeOAuthPresenter())
            await model.signIn(with: writer)
            _ = await model.chooseRoot(RemoteFolder(id: "drive-1", name: "Club"),
                                       cache: ClipCache(root: root.appendingPathComponent(".cache"),
                                                        downloader: FakeClipDownloader(), budget: 1_000),
                                       convention: .eventThenAthlete)
        }

        let target = try model.uploadTarget()

        XCTAssertTrue((target.provider as AnyObject) === writer)
        XCTAssertEqual(target.destination.rootID, "drive-1")
        XCTAssertEqual(target.destination.convention, .eventThenAthlete)
    }

    func testAnOpenDriveWhoseProviderCannotWriteRefuses() async throws {
        var model: ViewerModel!
        try await withTemporaryIndexStore {
            let (m, provider, cache, _) = try remoteModelWithDownloader(
                files: [remoteFile("1", "run.mov", ["Anna", "Slalom"])])
            await m.signIn(with: provider)
            _ = await m.chooseRoot(RemoteFolder(id: "drive-1", name: "Club"),
                                   cache: cache, convention: .eventThenAthlete)
            model = m
        }

        XCTAssertThrowsError(try model.uploadTarget()) {
            XCTAssertEqual($0 as? UploadRefusal, .cannotWrite(libraryName: "Club"))
        }
    }

    func testNothingOpenIsStillTheRefusalForATarget() {
        let model = ViewerModel(input: FakeInputSource(), folderPicker: FakeFolderPicker(),
                                oauthPresenter: FakeOAuthPresenter())
        XCTAssertThrowsError(try model.uploadTarget()) {
            XCTAssertEqual($0 as? UploadRefusal, .noLibraryOpen)
        }
    }

    // MARK: - Helpers

    /// Awaits `task` for at most `timeout`, failing instead of hanging. The
    /// flag is only touched on the main actor: the test class is
    /// `@MainActor`, and the unstructured `Task` inherits that isolation.
    private func finish(_ task: Task<Void, Never>, timeout: TimeInterval = 5) async throws {
        var finished = false
        Task { await task.value; finished = true }
        try await waitUntil(timeout: timeout) { finished }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("condition never became true")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}
