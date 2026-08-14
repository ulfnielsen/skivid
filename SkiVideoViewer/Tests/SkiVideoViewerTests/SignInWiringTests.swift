import XCTest
@testable import SkiVideoCore
@testable import SkiVideoCoreTests

@MainActor
final class SignInWiringTests: XCTestCase {
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
}
