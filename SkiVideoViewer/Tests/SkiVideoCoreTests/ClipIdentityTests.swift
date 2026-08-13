import XCTest
@testable import SkiVideoCore

final class ClipIdentityTests: XCTestCase {
    func testLocalIdentityHasNoStoreKey() {
        // A local clip's analysis sits beside the footage, so it never needs a
        // key. Nil is the signal that the keyed store does not apply.
        let identity = ClipIdentity(URL(fileURLWithPath: "/tmp/Anna/run1.mp4"))
        XCTAssertNil(identity.storeKey)
    }

    func testLocalIdentityStandardisesItsURL() {
        // Two spellings of one path must be one identity, or a clip opened via
        // a trailing-slash or dot component would get a second sidecar.
        XCTAssertEqual(
            ClipIdentity(URL(fileURLWithPath: "/tmp/Anna/./run1.mp4")),
            ClipIdentity(URL(fileURLWithPath: "/tmp/Anna/run1.mp4"))
        )
    }

    func testRemoteIdentityKeyJoinsProviderAndFileID() {
        let identity = ClipIdentity.remote(provider: "gdrive", fileID: "1AbC")
        XCTAssertEqual(identity.storeKey, "gdrive-1AbC")
    }

    func testRemoteIdentityKeyEscapesPathSeparators() throws {
        // Drive ids are URL-safe base64 today, but nothing in this type may
        // assume that: a "/" reaching the filename would silently write into a
        // sibling directory, or fail.
        let identity = ClipIdentity.remote(provider: "gdrive", fileID: "a/b..c")
        let key = try XCTUnwrap(identity.storeKey)
        XCTAssertFalse(key.contains("/"))
        XCTAssertFalse(key.contains(".."))
    }

    func testRemoteIdentitiesDifferingOnlyByProviderDoNotCollide() {
        XCTAssertNotEqual(
            ClipIdentity.remote(provider: "gdrive", fileID: "x").storeKey,
            ClipIdentity.remote(provider: "dropbox", fileID: "x").storeKey
        )
    }

    /// `pairKey`'s doc records an invariant it cannot check itself: a
    /// provider identifier must never contain "-" (the join would no longer
    /// be injective) and must never be the literal "local" (its key would be
    /// indistinguishable from a local digest). Nothing enforces this at
    /// compile time, so a real provider is guarded here directly.
    func testGoogleDriveProviderIdentifierRespectsThePairKeyInvariant() {
        XCTAssertFalse(GoogleDriveProvider.identifier.contains("-"))
        XCTAssertNotEqual(GoogleDriveProvider.identifier, "local")
    }
}
