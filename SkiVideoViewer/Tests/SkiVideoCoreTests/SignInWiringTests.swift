import XCTest
@testable import SkiVideoCore

@MainActor
final class SignInWiringTests: XCTestCase {
    /// Several tests here — not just the relaunch ones below, which wrap
    /// themselves in `withTemporaryIndexStore` — call `chooseRoot` on root id
    /// "d1", and `openRemoteLibrary` now saves and loads an index for it.
    /// Isolated for the whole class so none of them touch the real
    /// Application Support directory or see another test's leftovers:
    /// measured to happen (a stray `8b53639f152c8fc6.skiindex.json` in the
    /// real store) before this was added.
    private var previousIndexStoreRoot: URL!

    override func setUpWithError() throws {
        previousIndexStoreRoot = RemoteLibraryIndex.storeRoot
        RemoteLibraryIndex.storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: RemoteLibraryIndex.storeRoot)
        RemoteLibraryIndex.storeRoot = previousIndexStoreRoot
    }

    /// Two drives, not one. An implementation that returned only the first —
    /// or that stopped at the first page — passes a single-drive fixture, and
    /// a club with an archive drive would silently see half its footage.
    func testSigningInOffersEveryDriveTheAccountCanSee() async throws {
        let (model, provider, _) = try remoteModel(files: [])
        provider.rootsToReturn = [
            RemoteFolder(id: "d1", name: "Club Footage"),
            RemoteFolder(id: "d2", name: "Archive"),
        ]

        await model.signIn(with: provider)

        XCTAssertEqual(model.availableRoots.map(\.name), ["Club Footage", "Archive"])
        XCTAssertNil(model.signInError)
    }

    func testChoosingADriveFillsTheSidebar() async throws {
        let (model, provider, cache) = try remoteModel(files: [
            remoteFile("a", "run1.mp4", ["Neuss 2026", "Ada"]),
        ])
        await model.signIn(with: provider)

        await model.chooseRoot(RemoteFolder(id: "d1", name: "Club"), cache: cache)

        XCTAssertEqual(model.athletes.map(\.name), ["Ada"])
    }

    /// An account outside the club's Workspace is refused outright by Google —
    /// there is no request-access prompt — so the message must name the
    /// account, not say "sign-in failed". Asserted on the specific wording:
    /// a generic error string cannot satisfy it.
    func testAnAccountOutsideTheClubGetsThatMessageNotAGenericFailure() async throws {
        let (model, provider, _) = try remoteModel(files: [])
        provider.connectError = DriveError.notInOrganisation

        await model.signIn(with: provider)

        let message = try XCTUnwrap(model.signInError)
        XCTAssertTrue(message.lowercased().contains("account"), "got \(message)")
        XCTAssertTrue(model.availableRoots.isEmpty, "a refused sign-in must offer nothing")
    }

    /// Signing in must not fetch a single byte. The library is 74 GB; an
    /// implementation that materialised eagerly would download it on connect.
    /// Asserted on the downloader, which is the only thing that can tell.
    func testSigningInAndChoosingADriveDownloadsNothing() async throws {
        let (model, provider, cache, downloader) = try remoteModelWithDownloader(files: [
            remoteFile("a", "run1.mp4", ["Neuss 2026", "Ada"]),
            remoteFile("b", "run2.mp4", ["Neuss 2026", "Ada"]),
        ])
        await model.signIn(with: provider)
        await model.chooseRoot(RemoteFolder(id: "d1", name: "Club"), cache: cache)

        XCTAssertEqual(
            downloader.requestedFileIDs, [],
            "listing a library must not fetch its clips"
        )
    }

    /// A Shared Drive with no video files must not open as an empty library —
    /// `openRemoteLibrary` throws `ViewerError.noVideos` before it writes any
    /// state — and the failure has to reach `signInError` so the sheet can
    /// show it instead of silently dismissing. Asserted on both: an
    /// implementation that sets the error but still flips `isUsingRemoteLibrary`
    /// (or one that opens an empty `athletes` list) satisfies only one half.
    func testChoosingADriveWithNoVideosLeavesTheLibraryUnopenedAndReportsWhy() async throws {
        let (model, provider, cache) = try remoteModel(files: [])
        await model.signIn(with: provider)

        let opened = await model.chooseRoot(RemoteFolder(id: "empty", name: "Empty Drive"), cache: cache)

        XCTAssertFalse(opened)
        XCTAssertNotNil(model.signInError)
        XCTAssertTrue(model.athletes.isEmpty, "a drive with no videos must not open as an empty library")
        XCTAssertFalse(model.isUsingRemoteLibrary)
    }

    /// The stale-banner case: a failed pick sets `signInError`, and nothing
    /// before this fix ever cleared it, so a later, successful pick would
    /// show the earlier failure's message on top of a working library.
    /// Fails today because `chooseRoot` only ever sets `signInError`, never
    /// clears it on success.
    func testASuccessfulPickClearsAnEarlierFailedPicksError() async throws {
        let (model, provider, cache) = try remoteModel(files: [])
        await model.signIn(with: provider)

        let firstPick = await model.chooseRoot(RemoteFolder(id: "empty", name: "Empty Drive"), cache: cache)
        XCTAssertFalse(firstPick)
        XCTAssertNotNil(model.signInError, "precondition: the failed pick must have set an error")

        provider.files = [remoteFile("a", "run1.mp4", ["Neuss 2026", "Ada"])]
        let secondPick = await model.chooseRoot(RemoteFolder(id: "d1", name: "Club"), cache: cache)

        XCTAssertTrue(secondPick)
        XCTAssertNil(model.signInError, "a working pick must clear an earlier failure's message")
    }

    // MARK: - Resuming a previous session

    /// The complaint: "I don't understand why I have to login with google every
    /// time I run the app."
    ///
    /// A session Google still honours must carry the coach straight to the
    /// drive list. Asserted on `connectCallCount` staying at zero, which is the
    /// only thing that separates this from an ordinary sign-in — the drive list
    /// looks identical either way, and it is the browser the coach is
    /// complaining about.
    func testAResumableSessionOffersTheDrivesWithNoBrowser() async throws {
        let (model, provider, _) = try remoteModel(files: [])
        provider.canResumeSession = true
        provider.rootsToReturn = [RemoteFolder(id: "d1", name: "Club Footage")]

        await model.resumeSignIn(with: provider)

        XCTAssertEqual(model.availableRoots.map(\.name), ["Club Footage"])
        XCTAssertEqual(provider.connectCallCount, 0, "resuming must not open the browser")
        XCTAssertNil(model.signInError)
    }

    /// Nothing to resume — a first run, or a token Google has since refused —
    /// must land the coach on the ordinary sign-in prompt. An empty drive list
    /// is what shows that button, and there must be no error message: an
    /// automatic attempt that found nothing is not a failure the coach did
    /// anything to cause, and a red banner about it reads as a bug.
    func testWithNothingToResumeTheSheetStaysOnTheOrdinarySignInPrompt() async throws {
        let (model, provider, _) = try remoteModel(files: [])
        provider.canResumeSession = false

        await model.resumeSignIn(with: provider)

        XCTAssertEqual(provider.resumeCallCount, 1, "the silent path is tried first")
        XCTAssertTrue(model.availableRoots.isEmpty, "an empty drive list is what shows the button")
        XCTAssertNil(model.signInError, "nothing to resume is not a failure to report")
        XCTAssertEqual(provider.connectCallCount, 0, "the browser opens when the coach asks, not before")
    }

    /// The one resume outcome that must *not* be silent. The credential was
    /// accepted and the drive listing still failed, so something is wrong that
    /// the coach cannot infer from a sign-in button — and an empty library that
    /// looks like a bug is worse than being told what happened.
    func testAResumedSessionThatCannotListDrivesSaysWhy() async throws {
        let (model, provider, _) = try remoteModel(files: [])
        provider.canResumeSession = true
        provider.rootsError = RemoteLibraryError.api("Google Drive returned HTTP 500")

        await model.resumeSignIn(with: provider)

        let message = try XCTUnwrap(model.signInError, "a resumed session that then failed must say so")
        XCTAssertTrue(message.contains("500"), "got \(message)")
        XCTAssertTrue(model.availableRoots.isEmpty, "and must not look like a library with no drives")
    }

    /// After a resume finds nothing, the button still has to work. A resume
    /// that left the model in a half-signed-in state would take the coach's one
    /// remaining way in with it.
    func testSigningInStillWorksAfterAResumeFoundNothing() async throws {
        let (model, provider, _) = try remoteModel(files: [])
        provider.canResumeSession = false
        await model.resumeSignIn(with: provider)

        await model.signIn(with: provider)

        XCTAssertEqual(model.availableRoots.map(\.name), ["Test Drive"])
        XCTAssertEqual(provider.connectCallCount, 1)
    }

    // MARK: - Relaunch

    /// The whole point of the cursor: a second open must not list the drive
    /// again. Asserted on the enumeration count, which is the only thing that
    /// distinguishes "loaded the stored index" from "swept and got the same
    /// answer" — the sidebar looks identical either way.
    func testOpeningTheSameDriveTwiceSweepsOnce() async throws {
        try await withTemporaryIndexStore {
            let (model, provider, cache) = try remoteModel(files: [
                remoteFile("a", "run1.mp4", ["Neuss 2026", "Ada"]),
            ])
            let root = RemoteFolder(id: "d1", name: "Club")

            try await model.openRemoteLibrary(provider: provider, root: root, cache: cache)
            try await model.openRemoteLibrary(provider: provider, root: root, cache: cache)

            XCTAssertEqual(provider.enumerateCallCount, 1)
            XCTAssertEqual(provider.changesRequestedSince.count, 1, "the second open asks for a delta")
            XCTAssertEqual(model.athletes.map(\.name), ["Ada"])
        }
    }

    /// A clip uploaded while the app was closed appears without a re-sweep.
    /// The new clip is what proves the change was applied rather than the
    /// stored index simply reloaded.
    func testAClipAddedInDriveAppearsFromTheChangeFeed() async throws {
        try await withTemporaryIndexStore {
            let (model, provider, cache) = try remoteModel(files: [
                remoteFile("a", "run1.mp4", ["Neuss 2026", "Ada"]),
            ])
            let root = RemoteFolder(id: "d1", name: "Club")
            try await model.openRemoteLibrary(provider: provider, root: root, cache: cache)

            provider.pendingChanges = RemoteLibraryChanges(
                changed: [remoteFile("b", "run2.mp4", ["Neuss 2026", "Ada"])],
                removed: [], cursor: "cursor-2"
            )
            try await model.openRemoteLibrary(provider: provider, root: root, cache: cache)

            XCTAssertEqual(provider.enumerateCallCount, 1, "still no re-sweep")
            XCTAssertEqual(
                model.athletes.first?.videos.map(\.lastPathComponent),
                ["run1.mp4", "run2.mp4"]
            )
        }
    }

    /// A `removed` change must drop the clip from the library and leave its
    /// bytes alone. Drive reports lost access and a corpus move exactly as it
    /// reports a deletion, so a coach who regains access must not pay to
    /// download a clip that never left the disk.
    ///
    /// Fails if the removal path calls anything on the cache: the assertion is
    /// on the file existing, which only survives if nothing deleted it.
    func testARemovedClipLeavesTheLibraryButNotTheDisk() async throws {
        try await withTemporaryIndexStore {
            let (model, provider, cache) = try remoteModel(files: [
                remoteFile("a", "run1.mp4", ["Neuss 2026", "Ada"]),
                remoteFile("b", "run2.mp4", ["Neuss 2026", "Ada"]),
            ])
            let root = RemoteFolder(id: "d1", name: "Club")
            try await model.openRemoteLibrary(provider: provider, root: root, cache: cache)
            try await model.prepareCurrentClip()
            let cached = try XCTUnwrap(model.currentPlaybackURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path))

            provider.pendingChanges = RemoteLibraryChanges(
                changed: [], removed: ["a"], cursor: "cursor-2"
            )
            try await model.openRemoteLibrary(provider: provider, root: root, cache: cache)

            XCTAssertEqual(
                model.athletes.first?.videos.map(\.lastPathComponent), ["run2.mp4"],
                "the removed clip leaves the sidebar"
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: cached.path),
                "its bytes must stay: Drive reports lost access the same way"
            )
        }
    }
}
