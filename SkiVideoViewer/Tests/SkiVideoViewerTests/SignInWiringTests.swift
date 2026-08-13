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
}
