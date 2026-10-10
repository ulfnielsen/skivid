# Rename an Event Across Athletes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a coach renames an event (date and/or title) once and every athlete's clips follow, in a Drive or a local library; a name that already exists asks before merging.

**Architecture:** a path-based `EventFolderWriting` seam with a local (`FileManager`) and a Drive (`ItemUpdatable`) implementation; a planner that reads the *live* folders and emits idempotent steps (rename / move / remove-if-empty); a `@MainActor` runner that executes them with progress and the upload's retry-vs-stop classification. Drive refresh re-lists the library whenever the change feed reports a folder, which makes renames from anywhere — this feature, Drive's web UI, another coach — show up.

**Tech Stack:** Swift 6.1 / SwiftPM (`swiftLanguageModes: [.v5]`), SwiftUI, Google Drive v3, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-10-rename-event-design.md`

**Prerequisite:** the `photos-to-club-drive` branch is merged. This plan builds on its `ItemCreatable`, `RemoteUploadError`, `FakeDriveWriter`, `FakeHTTPTransport` usage in `GoogleDriveItemCreationTests`, and `UITestPhotosToDriveSeam`. Start a fresh branch `rename-event` from `main` after that merge.

## Global Constraints

- **Nothing is ever overwritten.** A move or rename whose destination exists fails the step.
- **No new OAuth scope.** Write consent is `authorizeWrites(presenter:)`; never edit the scope string.
- **Every Drive request carries `supportsAllDrives=true`.**
- **New event names come from `SortingLibrary.eventFolder(date:title:)`** — the function sorting uses.
- **A name that already exists asks first:** Merge / Choose Another Name / Cancel, with clip and athlete counts.
- **Emptied old folders:** binned on Drive (`trashed: true`), deleted locally — only after the writer re-checks, at that moment, that the folder is empty.
- **Test command is never plain `swift test`:** `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter …`. `--filter SkiVideoCoreTests` opens no windows.
- **Never `git add -A`** (`AppBundle/` holds uncommitted artwork). Commit messages: imperative, no `feat:`/`fix:` prefix.
- **`SkiVideoCore` names no AppKit/UIKit** (`CorePurityTests`).

## Review Focus

1. **Case-only rename on a case-insensitive disk** (`Hochybrig` → `HochYbrig` on APFS): the destination "exists" because it is the same folder. Expect the rename to happen, via a temporary name. → test in Task 2.
2. **A collision clip's sidecars** (`IMG_1.skianalysis.json`, `IMG_1--IMG_9.skialignment.json`) when `IMG_1.mov` stays behind in a merge: they must stay with it, not move without it. → test in Task 3.
3. **Re-running after a stop partway through an athlete-first rename** (some athletes renamed, some not): only the remainder runs, and nothing is moved twice. → test in Task 4.
4. **Two spellings that differ only in case grouped as one event in the sidebar** (`2026-02-14_hochybrig` under one athlete, `2026-02-14_Hochybrig` under another): renaming the sidebar's event must rename both folders. → test in Task 5.
5. **An upload batch's new event folder appearing in the change feed** triggers a full re-list on the next open. Expected and accepted (spec: folder changes are rare); the re-list must still keep the stored convention choice. → test in Task 5.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/SkiVideoCore/RemoteLibraryProvider.swift` (modify) | `RemoteChild`, `ItemUpdatable` protocol; `RemoteLibraryChanges.foldersChanged` |
| `Sources/SkiVideoCore/GoogleDriveProvider+Updating.swift` (create) | Drive list-children / rename / move / trash |
| `Sources/SkiVideoCore/GoogleDriveProvider+Creating.swift` (modify) | `request`, `createdItem`, `uploadFailure` become internal so `+Updating` reuses them |
| `Sources/SkiVideoCore/GoogleDriveProvider.swift` (modify) | `changes` sets `foldersChanged` |
| `Sources/SkiVideoCore/EventFolders.swift` (create) | `FolderEntry`, `EventFolderWriting`, `LocalEventFolders`, `DriveEventFolders` |
| `Sources/SkiVideoCore/EventRenamePlan.swift` (create) | `EventRenamePlan`, `EventRenamePlanner` |
| `Sources/SkiVideoCore/EventRenameModel.swift` (create) | runner: progress, stop reasons, summary |
| `Sources/SkiVideoCore/ViewerModel.swift` (modify) | `eventRenameTarget(for:)`, `reloadOpenLibrary()`, refresh re-list on folder change |
| `Sources/SkiVideoViewer/Shared/RenameEventSheet.swift` (create) | the sheet, merge dialog, progress, summary |
| `Sources/SkiVideoViewer/Shared/ContentView.swift` (modify) | "Rename Event…" context menu on event headers; Refresh button |
| `Tests/SkiVideoCoreTests/…` | one test file per core file above; `FakeDriveWriter` gains `ItemUpdatable` |
| `Tests/SkiVideoViewerUITests/RenameEventUITests.swift` (create) | UI test against the fake Drive |

---

### Task 1: Drive can list, rename, move and bin

**Files:**
- Modify: `Sources/SkiVideoCore/RemoteLibraryProvider.swift` (after `ItemCreatable`)
- Modify: `Sources/SkiVideoCore/GoogleDriveProvider+Creating.swift` (`request`, `createdItem`, `uploadFailure`: `private static` → `static`)
- Create: `Sources/SkiVideoCore/GoogleDriveProvider+Updating.swift`
- Test: `Tests/SkiVideoCoreTests/GoogleDriveItemUpdateTests.swift`

**Interfaces:**
- Consumes: `GoogleDriveProvider.authorized(_:send:)`, `get(_:)`, `escapeQueryLiteral`, `folderMimeType`, `request(_:bearer:method:)`, `createdItem(_:_:)`, `uploadFailure(data:response:)` (403 → `RemoteUploadError.stopBatch`, 404/410 → `.retryClip`).
- Produces:
  ```swift
  public struct RemoteChild: Equatable, Sendable {
      public let id: String; public let name: String; public let isFolder: Bool
      public init(id: String, name: String, isFolder: Bool)
  }
  public protocol ItemUpdatable: ItemCreatable {
      func listChildren(of folderID: String) async throws -> [RemoteChild]
      func rename(itemID: String, to newName: String) async throws
      func move(itemID: String, from oldParentID: String, to newParentID: String) async throws
      func trash(itemID: String) async throws
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import SkiVideoCore

/// Rename, move, bin and list, asserted on the requests — the mistakes that
/// matter (a missing `supportsAllDrives`, an unescaped id) fail silently.
final class GoogleDriveItemUpdateTests: XCTestCase {
    private var transport: FakeHTTPTransport!
    private var provider: GoogleDriveProvider!

    override func setUp() {
        super.setUp()
        transport = FakeHTTPTransport()
        provider = GoogleDriveProvider(transport: transport, token: { "test-token" })
    }

    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testRenamePatchesTheNameOnASharedDrive() async throws {
        transport.responses = [.init(json: #"{"id":"f1","name":"2026-02-14_Hoch-Ybrig"}"#)]
        try await provider.rename(itemID: "f1", to: "2026-02-14_Hoch-Ybrig")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/drive/v3/files/f1")
        XCTAssertEqual(transport.queryItems(of: 0)["supportsAllDrives"], "true")
        XCTAssertEqual(try json(request)["name"] as? String, "2026-02-14_Hoch-Ybrig")
    }

    func testMoveSwapsParentsKeepingTheID() async throws {
        transport.responses = [.init(json: #"{"id":"c1","name":"IMG_1.mov"}"#)]
        try await provider.move(itemID: "c1", from: "old", to: "new")
        let query = transport.queryItems(of: 0)
        XCTAssertEqual(transport.requests[0].httpMethod, "PATCH")
        XCTAssertEqual(transport.requests[0].url?.path, "/drive/v3/files/c1")
        XCTAssertEqual(query["addParents"], "new")
        XCTAssertEqual(query["removeParents"], "old")
        XCTAssertEqual(query["supportsAllDrives"], "true")
    }

    func testTrashSetsTrashedRatherThanDeleting() async throws {
        transport.responses = [.init(json: #"{"id":"f1","name":"old"}"#)]
        try await provider.trash(itemID: "f1")
        XCTAssertEqual(transport.requests[0].httpMethod, "PATCH")
        XCTAssertEqual(try json(transport.requests[0])["trashed"] as? Bool, true)
        XCTAssertEqual(transport.queryItems(of: 0)["supportsAllDrives"], "true")
    }

    func testListChildrenPagesAndTellsFoldersFromFiles() async throws {
        transport.responses = [
            .init(json: #"{"nextPageToken":"p2","files":[{"id":"a","name":"Anna","mimeType":"application/vnd.google-apps.folder"}]}"#),
            .init(json: #"{"files":[{"id":"b","name":"IMG_1.mov","mimeType":"video/quicktime"}]}"#),
        ]
        let children = try await provider.listChildren(of: "ev1")
        XCTAssertEqual(children, [RemoteChild(id: "a", name: "Anna", isFolder: true),
                                  RemoteChild(id: "b", name: "IMG_1.mov", isFolder: false)])
        XCTAssertEqual(transport.queryItems(of: 0)["q"], "'ev1' in parents and trashed = false")
        XCTAssertEqual(transport.queryItems(of: 1)["pageToken"], "p2")
        XCTAssertEqual(transport.queryItems(of: 0)["supportsAllDrives"], "true")
    }

    func testAnEmptyFolderListsNothing() async throws {
        // Drive omits `files` entirely when nothing matches.
        transport.responses = [.init(json: #"{"kind":"drive#fileList","incompleteSearch":false}"#)]
        let children = try await provider.listChildren(of: "ev1")
        XCTAssertEqual(children, [])
    }

    func testAnIncompleteListingIsAnErrorNotAnEmptyFolder() async throws {
        transport.responses = [.init(json: #"{"incompleteSearch":true,"files":[]}"#)]
        do {
            _ = try await provider.listChildren(of: "ev1")
            XCTFail("an incomplete listing must throw")
        } catch {}
    }

    func testNoEditAccessStopsRatherThanRetries() async throws {
        transport.responses = [.init(status: 403, json: #"{"error":{"code":403,"message":"The user does not have sufficient permissions for this file."}}"#)]
        do {
            try await provider.rename(itemID: "f1", to: "x")
            XCTFail("a 403 must throw")
        } catch let error as RemoteUploadError {
            guard case .stopBatch = error else { return XCTFail("expected stopBatch, got \(error)") }
        }
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SkiVideoCoreTests.GoogleDriveItemUpdateTests`
Expected: build FAIL — `value of type 'GoogleDriveProvider' has no member 'rename'`.

- [ ] **Step 3: Add the protocol** to `RemoteLibraryProvider.swift`, directly after `ItemCreatable`:

```swift
/// One entry in a Drive folder, as a rename needs to see it.
public struct RemoteChild: Equatable, Sendable {
    public let id: String
    public let name: String
    public let isFolder: Bool

    public init(id: String, name: String, isFolder: Bool) {
        self.id = id
        self.name = name
        self.isFolder = isFolder
    }
}

/// What a provider offers when a client may rename, move and bin what is
/// already there — the event rename's writes. Its own protocol for the same
/// reason `ItemCreatable` is: a read-only provider must not carry stubs.
///
/// Ids are preserved by every operation, so clip identity, analysis and the
/// cache survive (`RemoteFile.identity(inProvider:)` is the file id).
public protocol ItemUpdatable: ItemCreatable {
    /// Everything directly in the folder, not trashed. An incomplete listing
    /// throws rather than reading as fewer children.
    func listChildren(of folderID: String) async throws -> [RemoteChild]
    func rename(itemID: String, to newName: String) async throws
    func move(itemID: String, from oldParentID: String, to newParentID: String) async throws
    /// To the bin, recoverable for 30 days — never a permanent delete.
    func trash(itemID: String) async throws
}
```

- [ ] **Step 4: Make the three helpers internal** in `GoogleDriveProvider+Creating.swift`: change `private static func request(`, `private static func createdItem(` and `private static func uploadFailure(` to `static func …`. No other change.

- [ ] **Step 5: Implement** `Sources/SkiVideoCore/GoogleDriveProvider+Updating.swift`:

```swift
import Foundation

/// The event rename's writes, beside `+Creating` and sharing its helpers.
/// Every request carries `supportsAllDrives=true`: without it a Shared Drive
/// answers 404 (see `replaceContents`).
extension GoogleDriveProvider: ItemUpdatable {
    public func listChildren(of folderID: String) async throws -> [RemoteChild] {
        var children: [RemoteChild] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            var items = [
                URLQueryItem(name: "q", value: "'\(Self.escapeQueryLiteral(folderID))' in parents and trashed = false"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
                URLQueryItem(name: "corpora", value: "allDrives"),
                URLQueryItem(name: "fields", value: "nextPageToken,incompleteSearch,files(id,name,mimeType)"),
                URLQueryItem(name: "pageSize", value: "1000"),
            ]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = items
            let page: ChildPage = try await get(components)
            if page.incompleteSearch == true {
                throw RemoteLibraryError.api("Google Drive returned an incomplete listing. Try again.")
            }
            children += page.files.map {
                RemoteChild(id: $0.id, name: $0.name, isFolder: $0.mimeType == Self.folderMimeType)
            }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return children
    }

    public func rename(itemID: String, to newName: String) async throws {
        try await patch(itemID, query: [], body: ["name": newName])
    }

    public func move(itemID: String, from oldParentID: String, to newParentID: String) async throws {
        try await patch(itemID, query: [
            URLQueryItem(name: "addParents", value: newParentID),
            URLQueryItem(name: "removeParents", value: oldParentID),
        ], body: [:])
    }

    public func trash(itemID: String) async throws {
        try await patch(itemID, query: [], body: ["trashed": true])
    }

    private func patch(_ itemID: String, query: [URLQueryItem], body: [String: Any]) async throws {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(itemID)")!
        components.queryItems = query + [
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "fields", value: "id,name"),
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await authorized({ bearer in
            var request = Self.request(components, bearer: bearer, method: "PATCH")
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload
            return request
        }, send: { try await transport.data(for: $0) })
        guard (200...299).contains(response.statusCode) else {
            throw Self.uploadFailure(data: data, response: response)
        }
    }

    /// Drive omits `files` when the folder is empty; absence means none.
    private struct ChildPage: Decodable {
        struct Entry: Decodable { let id: String; let name: String; let mimeType: String }
        let nextPageToken: String?
        let incompleteSearch: Bool?
        let files: [Entry]

        enum CodingKeys: String, CodingKey { case nextPageToken, incompleteSearch, files }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            nextPageToken = try c.decodeIfPresent(String.self, forKey: .nextPageToken)
            incompleteSearch = try c.decodeIfPresent(Bool.self, forKey: .incompleteSearch)
            files = try c.decodeIfPresent([Entry].self, forKey: .files) ?? []
        }
    }
}
```

- [ ] **Step 6: Run to verify they pass**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "SkiVideoCoreTests.GoogleDriveItemUpdateTests|SkiVideoCoreTests.GoogleDriveItemCreationTests"`
Expected: PASS (the creation tests prove the helpers kept their behaviour).

- [ ] **Step 7: Commit**

```bash
git add Sources/SkiVideoCore/RemoteLibraryProvider.swift Sources/SkiVideoCore/GoogleDriveProvider+Creating.swift Sources/SkiVideoCore/GoogleDriveProvider+Updating.swift Tests/SkiVideoCoreTests/GoogleDriveItemUpdateTests.swift
git commit -m "Let Drive list, rename, move and bin what is already there"
```

---

### Task 2: One folder seam, local and Drive

**Files:**
- Create: `Sources/SkiVideoCore/EventFolders.swift`
- Modify: `Tests/SkiVideoCoreTests/FakeDriveWriter.swift` (conform to `ItemUpdatable`)
- Test: `Tests/SkiVideoCoreTests/EventFoldersTests.swift`

**Interfaces:**
- Consumes: `ItemUpdatable` (Task 1); `ItemCreatable.findFolder(named:parent:)`, `authorizeWrites(presenter:)`; `RemoteUploadError.stopBatch`.
- Produces:
  ```swift
  public struct FolderEntry: Equatable, Sendable { public let name: String; public let isFolder: Bool }
  public protocol EventFolderWriting: Sendable {
      func prepareToWrite() async throws
      func children(of path: [String]) async throws -> [FolderEntry]?   // nil = no such folder
      func rename(_ path: [String], to newName: String) async throws    // no-op if `path` is gone
      func move(_ name: String, from source: [String], to destination: [String]) async throws // no-op if gone
      func removeIfEmpty(_ path: [String]) async throws -> Bool         // re-checks emptiness itself
  }
  public struct LocalEventFolders: EventFolderWriting { public init(root: URL) }
  public struct DriveEventFolders: EventFolderWriting {
      public init(writer: any ItemUpdatable, rootID: String, presenter: OAuthPresenter)
  }
  ```
  Paths are folder names from the library root, e.g. `["2026-02-14_Hochybrig", "Anna"]`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import SkiVideoCore

/// The folder seam on real temporary directories (local) and on the
/// in-memory Drive (`FakeDriveWriter`), so both implementations are held to
/// one contract.
final class EventFoldersTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("EventFolders-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func file(_ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: url)
    }

    // MARK: Local

    func testLocalListsFoldersAndFilesAndSaysWhenAFolderIsMissing() async throws {
        try file("2026-02-14_A/Anna/IMG_1.mov")
        let folders = LocalEventFolders(root: root)
        let event = try await folders.children(of: ["2026-02-14_A"])
        XCTAssertEqual(event, [FolderEntry(name: "Anna", isFolder: true)])
        let missing = try await folders.children(of: ["nope"])
        XCTAssertNil(missing)
    }

    func testLocalRenameNeverOverwrites() async throws {
        try file("2026-02-14_A/Anna/IMG_1.mov")
        try file("2026-02-14_B/Bo/IMG_2.mov")
        let folders = LocalEventFolders(root: root)
        do {
            try await folders.rename(["2026-02-14_A"], to: "2026-02-14_B")
            XCTFail("renaming onto an existing folder must throw")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("2026-02-14_A/Anna/IMG_1.mov").path))
    }

    /// Review Focus 1: APFS is case-insensitive, so the destination "exists".
    func testLocalCaseOnlyRenameHappens() async throws {
        try file("2026-02-14_Hochybrig/Anna/IMG_1.mov")
        let folders = LocalEventFolders(root: root)
        try await folders.rename(["2026-02-14_Hochybrig"], to: "2026-02-14_HochYbrig")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(names, ["2026-02-14_HochYbrig"])
    }

    func testLocalMoveOfAMissingItemIsANoOp() async throws {
        try file("2026-02-14_A/Anna/IMG_1.mov")
        let folders = LocalEventFolders(root: root)
        try await folders.move("gone.mov", from: ["2026-02-14_A", "Anna"], to: ["2026-02-14_A"])
    }

    func testLocalRemovesOnlyAnEmptyFolder() async throws {
        try file("2026-02-14_A/Anna/IMG_1.mov")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("2026-02-14_A/Bo"),
                                                withIntermediateDirectories: true)
        let folders = LocalEventFolders(root: root)
        let removedFull = try await folders.removeIfEmpty(["2026-02-14_A", "Anna"])
        let removedEmpty = try await folders.removeIfEmpty(["2026-02-14_A", "Bo"])
        XCTAssertFalse(removedFull)
        XCTAssertTrue(removedEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("2026-02-14_A/Anna/IMG_1.mov").path))
    }

    // MARK: Drive

    func testDriveResolvesPathsAndRenamesByID() async throws {
        let drive = FakeDriveWriter()
        drive.seedFile("IMG_1.mov", at: ["2026-02-14_A", "Anna"])
        let folders = DriveEventFolders(writer: drive, rootID: "root-1", presenter: FakeOAuthPresenter())
        try await folders.rename(["2026-02-14_A"], to: "2026-02-14_B")
        XCTAssertEqual(drive.path(ofFile: "IMG_1.mov"), ["2026-02-14_B", "Anna"])
    }

    func testDriveMovesAFileIntoAnotherFolder() async throws {
        let drive = FakeDriveWriter()
        drive.seedFile("IMG_1.mov", at: ["2026-02-14_A", "Anna"])
        drive.seedFile("IMG_2.mov", at: ["2026-02-14_B", "Anna"])
        let folders = DriveEventFolders(writer: drive, rootID: "root-1", presenter: FakeOAuthPresenter())
        try await folders.move("IMG_1.mov", from: ["2026-02-14_A", "Anna"], to: ["2026-02-14_B", "Anna"])
        XCTAssertEqual(drive.path(ofFile: "IMG_1.mov"), ["2026-02-14_B", "Anna"])
    }

    func testDriveBinsOnlyAnEmptyFolder() async throws {
        let drive = FakeDriveWriter()
        drive.seedFile("IMG_1.mov", at: ["2026-02-14_A", "Anna"])
        let folders = DriveEventFolders(writer: drive, rootID: "root-1", presenter: FakeOAuthPresenter())
        let binned = try await folders.removeIfEmpty(["2026-02-14_A"])
        XCTAssertFalse(binned)
        XCTAssertEqual(drive.trashedIDs, [])
    }

    func testDrivePreparingToWriteAsksForConsent() async throws {
        let drive = FakeDriveWriter()
        let folders = DriveEventFolders(writer: drive, rootID: "root-1", presenter: FakeOAuthPresenter())
        try await folders.prepareToWrite()
        XCTAssertEqual(drive.authorizeCount, 1)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SkiVideoCoreTests.EventFoldersTests`
Expected: build FAIL — `cannot find 'LocalEventFolders' in scope`.

- [ ] **Step 3: Give `FakeDriveWriter` the update operations.** Add to `Tests/SkiVideoCoreTests/FakeDriveWriter.swift` (inside the class; it already has `folders`, `files`, `locked`, `folderIDLocked`, `mintLocked`):

```swift
    private var _trashedIDs: [String] = []
    var trashedIDs: [String] { locked { _trashedIDs } }

    // MARK: ItemUpdatable

    func listChildren(of folderID: String) async throws -> [RemoteChild] {
        locked {
            let subfolders = folders.filter { $0.value.parent == folderID && !_trashedIDs.contains($0.key) }
                .map { RemoteChild(id: $0.key, name: $0.value.name, isFolder: true) }
            let contained = files.filter { $0.parent == folderID }
                .map { RemoteChild(id: $0.id, name: $0.name, isFolder: false) }
            return (subfolders + contained).sorted { $0.name < $1.name }
        }
    }

    func rename(itemID: String, to newName: String) async throws {
        locked {
            if let folder = folders[itemID] { folders[itemID] = (newName, folder.parent) }
            if let index = files.firstIndex(where: { $0.id == itemID }) { files[index].name = newName }
        }
    }

    func move(itemID: String, from oldParentID: String, to newParentID: String) async throws {
        locked {
            if let folder = folders[itemID] { folders[itemID] = (folder.name, newParentID) }
            if let index = files.firstIndex(where: { $0.id == itemID }) { files[index].parent = newParentID }
        }
    }

    func trash(itemID: String) async throws { locked { _trashedIDs.append(itemID) } }
```
Change the class declaration to `final class FakeDriveWriter: ItemUpdatable, @unchecked Sendable`. If `files` is declared with `let` tuple members, change its element to `(id: String, name: String, parent: String)` held in a `var` array (it already is `private var files`).

- [ ] **Step 4: Implement** `Sources/SkiVideoCore/EventFolders.swift`:

```swift
import Foundation

/// One entry in a library folder.
public struct FolderEntry: Equatable, Sendable {
    public let name: String
    public let isFolder: Bool

    public init(name: String, isFolder: Bool) {
        self.name = name
        self.isFolder = isFolder
    }
}

/// The folders of one library, addressed by names from its root — the seam
/// the event rename plans and writes through, so the same planner and runner
/// serve a Drive and a local library.
///
/// `rename` and `move` are no-ops when their source is already gone: that is
/// what makes a re-run after a partial failure finish the job instead of
/// failing on the steps that already happened. Neither ever overwrites.
public protocol EventFolderWriting: Sendable {
    /// Consent (Drive) or a writability check (local), before anything moves.
    func prepareToWrite() async throws
    func children(of path: [String]) async throws -> [FolderEntry]?
    func rename(_ path: [String], to newName: String) async throws
    func move(_ name: String, from source: [String], to destination: [String]) async throws
    /// Bins (Drive) or deletes (local) the folder only if it is empty *now*,
    /// checked here rather than trusted from a plan made earlier.
    func removeIfEmpty(_ path: [String]) async throws -> Bool
}

// MARK: - Local

public struct LocalEventFolders: EventFolderWriting {
    private let root: URL

    public init(root: URL) { self.root = root }

    private func url(_ path: [String]) -> URL {
        path.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    public func prepareToWrite() async throws {
        guard FileManager.default.isWritableFile(atPath: root.path) else {
            throw RemoteUploadError.stopBatch(
                "“\(root.lastPathComponent)” is read-only, so its events cannot be renamed.")
        }
    }

    public func children(of path: [String]) async throws -> [FolderEntry]? {
        let folder = url(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ).map {
            FolderEntry(name: $0.lastPathComponent,
                        isFolder: (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
        }.sorted { $0.name < $1.name }
    }

    public func rename(_ path: [String], to newName: String) async throws {
        let source = url(path)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let destination = source.deletingLastPathComponent().appendingPathComponent(newName, isDirectory: true)
        if source.lastPathComponent.caseInsensitiveCompare(newName) == .orderedSame {
            // Review Focus 1: on a case-insensitive volume the destination
            // "exists" because it is the source. Two moves, via a name no
            // one else uses.
            let step = source.deletingLastPathComponent()
                .appendingPathComponent(".rename-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.moveItem(at: source, to: step)
            try FileManager.default.moveItem(at: step, to: destination)
            return
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw RemoteUploadError.stopBatch("“\(newName)” already exists, so nothing was overwritten.")
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    public func move(_ name: String, from source: [String], to destination: [String]) async throws {
        let from = url(source).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: from.path) else { return }
        let to = url(destination).appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: to.path) else {
            throw RemoteUploadError.stopBatch("“\(name)” is already in the target, so nothing was overwritten.")
        }
        try FileManager.default.moveItem(at: from, to: to)
    }

    public func removeIfEmpty(_ path: [String]) async throws -> Bool {
        guard let children = try await children(of: path), children.isEmpty else { return false }
        try FileManager.default.removeItem(at: url(path))
        return true
    }
}

// MARK: - Drive

public struct DriveEventFolders: EventFolderWriting {
    private let writer: any ItemUpdatable
    private let rootID: String
    private let presenter: OAuthPresenter

    public init(writer: any ItemUpdatable, rootID: String, presenter: OAuthPresenter) {
        self.writer = writer
        self.rootID = rootID
        self.presenter = presenter
    }

    public func prepareToWrite() async throws {
        try await writer.authorizeWrites(presenter: presenter)
    }

    /// Walks names to an id from the root; nil when any step is missing.
    private func folderID(_ path: [String]) async throws -> String? {
        var current = rootID
        for name in path {
            guard let next = try await writer.findFolder(named: name, parent: current) else { return nil }
            current = next.id
        }
        return current
    }

    public func children(of path: [String]) async throws -> [FolderEntry]? {
        guard let id = try await folderID(path) else { return nil }
        return try await writer.listChildren(of: id).map { FolderEntry(name: $0.name, isFolder: $0.isFolder) }
    }

    public func rename(_ path: [String], to newName: String) async throws {
        guard let id = try await folderID(path) else { return }
        try await writer.rename(itemID: id, to: newName)
    }

    public func move(_ name: String, from source: [String], to destination: [String]) async throws {
        guard let from = try await folderID(source),
              let item = try await writer.listChildren(of: from).first(where: { $0.name == name })
        else { return }
        guard let to = try await folderID(destination) else {
            throw RemoteUploadError.retryClip("The target folder for “\(name)” was not found.")
        }
        if try await writer.listChildren(of: to).contains(where: { $0.name == name }) {
            throw RemoteUploadError.stopBatch("“\(name)” is already in the target, so nothing was overwritten.")
        }
        try await writer.move(itemID: item.id, from: from, to: to)
    }

    public func removeIfEmpty(_ path: [String]) async throws -> Bool {
        guard let id = try await folderID(path), try await writer.listChildren(of: id).isEmpty else {
            return false
        }
        try await writer.trash(itemID: id)
        return true
    }
}
```

- [ ] **Step 5: Run to verify they pass**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "SkiVideoCoreTests.EventFoldersTests|SkiVideoCoreTests.UploadBatchModelTests"`
Expected: PASS (the batch tests prove `FakeDriveWriter` still serves the upload).

- [ ] **Step 6: Commit**

```bash
git add Sources/SkiVideoCore/EventFolders.swift Tests/SkiVideoCoreTests/EventFoldersTests.swift Tests/SkiVideoCoreTests/FakeDriveWriter.swift
git commit -m "Address a library's folders by name, the same way locally and in Drive"
```

---

### Task 3: Plan the rename from the folders as they are

**Files:**
- Create: `Sources/SkiVideoCore/EventRenamePlan.swift`
- Test: `Tests/SkiVideoCoreTests/EventRenamePlanTests.swift`

**Interfaces:**
- Consumes: `EventFolderWriting`, `FolderEntry`, `LocalEventFolders` (Task 2); `VideoLibrary.supportedExtensions`.
- Produces:
  ```swift
  public struct EventRenamePlan: Equatable, Sendable {
      public enum Step: Equatable, Sendable {
          case rename([String], to: String)
          case move(String, from: [String], to: [String])
          case removeIfEmpty([String])
      }
      public var steps: [Step]
      public var leftInPlace: [[String]]     // full paths of files kept because the target has them
      public var mergesIntoExisting: Bool
  }
  public enum EventRenamePlanner {
      public static func plan(eventFolders: [[String]], newName: String,
                              in folders: any EventFolderWriting) async throws -> EventRenamePlan
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import SkiVideoCore

/// Plans read the live folders, so every test builds a real directory and
/// plans through `LocalEventFolders`.
final class EventRenamePlanTests: XCTestCase {
    private var root: URL!
    private var folders: LocalEventFolders!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        folders = LocalEventFolders(root: root)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func file(_ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: url)
    }

    func testEventFirstWithNoTargetIsOneRename() async throws {
        try file("2026-02-14_Hochybrig/Anna/IMG_1.mov")
        let plan = try await EventRenamePlanner.plan(
            eventFolders: [["2026-02-14_Hochybrig"]], newName: "2026-02-14_Hoch-Ybrig", in: folders)
        XCTAssertEqual(plan.steps, [.rename(["2026-02-14_Hochybrig"], to: "2026-02-14_Hoch-Ybrig")])
        XCTAssertFalse(plan.mergesIntoExisting)
    }

    func testAthleteFirstRenamesUnderEveryAthlete() async throws {
        try file("Anna/2026-02-14_Hochybrig/IMG_1.mov")
        try file("Bo/2026-02-14_Hochybrig/IMG_2.mov")
        let plan = try await EventRenamePlanner.plan(
            eventFolders: [["Anna", "2026-02-14_Hochybrig"], ["Bo", "2026-02-14_Hochybrig"]],
            newName: "2026-02-14_Hoch-Ybrig", in: folders)
        XCTAssertEqual(plan.steps, [
            .rename(["Anna", "2026-02-14_Hochybrig"], to: "2026-02-14_Hoch-Ybrig"),
            .rename(["Bo", "2026-02-14_Hochybrig"], to: "2026-02-14_Hoch-Ybrig"),
        ])
    }

    func testMergeMovesNewAthletesWholeAndMergesSharedOnesClipByClip() async throws {
        try file("2026-02-14_Hochybrig/Anna/IMG_1.mov")
        try file("2026-02-14_Hochybrig/Bo/IMG_2.mov")
        try file("2026-02-14_Hoch-Ybrig/Anna/IMG_9.mov")
        let plan = try await EventRenamePlanner.plan(
            eventFolders: [["2026-02-14_Hochybrig"]], newName: "2026-02-14_Hoch-Ybrig", in: folders)
        XCTAssertTrue(plan.mergesIntoExisting)
        XCTAssertEqual(plan.steps, [
            .move("IMG_1.mov", from: ["2026-02-14_Hochybrig", "Anna"], to: ["2026-02-14_Hoch-Ybrig", "Anna"]),
            .removeIfEmpty(["2026-02-14_Hochybrig", "Anna"]),
            .move("Bo", from: ["2026-02-14_Hochybrig"], to: ["2026-02-14_Hoch-Ybrig"]),
            .removeIfEmpty(["2026-02-14_Hochybrig"]),
        ])
        XCTAssertEqual(plan.leftInPlace, [])
    }

    /// Review Focus 2: a clip that stays keeps its sidecars with it.
    func testACollidingClipStaysWithItsSidecars() async throws {
        try file("2026-02-14_Hochybrig/Anna/IMG_1.mov")
        try file("2026-02-14_Hochybrig/Anna/IMG_1.skianalysis.json")
        try file("2026-02-14_Hochybrig/Anna/IMG_1--IMG_7.skialignment.json")
        try file("2026-02-14_Hochybrig/Anna/IMG_2.mov")
        try file("2026-02-14_Hochybrig/Anna/IMG_2.skianalysis.json")
        try file("2026-02-14_Hoch-Ybrig/Anna/IMG_1.mov")
        let plan = try await EventRenamePlanner.plan(
            eventFolders: [["2026-02-14_Hochybrig"]], newName: "2026-02-14_Hoch-Ybrig", in: folders)
        let moved = plan.steps.compactMap { step -> String? in
            if case let .move(name, _, _) = step { return name }
            return nil
        }
        XCTAssertEqual(Set(moved), ["IMG_2.mov", "IMG_2.skianalysis.json"])
        XCTAssertEqual(Set(plan.leftInPlace.map { $0.last! }),
                       ["IMG_1.mov", "IMG_1.skianalysis.json", "IMG_1--IMG_7.skialignment.json"])
    }

    func testAFolderAlreadyRenamedPlansNothing() async throws {
        try file("2026-02-14_Hoch-Ybrig/Anna/IMG_1.mov")
        let plan = try await EventRenamePlanner.plan(
            eventFolders: [["2026-02-14_Hochybrig"]], newName: "2026-02-14_Hoch-Ybrig", in: folders)
        XCTAssertEqual(plan.steps, [])
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SkiVideoCoreTests.EventRenamePlanTests`
Expected: build FAIL — `cannot find 'EventRenamePlanner' in scope`.

- [ ] **Step 3: Implement** `Sources/SkiVideoCore/EventRenamePlan.swift`:

```swift
import Foundation

/// What renaming one event will do, worked out from the folders as they are
/// *now* — so planning again after a partial run yields only what is left.
public struct EventRenamePlan: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case rename([String], to: String)
        case move(String, from: [String], to: [String])
        case removeIfEmpty([String])
    }

    public var steps: [Step] = []
    /// Files that stay where they are because the target already holds the
    /// same name — a clip together with its sidecars. Never overwritten.
    public var leftInPlace: [[String]] = []
    /// True when the new name already exists somewhere this rename touches,
    /// which is what the "Merge?" question is about.
    public var mergesIntoExisting = false
}

public enum EventRenamePlanner {
    /// - Parameter eventFolders: every folder of the event, as names from the
    ///   library root (one for an event-first library, one per athlete for an
    ///   athlete-first one).
    public static func plan(
        eventFolders: [[String]], newName: String, in folders: any EventFolderWriting
    ) async throws -> EventRenamePlan {
        var plan = EventRenamePlan()
        for path in eventFolders.sorted(by: { $0.joined(separator: "/") < $1.joined(separator: "/") }) {
            guard let oldName = path.last, oldName != newName,
                  try await folders.children(of: path) != nil else { continue }
            let parent = Array(path.dropLast())
            let siblings = try await folders.children(of: parent) ?? []
            let target = parent + [newName]
            if siblings.contains(where: { $0.isFolder && $0.name == newName }) {
                plan.mergesIntoExisting = true
                try await merge(path, into: target, folders: folders, plan: &plan)
                plan.steps.append(.removeIfEmpty(path))
            } else {
                plan.steps.append(.rename(path, to: newName))
            }
        }
        return plan
    }

    private static func merge(
        _ source: [String], into target: [String],
        folders: any EventFolderWriting, plan: inout EventRenamePlan
    ) async throws {
        let incoming = try await folders.children(of: source) ?? []
        let existing = Dictionary((try await folders.children(of: target) ?? []).map { ($0.name, $0) },
                                  uniquingKeysWith: { first, _ in first })
        // A clip that stays keeps its sidecars (`<stem>.skianalysis.json`,
        // `<stem>--<other>.skialignment.json`) with it: moving them alone
        // would file one clip's analysis beside another.
        let stayingStems = incoming
            .filter { !$0.isFolder && existing[$0.name] != nil && isVideo($0.name) }
            .map { ($0.name as NSString).deletingPathExtension }
        for entry in incoming {
            if let clash = existing[entry.name] {
                if entry.isFolder && clash.isFolder {
                    try await merge(source + [entry.name], into: target + [entry.name],
                                    folders: folders, plan: &plan)
                    plan.steps.append(.removeIfEmpty(source + [entry.name]))
                } else {
                    plan.leftInPlace.append(source + [entry.name])
                }
            } else if !entry.isFolder, stayingStems.contains(where: { belongs(entry.name, to: $0) }) {
                plan.leftInPlace.append(source + [entry.name])
            } else {
                plan.steps.append(.move(entry.name, from: source, to: target))
            }
        }
    }

    private static func isVideo(_ name: String) -> Bool {
        VideoLibrary.supportedExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private static func belongs(_ name: String, to stem: String) -> Bool {
        name.hasPrefix(stem + ".") || name.hasPrefix(stem + "--")
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SkiVideoCoreTests.EventRenamePlanTests`
Expected: PASS. (`testMergeMoves…` asserts order: entries are listed sorted by name, so `Anna` before `Bo`.)

- [ ] **Step 5: Commit**

```bash
git add Sources/SkiVideoCore/EventRenamePlan.swift Tests/SkiVideoCoreTests/EventRenamePlanTests.swift
git commit -m "Plan an event rename from the folders as they are"
```

---

### Task 4: Run the plan, and finish it on a second try

**Files:**
- Create: `Sources/SkiVideoCore/EventRenameModel.swift`
- Test: `Tests/SkiVideoCoreTests/EventRenameModelTests.swift`

**Interfaces:**
- Consumes: `EventRenamePlanner`, `EventRenamePlan` (Task 3); `EventFolderWriting` (Task 2); `RemoteUploadError`, `RemoteLibraryError.notSignedIn`.
- Produces:
  ```swift
  public struct EventClipCount: Equatable, Sendable { public let clips: Int; public let athletes: Int }
  @MainActor public final class EventRenameModel: ObservableObject {
      public init(oldName: String, eventFolders: [[String]], folders: any EventFolderWriting)
      @Published public private(set) var done: Int
      @Published public private(set) var total: Int
      @Published public private(set) var isRunning: Bool
      @Published public private(set) var stopReason: String?      // set on failure
      @Published public private(set) var leftInPlace: [[String]]   // after success
      public let oldName: String
      public func targetExists(newName: String) async throws -> Bool
      @discardableResult public func run(newName: String) async -> Bool
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import SkiVideoCore

@MainActor
final class EventRenameModelTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func file(_ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: url)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    func testARenameMovesEveryAthletesClips() async throws {
        try file("Anna/2026-02-14_Hochybrig/IMG_1.mov")
        try file("Bo/2026-02-14_Hochybrig/IMG_2.mov")
        let model = EventRenameModel(
            oldName: "2026-02-14_Hochybrig",
            eventFolders: [["Anna", "2026-02-14_Hochybrig"], ["Bo", "2026-02-14_Hochybrig"]],
            folders: LocalEventFolders(root: root))
        let ok = await model.run(newName: "2026-02-14_Hoch-Ybrig")
        XCTAssertTrue(ok)
        XCTAssertTrue(exists("Anna/2026-02-14_Hoch-Ybrig/IMG_1.mov"))
        XCTAssertTrue(exists("Bo/2026-02-14_Hoch-Ybrig/IMG_2.mov"))
        XCTAssertEqual(model.done, 2)
        XCTAssertEqual(model.total, 2)
    }

    /// Review Focus 3: stop partway, then try again.
    func testAStoppedRunFinishesOnTheSecondTryWithoutRepeatingWork() async throws {
        try file("Anna/2026-02-14_Hochybrig/IMG_1.mov")
        try file("Bo/2026-02-14_Hochybrig/IMG_2.mov")
        let flaky = FlakyFolders(LocalEventFolders(root: root), failRenamesAfter: 1)
        let model = EventRenameModel(
            oldName: "2026-02-14_Hochybrig",
            eventFolders: [["Anna", "2026-02-14_Hochybrig"], ["Bo", "2026-02-14_Hochybrig"]],
            folders: flaky)

        let first = await model.run(newName: "2026-02-14_Hoch-Ybrig")
        XCTAssertFalse(first)
        XCTAssertEqual(model.stopReason?.hasPrefix("Renamed 1 of 2"), true)
        XCTAssertTrue(exists("Anna/2026-02-14_Hoch-Ybrig/IMG_1.mov"))
        XCTAssertTrue(exists("Bo/2026-02-14_Hochybrig/IMG_2.mov"))

        flaky.heal()
        let second = await model.run(newName: "2026-02-14_Hoch-Ybrig")
        XCTAssertTrue(second)
        XCTAssertEqual(model.total, 1, "only the remaining athlete is renamed")
        XCTAssertTrue(exists("Bo/2026-02-14_Hoch-Ybrig/IMG_2.mov"))
        XCTAssertNil(model.stopReason)
    }

    func testNoEditAccessStopsAndSaysWhy() async throws {
        try file("2026-02-14_Hochybrig/Anna/IMG_1.mov")
        let model = EventRenameModel(
            oldName: "2026-02-14_Hochybrig", eventFolders: [["2026-02-14_Hochybrig"]],
            folders: RefusingFolders())
        let ok = await model.run(newName: "2026-02-14_Hoch-Ybrig")
        XCTAssertFalse(ok)
        XCTAssertEqual(model.stopReason, "You cannot edit this Drive.")
    }

    func testAMergeLeavesCollisionsAndBinsWhatEmptied() async throws {
        try file("2026-02-14_Hochybrig/Anna/IMG_1.mov")
        try file("2026-02-14_Hochybrig/Anna/IMG_2.mov")
        try file("2026-02-14_Hoch-Ybrig/Anna/IMG_1.mov")
        let model = EventRenameModel(
            oldName: "2026-02-14_Hochybrig", eventFolders: [["2026-02-14_Hochybrig"]],
            folders: LocalEventFolders(root: root))
        let merges = try await model.targetExists(newName: "2026-02-14_Hoch-Ybrig")
        XCTAssertTrue(merges)
        let ok = await model.run(newName: "2026-02-14_Hoch-Ybrig")
        XCTAssertTrue(ok)
        XCTAssertTrue(exists("2026-02-14_Hoch-Ybrig/Anna/IMG_2.mov"))
        XCTAssertTrue(exists("2026-02-14_Hochybrig/Anna/IMG_1.mov"), "the collision stays")
        XCTAssertEqual(model.leftInPlace, [["2026-02-14_Hochybrig", "Anna", "IMG_1.mov"]])
    }
}

/// Fails every rename after the first `n`, as a dropped signal would.
private final class FlakyFolders: EventFolderWriting, @unchecked Sendable {
    private let inner: LocalEventFolders
    private var remaining: Int
    init(_ inner: LocalEventFolders, failRenamesAfter n: Int) { self.inner = inner; remaining = n }
    func heal() { remaining = .max }
    func prepareToWrite() async throws {}
    func children(of path: [String]) async throws -> [FolderEntry]? { try await inner.children(of: path) }
    func rename(_ path: [String], to newName: String) async throws {
        guard remaining > 0 else { throw URLError(.networkConnectionLost) }
        remaining -= 1
        try await inner.rename(path, to: newName)
    }
    func move(_ name: String, from source: [String], to destination: [String]) async throws {
        try await inner.move(name, from: source, to: destination)
    }
    func removeIfEmpty(_ path: [String]) async throws -> Bool { try await inner.removeIfEmpty(path) }
}

private struct RefusingFolders: EventFolderWriting {
    func prepareToWrite() async throws { throw RemoteUploadError.stopBatch("You cannot edit this Drive.") }
    func children(of path: [String]) async throws -> [FolderEntry]? { [] }
    func rename(_ path: [String], to newName: String) async throws {}
    func move(_ name: String, from source: [String], to destination: [String]) async throws {}
    func removeIfEmpty(_ path: [String]) async throws -> Bool { false }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SkiVideoCoreTests.EventRenameModelTests`
Expected: build FAIL — `cannot find 'EventRenameModel' in scope`.

- [ ] **Step 3: Implement** `Sources/SkiVideoCore/EventRenameModel.swift`:

```swift
import Foundation

/// What an event holds, for the "Merge?" question.
public struct EventClipCount: Equatable, Sendable {
    public let clips: Int
    public let athletes: Int

    public init(clips: Int, athletes: Int) {
        self.clips = clips
        self.athletes = athletes
    }
}

/// Runs one event's rename: plans from the live folders, executes step by
/// step with progress, and stops with a reason the coach can act on. Running
/// it again re-plans, so a rename stopped partway finishes instead of
/// repeating what already happened.
@MainActor
public final class EventRenameModel: ObservableObject {
    public let oldName: String
    private let eventFolders: [[String]]
    private let folders: any EventFolderWriting

    @Published public private(set) var done = 0
    @Published public private(set) var total = 0
    @Published public private(set) var isRunning = false
    @Published public private(set) var stopReason: String?
    @Published public private(set) var leftInPlace: [[String]] = []

    public init(oldName: String, eventFolders: [[String]], folders: any EventFolderWriting) {
        self.oldName = oldName
        self.eventFolders = eventFolders
        self.folders = folders
    }

    /// Whether `newName` already exists where this rename would put it — the
    /// moment to ask "Merge?", before anything moves.
    public func targetExists(newName: String) async throws -> Bool {
        try await EventRenamePlanner.plan(eventFolders: eventFolders, newName: newName, in: folders)
            .mergesIntoExisting
    }

    @discardableResult
    public func run(newName: String) async -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        defer { isRunning = false }
        stopReason = nil
        done = 0
        total = 0
        do {
            try await folders.prepareToWrite()
            let plan = try await EventRenamePlanner.plan(eventFolders: eventFolders, newName: newName, in: folders)
            total = plan.steps.count
            for step in plan.steps {
                switch step {
                case let .rename(path, newName):
                    try await folders.rename(path, to: newName)
                case let .move(name, source, destination):
                    try await folders.move(name, from: source, to: destination)
                case let .removeIfEmpty(path):
                    _ = try await folders.removeIfEmpty(path)
                }
                done += 1
            }
            leftInPlace = plan.leftInPlace
            return true
        } catch {
            stopReason = Self.reason(for: error, done: done, total: total)
            return false
        }
    }

    /// The upload's split: no access or signed out stops outright; anything
    /// else is worth another try, and says how far it got.
    private static func reason(for error: Error, done: Int, total: Int) -> String {
        if case let RemoteUploadError.stopBatch(message) = error { return message }
        if case RemoteLibraryError.notSignedIn = error { return "Sign in to Google Drive again, then try again." }
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return "Renamed \(done) of \(total) — \(detail). Try again."
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SkiVideoCoreTests.EventRenameModelTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SkiVideoCore/EventRenameModel.swift Tests/SkiVideoCoreTests/EventRenameModelTests.swift
git commit -m "Run an event rename step by step, and finish it on a second try"
```

---

### Task 5: The open library offers its events for renaming, and refreshes honestly

**Files:**
- Modify: `Sources/SkiVideoCore/RemoteLibraryProvider.swift` (`RemoteLibraryChanges.foldersChanged`)
- Modify: `Sources/SkiVideoCore/GoogleDriveProvider.swift` (`changes` sets it)
- Modify: `Sources/SkiVideoCore/ViewerModel.swift` (`openRemoteLibrary` re-lists on folder change; `eventRenameTarget(for:)`; `eventClipCount(named:)`; `reloadOpenLibrary()`)
- Test: `Tests/SkiVideoCoreTests/EventRenameTargetTests.swift`

**Interfaces:**
- Consumes: `EventRenameModel`, `EventClipCount` (Task 4); `LocalEventFolders`, `DriveEventFolders` (Task 2); `ItemUpdatable` (Task 1).
- Produces:
  ```swift
  public enum EventRenameRefusal: Error, Equatable, LocalizedError {
      case noLibraryOpen, cannotWrite(libraryName: String)
  }
  extension ViewerModel {
      public func eventRenameTarget(for eventName: String) throws -> EventRenameModel
      public func eventClipCount(named eventName: String) -> EventClipCount
      public func reloadOpenLibrary() async throws
  }
  public struct RemoteLibraryChanges { public let foldersChanged: Bool }   // init gains `foldersChanged: Bool = false`
  ```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import SkiVideoCore

@MainActor
final class EventRenameTargetTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func openDrive(_ files: [RemoteFile], convention: FolderConvention,
                           writer: FakeDriveWriter = FakeDriveWriter()) async throws -> ViewerModel {
        writer.listedFiles = files
        var model: ViewerModel!
        try await withTemporaryIndexStore {
            model = ViewerModel(input: FakeInputSource(), folderPicker: FakeFolderPicker(),
                                oauthPresenter: FakeOAuthPresenter())
            await model.signIn(with: writer)
            _ = await model.chooseRoot(RemoteFolder(id: "drive-1", name: "Club"),
                                       cache: ClipCache(root: root.appendingPathComponent(".cache"),
                                                        downloader: FakeClipDownloader(), budget: 1_000),
                                       convention: convention)
        }
        return model
    }

    func testAnEventFirstDriveEventIsOneFolder() async throws {
        let model = try await openDrive([
            remoteFile("1", "a.mov", ["2026-02-14_Hochybrig", "Anna"]),
            remoteFile("2", "b.mov", ["2026-02-14_Hochybrig", "Bo"]),
        ], convention: .eventThenAthlete)
        let rename = try model.eventRenameTarget(for: "2026-02-14_Hochybrig")
        XCTAssertEqual(rename.oldName, "2026-02-14_Hochybrig")
        XCTAssertEqual(model.eventClipCount(named: "2026-02-14_Hochybrig"), EventClipCount(clips: 2, athletes: 2))
    }

    /// Review Focus 4: case variants grouped as one event are all renamed.
    func testAthleteFirstCollectsEveryAthletesFolderIgnoringCase() async throws {
        let model = try await openDrive([
            remoteFile("1", "a.mov", ["Anna", "2026-02-14_hochybrig"]),
            remoteFile("2", "b.mov", ["Bo", "2026-02-14_Hochybrig"]),
        ], convention: .athleteThenEvent)
        XCTAssertEqual(model.eventRenameFolders(for: "2026-02-14_Hochybrig"),
                       [["Anna", "2026-02-14_hochybrig"], ["Bo", "2026-02-14_Hochybrig"]])
    }

    func testNothingOpenRefuses() {
        let model = ViewerModel(input: FakeInputSource(), folderPicker: FakeFolderPicker(),
                                oauthPresenter: FakeOAuthPresenter())
        XCTAssertThrowsError(try model.eventRenameTarget(for: "x")) {
            XCTAssertEqual($0 as? EventRenameRefusal, .noLibraryOpen)
        }
    }

    func testALocalLibraryRenamesTheFolderAboveEachAthlete() throws {
        for path in ["2026/2026-02-14_Hochybrig/Anna/a.mov", "2026/2026-02-14_Hochybrig/Bo/b.mov"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: url)
        }
        let model = ViewerModel(input: FakeInputSource(), folderPicker: FakeFolderPicker(),
                                oauthPresenter: FakeOAuthPresenter())
        model.openDirectory(root)
        XCTAssertEqual(model.eventRenameFolders(for: "2026-02-14_Hochybrig"), [["2026", "2026-02-14_Hochybrig"]])
    }

    /// Review Focus 5 and the spec's refresh rule.
    func testAChangePageWithAFolderMakesTheNextOpenReList() async throws {
        let writer = FakeDriveWriter()
        let model = try await openDrive([remoteFile("1", "a.mov", ["2026-02-14_Hochybrig", "Anna"])],
                                        convention: .eventThenAthlete, writer: writer)
        writer.listedFiles = [remoteFile("1", "a.mov", ["2026-02-14_Hoch-Ybrig", "Anna"])]
        writer.nextChanges = RemoteLibraryChanges(changed: [], removed: [], cursor: "c2", foldersChanged: true)
        try await withTemporaryIndexStore { try await model.reloadOpenLibrary() }
        XCTAssertEqual(model.events.compactMap(\.name), ["2026-02-14_Hoch-Ybrig"])
    }

    /// The spec: a clip open in the viewer is re-selected under its new name.
    func testTheOpenClipIsReselectedAfterTheRename() async throws {
        let writer = FakeDriveWriter()
        let model = try await openDrive([
            remoteFile("1", "a.mov", ["2026-02-14_Hochybrig", "Anna"]),
            remoteFile("2", "b.mov", ["2026-02-14_Hochybrig", "Anna"]),
        ], convention: .eventThenAthlete, writer: writer)
        _ = model.changeVideo(by: 1)
        XCTAssertEqual(model.currentVideo?.lastPathComponent, "b.mov")
        writer.listedFiles = [
            remoteFile("1", "a.mov", ["2026-02-14_Hoch-Ybrig", "Anna"]),
            remoteFile("2", "b.mov", ["2026-02-14_Hoch-Ybrig", "Anna"]),
        ]
        writer.nextChanges = RemoteLibraryChanges(changed: [], removed: [], cursor: "c2", foldersChanged: true)
        try await withTemporaryIndexStore { try await model.reloadOpenLibrary() }
        XCTAssertEqual(model.currentVideo?.lastPathComponent, "b.mov")
        XCTAssertEqual(model.currentClipIdentity, .remote(provider: FakeDriveWriter.identifier, fileID: "2"))
    }
}
```
(`eventRenameFolders(for:)` is internal so tests can read the collected paths. `FakeDriveWriter.nextChanges` is added in Step 3. `withTemporaryIndexStore`, `remoteFile`, `FakeInputSource`, `FakeFolderPicker`, `FakeOAuthPresenter`, `FakeClipDownloader` already exist in the test target.)

- [ ] **Step 2: Run to verify they fail**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SkiVideoCoreTests.EventRenameTargetTests`
Expected: build FAIL — `value of type 'ViewerModel' has no member 'eventRenameTarget'`.

- [ ] **Step 3: Let the fake Drive report changes.** In `FakeDriveWriter`, conform to `IncrementallyEnumerable` if it does not already, with:

```swift
    var nextChanges: RemoteLibraryChanges?
    func startCursor(forRoot rootID: String) async throws -> String { "c1" }
    func changes(since cursor: String, forRoot rootID: String) async throws -> RemoteLibraryChanges {
        nextChanges ?? RemoteLibraryChanges(changed: [], removed: [], cursor: cursor)
    }
```

- [ ] **Step 4: Add `foldersChanged`.** In `RemoteLibraryChanges` add `public let foldersChanged: Bool` and extend the init to `init(changed:removed:cursor:foldersChanged: Bool = false)`. In `GoogleDriveProvider.changes`, pass `foldersChanged: !folders.isEmpty` where it builds the result (the `folders` dictionary already holds every changed folder record in the drained pages), with this comment above it:

```swift
            // A changed folder's descendants are not in this page — their
            // stored paths still carry the old name. The caller re-lists.
```

- [ ] **Step 5: Re-list on a folder change.** In `ViewerModel.openRemoteLibrary`, replace the `if let stored = index, let cursor …` branch so a folder change falls through to the sweep:

```swift
        var index = RemoteLibraryIndex.load(forRoot: root.id)
        if let stored = index,
           let cursor = stored.cursor,
           let incremental = provider as? IncrementallyEnumerable {
            let changes = try await incremental.changes(since: cursor, forRoot: root.id)
            // A renamed or moved folder leaves every clip under it with a
            // stale stored path, and the change page does not list them.
            // Re-list instead — rare, because folders rarely change.
            index = changes.foldersChanged ? nil : stored.applying(changes)
            if changes.foldersChanged, stored.conventionWasChosen, convention == nil {
                keptConvention = stored.convention
            }
        }
        if index == nil {
```
Declare `var keptConvention: FolderConvention?` just above, change the existing `} else if index == nil {` to the `if index == nil {` shown, and after the sweep block use the kept choice: replace `if let convention {` with `if let convention = convention ?? keptConvention {`. This keeps an operator's explicit layout pick across the re-list (Review Focus 5).

- [ ] **Step 6: Add the rename entry points** to `ViewerModel.swift` (near `uploadTarget()`):

```swift
    /// Every folder of the event the sidebar shows as `eventName`, as names
    /// from the library root. Case-insensitive, because the sidebar groups
    /// case variants into one event and the rename must move all of them.
    func eventRenameFolders(for eventName: String) -> [[String]] {
        var paths = Set<[String]>()
        if let remoteIndex {
            for file in remoteIndex.files where file.path.count >= 2 {
                let eventIndex = remoteIndex.convention == .eventThenAthlete
                    ? file.path.count - 2 : file.path.count - 1
                if file.path[eventIndex].caseInsensitiveCompare(eventName) == .orderedSame {
                    paths.insert(Array(file.path[...eventIndex]))
                }
            }
        } else if let directory {
            let rootComponents = directory.standardizedFileURL.pathComponents
            for group in athletes {
                for video in group.videos {
                    let eventFolder = video.standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
                    guard eventFolder.lastPathComponent.caseInsensitiveCompare(eventName) == .orderedSame else { continue }
                    paths.insert(Array(eventFolder.pathComponents.dropFirst(rootComponents.count)))
                }
            }
        }
        return paths.sorted { $0.joined(separator: "/") < $1.joined(separator: "/") }
    }

    /// The rename for one sidebar event, or why there is none.
    public func eventRenameTarget(for eventName: String) throws -> EventRenameModel {
        let paths = eventRenameFolders(for: eventName)
        if let library = openLibrary, case let .drive(rootID) = library.kind {
            guard let writer = remoteProvider as? ItemUpdatable else {
                throw EventRenameRefusal.cannotWrite(libraryName: library.name)
            }
            return EventRenameModel(oldName: eventName, eventFolders: paths,
                                    folders: DriveEventFolders(writer: writer, rootID: rootID, presenter: oauthPresenter))
        }
        guard let directory else { throw EventRenameRefusal.noLibraryOpen }
        return EventRenameModel(oldName: eventName, eventFolders: paths, folders: LocalEventFolders(root: directory))
    }

    /// Clips and athletes the sidebar shows under `eventName`, for "Merge?".
    public func eventClipCount(named eventName: String) -> EventClipCount {
        let groups = athletes.filter { $0.event?.caseInsensitiveCompare(eventName) == .orderedSame }
        return EventClipCount(clips: groups.reduce(0) { $0 + $1.videos.count },
                              athletes: Set(groups.map(\.name)).count)
    }

    /// Opens the open library again — a Drive library through its change
    /// feed (which re-lists after a folder change), a local one by rescanning
    /// — and re-selects the clip that was open, wherever it now lives.
    ///
    /// A Drive clip is found again by file id, which a rename keeps. A local
    /// clip has no stable id, so it is found by athlete and file name; when
    /// two events hold the same pair, the first in sidebar order wins.
    public func reloadOpenLibrary() async throws {
        let previous = currentVideo
        let previousID = previous.map(identity(of:))
        let previousAthlete = athletes.first { $0.id == selectedAthleteID }?.name
        if let library = openLibrary, case let .drive(rootID) = library.kind,
           let remoteProvider, let clipCache {
            try await openRemoteLibrary(provider: remoteProvider,
                                        root: RemoteFolder(id: rootID, name: library.name), cache: clipCache)
        } else if let directory {
            openDirectory(directory)
        }
        guard let previous else { return }
        for group in athletes {
            let match = group.videos.first { video in
                if case .remote = previousID { return identity(of: video) == previousID }
                return group.name == previousAthlete && video.lastPathComponent == previous.lastPathComponent
            }
            if let match, let index = group.videos.firstIndex(of: match) {
                // `selectAthlete` starts at the first clip; step to the match.
                selectAthlete(group.id)
                if index > 0 { _ = changeVideo(by: index) }
                return
            }
        }
    }
```
And at file scope in `EventRenameModel.swift`:

```swift
public enum EventRenameRefusal: Error, Equatable, LocalizedError {
    case noLibraryOpen
    case cannotWrite(libraryName: String)

    public var errorDescription: String? {
        switch self {
        case .noLibraryOpen: return "Open a library first."
        case let .cannotWrite(name): return "\(name) cannot be changed from this app."
        }
    }
}
```

- [ ] **Step 7: Run to verify they pass, and that nothing else moved**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SkiVideoCoreTests`
Expected: PASS, including the existing `RemoteLibrary*`, `GoogleDriveProvider*` and `UploadBatchModel*` tests.

- [ ] **Step 8: Commit**

```bash
git add Sources/SkiVideoCore/RemoteLibraryProvider.swift Sources/SkiVideoCore/GoogleDriveProvider.swift Sources/SkiVideoCore/ViewerModel.swift Sources/SkiVideoCore/EventRenameModel.swift Tests/SkiVideoCoreTests/EventRenameTargetTests.swift Tests/SkiVideoCoreTests/FakeDriveWriter.swift
git commit -m "Offer the open library's events for renaming, and re-list after a folder change"
```

---

### Task 6: The sheet, the merge question, and Refresh

**Files:**
- Create: `Sources/SkiVideoViewer/Shared/RenameEventSheet.swift`
- Modify: `Sources/SkiVideoViewer/Shared/ContentView.swift` (event header `Button` gains a `.contextMenu`; toolbar gains Refresh)
- Modify: `Sources/SkiVideoCore/SecondaryScreens.swift`, `Sources/SkiVideoViewer/macOS/MacSecondaryScreenPresenter.swift`, `Sources/SkiVideoViewer/macOS/ComparisonWindowController.swift`, `Sources/SkiVideoViewer/macOS/SortingWindowController.swift`, `Sources/SkiVideoViewer/iOS/IOSSecondaryScreenPresenter.swift` (`hasOpenWindow`, Step 4)
- Test: build both apps; the behaviour is proven by Task 7's UI test

**Interfaces:**
- Consumes: `ViewerModel.eventRenameTarget(for:)`, `eventClipCount(named:)`, `reloadOpenLibrary()` (Task 5); `EventRenameModel` (Task 4); `SortingLibrary.eventFolder(date:title:)`.
- Produces: `RenameEventSheet(viewerModel: ViewerModel, eventName: String)`; accessibility identifiers `rename.date`, `rename.title`, `rename.submit`, `rename.merge`, `rename.otherName`, `rename.summary`, `rename.stopReason`, `library.refresh`.

- [ ] **Step 1: Create** `Sources/SkiVideoViewer/Shared/RenameEventSheet.swift`:

```swift
import SkiVideoCore
import SwiftUI

/// Rename one event across every athlete. The date and title are edited
/// apart and joined by `SortingLibrary.eventFolder`, so a renamed event is
/// spelled exactly as a freshly sorted one.
struct RenameEventSheet: View {
    @ObservedObject var viewerModel: ViewerModel
    let eventName: String
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var title = ""
    @State private var rename: EventRenameModel?
    @State private var refusal: String?
    @State private var mergeInto: (name: String, from: EventClipCount, into: EventClipCount)?
    @State private var finished = false

    private var newName: String? { try? SortingLibrary.eventFolder(date: date, title: title) }

    var body: some View {
        NavigationStack {
            Form {
                if let refusal {
                    Text(refusal).foregroundStyle(.red)
                } else if let rename {
                    content(rename)
                }
            }
            .navigationTitle("Rename Event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(finished ? "Done" : "Cancel") { dismiss() }
                        .disabled(rename?.isRunning == true)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !finished {
                        Button("Rename") { Task { await submit() } }
                            .disabled(newName == nil || newName == eventName || rename?.isRunning != false)
                            .accessibilityIdentifier("rename.submit")
                    }
                }
            }
            .confirmationDialog(
                mergeInto.map { "“\($0.name)” already exists" } ?? "",
                isPresented: Binding(get: { mergeInto != nil }, set: { if !$0 { mergeInto = nil } }),
                titleVisibility: .visible,
                presenting: mergeInto
            ) { merge in
                Button("Merge") { Task { await start(merge.name) } }
                    .accessibilityIdentifier("rename.merge")
                Button("Choose Another Name") { mergeInto = nil }
                    .accessibilityIdentifier("rename.otherName")
                Button("Cancel", role: .cancel) { dismiss() }
            } message: { merge in
                Text("It has \(merge.into.clips) clips for \(merge.into.athletes) athletes. "
                     + "Merge “\(eventName)” (\(merge.from.clips) clips, \(merge.from.athletes) athletes) into it?")
            }
        }
        .onAppear(perform: prepare)
    }

    @ViewBuilder
    private func content(_ rename: EventRenameModel) -> some View {
        Section {
            DatePicker("Date", selection: $date, displayedComponents: .date)
                .accessibilityIdentifier("rename.date")
            TextField("Title", text: $title)
                .accessibilityIdentifier("rename.title")
            if let newName { LabeledContent("New name", value: newName) }
        }
        if rename.isRunning {
            ProgressView(value: Double(rename.done), total: Double(max(rename.total, 1))) {
                Text("Renaming \(rename.done) of \(rename.total)…")
            }
        }
        if let stop = rename.stopReason {
            Text(stop).foregroundStyle(.red).accessibilityIdentifier("rename.stopReason")
        }
        if finished, rename.stopReason == nil {
            Text(summary(rename)).accessibilityIdentifier("rename.summary")
        }
    }

    private func summary(_ rename: EventRenameModel) -> String {
        guard !rename.leftInPlace.isEmpty else { return "Renamed to \(newName ?? "")." }
        let names = rename.leftInPlace.compactMap(\.last).joined(separator: ", ")
        return "Done. \(rename.leftInPlace.count) file(s) stayed in “\(eventName)” because the same "
            + "name is already in the target: \(names)."
    }

    /// Pre-fills date and title from the current name `yyyy-MM-dd_Title`.
    private func prepare() {
        do { rename = try viewerModel.eventRenameTarget(for: eventName) }
        catch { refusal = error.localizedDescription }
        let parts = eventName.split(separator: "_", maxSplits: 1).map(String.init)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        if let first = parts.first, let parsed = formatter.date(from: first) {
            date = parsed
            title = parts.count > 1 ? parts[1].replacingOccurrences(of: "-", with: " ") : ""
        } else {
            title = eventName
        }
    }

    private func submit() async {
        guard let rename, let newName else { return }
        do {
            if try await rename.targetExists(newName: newName) {
                mergeInto = (newName, viewerModel.eventClipCount(named: eventName),
                             viewerModel.eventClipCount(named: newName))
                return
            }
        } catch {
            refusal = error.localizedDescription
            return
        }
        await start(newName)
    }

    private func start(_ name: String) async {
        mergeInto = nil
        guard let rename else { return }
        let ok = await rename.run(newName: name)
        // Refreshed either way: after a stop the sidebar must show honestly
        // which athletes are under which name.
        try? await viewerModel.reloadOpenLibrary()
        finished = ok
    }
}
```

- [ ] **Step 2: Wire it into the sidebar.** In `ContentView.swift`, add state `@State private var renamingEvent: String?`. On the event header `Button` (the one toggling `collapsedSections`), append after `.padding(.bottom, 2)`:

```swift
                            .contextMenu {
                                Button("Rename Event…") { renamingEvent = name }
                            }
```
and on the `List`:

```swift
            .sheet(item: Binding(
                get: { renamingEvent.map(IdentifiedName.init) },
                set: { renamingEvent = $0?.id }
            )) { event in
                RenameEventSheet(viewerModel: model, eventName: event.id)
            }
```
with, at file scope in `RenameEventSheet.swift`:

```swift
struct IdentifiedName: Identifiable { let id: String }
```

- [ ] **Step 3: Add Refresh.** In the same `ContentView` toolbar that holds the existing library controls, add:

```swift
                Button {
                    Task { try? await model.reloadOpenLibrary() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.openLibrary == nil)
                .accessibilityIdentifier("library.refresh")
```

- [ ] **Step 4: Refuse while comparison or sorting is open.** Read at the moment the menu item is chosen — not in `body`: `ContentView` does not observe the presenter (see the comment on `SecondaryScreenPresenter`), so a `.disabled` computed there would never update.
  - `Sources/SkiVideoCore/SecondaryScreens.swift`, in the protocol: 
    ```swift
        /// Read when an action needs it, never while building `body` — the
        /// presenter is not observed. True while a comparison or sorting
        /// window holds clip paths that a library change would invalidate.
        var hasOpenWindow: Bool { get }
    ```
  - `Sources/SkiVideoViewer/macOS/ComparisonWindowController.swift` and `SortingWindowController.swift`: add `var isOpen: Bool { window?.isVisible == true }` (both already keep `window`).
  - `MacSecondaryScreenPresenter`: `var hasOpenWindow: Bool { comparisonWindow.isOpen || sortingWindow.isOpen }`.
  - `IOSSecondaryScreenPresenter`: `var hasOpenWindow: Bool { false }` with the comment `// Both screens are full-screen covers on iOS: the sidebar cannot be reached while either is up.`
  - Any test fake conforming to `SecondaryScreenPresenter` (search `SecondaryScreenPresenter` under `Tests/`): add `var hasOpenWindow = false`.
  - In `ContentView`, add `@State private var renameRefusal: String?`; the menu action becomes:
    ```swift
                                Button("Rename Event…") {
                                    if secondaryScreens.hasOpenWindow {
                                        renameRefusal = "Close the comparison and sorting windows first."
                                    } else {
                                        renamingEvent = name
                                    }
                                }
    ```
    and on the `List`: `.alert(renameRefusal ?? "", isPresented: Binding(get: { renameRefusal != nil }, set: { if !$0 { renameRefusal = nil } })) { Button("OK", role: .cancel) {} }`.

- [ ] **Step 5: Build both apps**

Run: `./build_app.sh` and, for iOS, `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme SkiVideoViewer-iPad -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
Expected: both succeed with no new warnings in the touched files.

- [ ] **Step 6: Commit**

```bash
git add Sources/SkiVideoViewer/Shared/RenameEventSheet.swift Sources/SkiVideoViewer/Shared/ContentView.swift
git commit -m "Rename an event from the sidebar, asking before a merge"
```

---

### Task 7: Proof

**Files:**
- Modify: `Sources/SkiVideoViewer/iOS/UITestPhotosToDriveSeam.swift` (`FakeClubDrive` conforms to `ItemUpdatable`; seed a second event)
- Create: `Tests/SkiVideoViewerUITests/RenameEventUITests.swift`
- Run: xcodegen, the UI test, then the full suites

**Interfaces:**
- Consumes: Task 6's accessibility identifiers; the seam launch argument `-SkiUITestPhotosToDrive`.

- [ ] **Step 1: Give the seam's fake Drive the update operations.** In `FakeClubDrive`, change the declaration to `ItemUpdatable` and add — mirroring the locked-helper style already in that class:

```swift
    func listChildren(of folderID: String) async throws -> [RemoteChild] {
        locked {
            folders.filter { $0.value.parent == folderID }.map { RemoteChild(id: $0.key, name: $0.value.name, isFolder: true) }
                + files.filter { $0.parent == folderID }.map { RemoteChild(id: $0.id, name: $0.name, isFolder: false) }
        }
    }
    func rename(itemID: String, to newName: String) async throws {
        locked { if let f = folders[itemID] { folders[itemID] = (newName, f.parent) } }
    }
    func move(itemID: String, from oldParentID: String, to newParentID: String) async throws {
        locked {
            if let f = folders[itemID] { folders[itemID] = (f.name, newParentID) }
            if let i = files.firstIndex(where: { $0.id == itemID }) { files[i].parent = newParentID }
        }
    }
    func trash(itemID: String) async throws { locked { folders.removeValue(forKey: itemID) } }
```
Make `enumerate` yield every file in `files`, each with its path derived from the live folder tree (`pathLocked(of:)`) instead of the fixed `seedPath`, so a rename shows after `reloadOpenLibrary()`. In `init`, seed a second event beside the first, so the merge question can be reached:

```swift
    /// A second event on the same date, so renaming the first to "Spring
    /// Camp" collides and asks "Merge?". Its athlete is distinct so
    /// `PhotosToDriveUITests`' `sidebar.athlete.Seed Athlete` stays unique.
    static let secondPath = ["2026-01-10_Spring-Camp", "Other Athlete"]
```
and in `init`, after the existing seed: `var second = rootID; for name in Self.secondPath { second = createFolderLocked(named: name, parent: second) }; files.append((id: mintLocked("file"), name: "seed2.mp4", parent: second))`. Run `PhotosToDriveUITests` once after this change to confirm it is unaffected.

- [ ] **Step 2: Write the UI test** `Tests/SkiVideoViewerUITests/RenameEventUITests.swift`:

```swift
import XCTest

/// Rename an event against the seam's in-memory Drive, then hit the merge
/// question and back out of it. Every wait is bounded.
final class RenameEventUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testRenamingAnEventMovesItInTheSidebar() throws {
        let app = launch()
        openRename(of: "2026-01-10_Seed Camp", in: app)
        retitle("Autumn Camp", in: app)
        app.buttons["rename.submit"].tap()

        XCTAssertTrue(app.staticTexts["rename.summary"].waitForExistence(timeout: 30))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["2026-01-10_Autumn-Camp"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["2026-01-10_Seed Camp"].exists)
    }

    /// The spec: a name that already exists asks first, and backing out
    /// changes nothing and keeps what was typed.
    func testAnExistingNameAsksBeforeMerging() throws {
        let app = launch()
        openRename(of: "2026-01-10_Seed Camp", in: app)
        retitle("Spring Camp", in: app)
        app.buttons["rename.submit"].tap()

        let otherName = app.buttons["rename.otherName"]
        XCTAssertTrue(otherName.waitForExistence(timeout: 30), "an existing name must ask before merging")
        XCTAssertTrue(app.buttons["rename.merge"].exists)
        otherName.tap()

        let title = app.textFields["rename.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.value as? String, "Spring Camp", "the typed name is kept")
        XCTAssertTrue(app.buttons["2026-01-10_Seed Camp"].exists, "nothing moved")
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-SkiUITestPhotosToDrive"]
        app.launch()
        return app
    }

    private func openRename(of event: String, in app: XCUIApplication) {
        let header = app.buttons[event]
        XCTAssertTrue(header.waitForExistence(timeout: 60), "the fake Drive must open")
        header.press(forDuration: 1.0)
        let item = app.buttons["Rename Event…"]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.tap()
    }

    /// Clears the title by deleting what is there — no reliance on an edit
    /// menu — and types the new one.
    private func retitle(_ text: String, in app: XCUIApplication) {
        let title = app.textFields["rename.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        let current = title.value as? String ?? ""
        title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }
}
```

- [ ] **Step 3: Regenerate the project and run the UI test**

Run: `xcodegen generate` then
`env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme SkiVideoViewer-iPad -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:SkiVideoViewer-iPadUITests/RenameEventUITests test`
(run it in the background; it can take minutes). Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Full suites before sign-off**

Run: `SKI_SLOW_TESTS=1 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` (opens windows — warn whoever is at the keyboard). Check `uptime` first; a red test under a load average above ~20 is starvation until proven otherwise.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SkiVideoViewer/iOS/UITestPhotosToDriveSeam.swift Tests/SkiVideoViewerUITests/RenameEventUITests.swift SkiVideoViewer.xcodeproj
git commit -m "Prove an event rename end to end against the fake Drive"
```

- [ ] **Step 6: Hand the real-data checks to the user** (not automatable):
  - rename an event in the real club Drive (both layouts if available) and check Drive's web UI;
  - merge two spellings of one day, and see the collision summary;
  - rename a folder in Drive's web UI, press Refresh, and confirm the app shows the new name — the live check for the spec's unverified change-log assumption.
