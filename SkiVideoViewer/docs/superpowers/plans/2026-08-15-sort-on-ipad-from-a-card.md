# Sort on iPad from a Card — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a coach can run the existing sort-and-resize workflow on an iPad with
the camera's SD card as the source, without the card ever being written to.

**Architecture:** `SortingModel` currently ends a session by moving each
original into `organized/<event>/<athlete>/` and resizing into
`organized_resize/…`, both derived from the *source* folder. That end-stage
becomes a `ClipPublisher` seam with two conformers: `LocalFolderPublisher`
(today's behaviour, extracted verbatim) and `ReadOnlySourcePublisher` (leaves
the source untouched and writes the resize elsewhere). `SortingModel` then only
knows "prepare targets for this clip".

**Tech Stack:** Swift 6.1 / SwiftPM (`swiftLanguageModes: [.v5]`), AVFoundation,
SwiftUI, XCTest, XcodeGen.

## Global Constraints

- **The SD card is read-only.** No move, no metadata write, no directory
  creation on a read-only source. This is the whole point of the plan.
- **Plan 1 makes no Drive changes and no OAuth scope changes.** Nothing in this
  plan may touch `GoogleOAuth`, `GoogleDriveProvider`, or the scope string.
- **`LocalFolderPublisher` must reproduce today's Mac behaviour exactly** —
  same paths, same filenames, same error on collision. It is pinned by tests
  before it is extracted.
- **Test command is not plain `swift test`.** `xcode-select -p` points at
  CommandLineTools, which has no XCTest. Prefix every invocation:
  `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter …`
- **Do not run the full suite** — it is ~186s. Run `swift build --build-tests`
  plus named filters, in the foreground.
- **Before committing, also run `xcodegen generate` and build both schemes.**
  A test-target dependency SwiftPM allowed and `xcodebuild` rejected went
  unnoticed for four tasks because every check ran through SwiftPM:
  ```
  xcodebuild -project SkiVideoViewer.xcodeproj -scheme SkiVideoViewer -destination 'platform=macOS' build
  xcodebuild -project SkiVideoViewer.xcodeproj -scheme SkiVideoViewer-iPad -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
  ```
- **`ls ~/Library/Application\ Support/SkiVideoViewer` must find nothing new
  after a test run**, and `ls ~/Library/Preferences | grep -i test` must find
  nothing. Tests have twice polluted the developer's real home directory here.
- **`Sources/SkiVideoCore` may not contain** `import AppKit`, `import UIKit`,
  `import SwiftUI`, or `Process(`. `CorePurityTests` enforces this.
- New tests go in `Tests/SkiVideoCoreTests/`.
- **Every test must name, in a doc comment, the change that would make it
  fail.** A test that cannot fail is worse than no test — this project has
  shipped an always-green plist assertion and an `isDecodable` check that could
  never fire.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `Sources/SkiVideoCore/ClipPublisher.swift` (create) | The seam: `PublishTargets`, `ClipPublisher`, `LocalFolderPublisher`, `ReadOnlySourcePublisher` |
| `Sources/SkiVideoCore/SortingModel.swift` (modify) | Delegates target computation to a publisher; gates the source-metadata write |
| `Sources/SkiVideoViewer/iOS/IOSSecondaryScreenPresenter.swift` (modify) | Report `canPresentSorting == true` and present the sheet |
| `Tests/SkiVideoCoreTests/ClipPublisherTests.swift` (create) | Both conformers, including the read-only guarantee |
| `Tests/SkiVideoCoreTests/SortingModelPublisherTests.swift` (create) | `SortingModel` produces today's layout through the seam |

---

### Task 1: Pin today's output layout before touching it

The regression net. `LocalFolderPublisher` does not exist yet; this task
asserts what `SortingModel` produces **now**, so the extraction in Task 3
cannot silently change it.

**Files:**
- Test: `Tests/SkiVideoCoreTests/SortingModelPublisherTests.swift` (create)

**Interfaces:**
- Consumes: `SortingModel(mediaPipeline:input:folderPicker:)`, `SortingLibrary.eventFolder(date:title:)`, `SortingLibrary.athleteFolderName(_:)`
- Produces: nothing — tests only

- [ ] **Step 1: Write the characterisation test**

```swift
import XCTest
@testable import SkiVideoCore

/// Pins the on-disk layout a sorting session produces, **before** the output
/// stage is extracted behind `ClipPublisher` in Task 3.
///
/// Fails if the extraction changes any path component, the filename, or the
/// collision error — which is exactly what a refactor of working Mac
/// behaviour is most likely to do by accident.
final class SortingModelPublisherTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sorting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    /// The layout: `organized/<event>/<athlete>/<original filename>` for the
    /// original, and the same tail under `organized_resize/`.
    func testASortedClipLandsInTheEventAthleteLayout() async throws {
        let source = try makeSource(named: "C0001.MP4")
        let model = await makeModel(source: source, event: "Brunni")

        await MainActor.run {
            model.athleteQuery = "Ada Example"
            model.tagCurrentVideo()
        }

        let event = try SortingLibrary.eventFolder(date: await model.eventDate, title: "Brunni")
        let athlete = try SortingLibrary.athleteFolderName("Ada Example")
        let organized = root
            .appendingPathComponent("organized/\(event)/\(athlete)/C0001.MP4")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: organized.path),
            "expected the original at \(organized.path); the layout is what this test pins"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: source.path),
            "the original is moved, not copied — that is today's behaviour"
        )
    }

    private func makeSource(named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 0, count: 16).write(to: url)
        return url
    }

    @MainActor
    private func makeModel(source: URL, event: String) -> SortingModel {
        let model = SortingModel(mediaPipeline: NoOpMediaPipeline())
        model.sourcePath = root.path
        model.eventTitle = event
        model.athleteNames = ["Ada Example"]
        model.beginSorting()
        return model
    }
}

/// Does nothing, so these tests measure layout rather than AVFoundation.
private struct NoOpMediaPipeline: MediaPipeline {
    func writeMetadata(athlete: String, to url: URL) async throws {}
    func resize(source: URL, destination: URL, athlete: String) async throws {}
}
```

- [ ] **Step 2: Run it and read the failures**

Run:
```
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SortingModelPublisherTests
```

Expected: it may fail on API details — `SortingModel`'s initialiser
parameters, `athleteNames` being `private(set)`, or `beginSorting` needing
more setup. **Adjust the test to match the real API; do not change
`SortingModel` in this task.** The point is a passing characterisation of
current behaviour.

- [ ] **Step 3: Make it pass against unchanged production code**

Read `Sources/SkiVideoCore/SortingModel.swift` and adapt the test's setup. If
`athleteNames` cannot be set from a test, use `addNewAthleteAndTag()` instead
of `tagCurrentVideo()`, and assert the same paths.

- [ ] **Step 4: Confirm it passes**

Run the filter above. Expected: PASS, with no changes to any file under
`Sources/`.

- [ ] **Step 5: Prove it can fail**

Temporarily change `"organized"` to `"organized2"` in
`SortingModel.beginSorting`, re-run, confirm the test fails naming the path,
then revert.

- [ ] **Step 6: Commit**

```bash
git add Tests/SkiVideoCoreTests/SortingModelPublisherTests.swift
git commit -m "Pin the sorting layout before extracting it"
```

---

### Task 2: The `ClipPublisher` seam and its two conformers

**Files:**
- Create: `Sources/SkiVideoCore/ClipPublisher.swift`
- Test: `Tests/SkiVideoCoreTests/ClipPublisherTests.swift` (create)

**Interfaces:**
- Consumes: `SortingLibrary.athleteFolderName(_:)`, `SortingError.outputExists(_:)`
- Produces:
  - `public struct PublishTargets { public let resizeSource: URL; public let resizeDestination: URL }`
  - `public protocol ClipPublisher: Sendable { var maySkipSourceMetadata: Bool { get }; func prepare(source: URL, athlete: String, event: String) throws -> PublishTargets }`
  - `public struct LocalFolderPublisher: ClipPublisher { public init(organizedRoot: URL, resizedRoot: URL) }`
  - `public struct ReadOnlySourcePublisher: ClipPublisher { public init(resizedRoot: URL) }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import SkiVideoCore

final class ClipPublisherTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("publisher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    /// Fails if the local publisher stops moving the original, which is how a
    /// Mac session archives full-quality footage.
    func testTheLocalPublisherMovesTheOriginalIntoTheEventAthleteLayout() throws {
        let source = try makeFile("C0001.MP4")
        let publisher = LocalFolderPublisher(
            organizedRoot: root.appendingPathComponent("organized"),
            resizedRoot: root.appendingPathComponent("organized_resize")
        )

        let targets = try publisher.prepare(source: source, athlete: "Ada", event: "2026-01-14_Brunni")

        XCTAssertEqual(
            targets.resizeSource.path,
            root.appendingPathComponent("organized/2026-01-14_Brunni/Ada/C0001.MP4").path
        )
        XCTAssertEqual(
            targets.resizeDestination.path,
            root.appendingPathComponent("organized_resize/2026-01-14_Brunni/Ada/C0001.MP4").path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: targets.resizeSource.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: source.path),
            "the original is moved, not copied"
        )
    }

    /// **The reason this plan exists.** Fails if the read-only publisher moves,
    /// copies, or creates anything at the source — which on an SD card would
    /// mean rearranging the only archive of a training session.
    func testTheReadOnlyPublisherLeavesTheSourceUntouched() throws {
        let card = root.appendingPathComponent("DCIM")
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        let source = card.appendingPathComponent("C0001.MP4")
        try Data(repeating: 0, count: 16).write(to: source)
        let before = try FileManager.default.contentsOfDirectory(atPath: card.path)

        let publisher = ReadOnlySourcePublisher(resizedRoot: root.appendingPathComponent("out"))
        let targets = try publisher.prepare(source: source, athlete: "Ada", event: "2026-01-14_Brunni")

        XCTAssertEqual(targets.resizeSource.path, source.path, "the resize reads the card directly")
        XCTAssertEqual(
            targets.resizeDestination.path,
            root.appendingPathComponent("out/2026-01-14_Brunni/Ada/C0001.MP4").path
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: card.path), before,
            "nothing may be added to, removed from, or moved within the source directory"
        )
    }

    /// Fails if the metadata gate is dropped: `SortingModel` writes an athlete
    /// tag into the *original* before resizing, and on a card that is a write.
    func testOnlyTheLocalPublisherPermitsWritingToTheSource() {
        XCTAssertFalse(
            LocalFolderPublisher(
                organizedRoot: root.appendingPathComponent("organized"),
                resizedRoot: root.appendingPathComponent("organized_resize")
            ).maySkipSourceMetadata
        )
        XCTAssertTrue(ReadOnlySourcePublisher(resizedRoot: root).maySkipSourceMetadata)
    }

    /// Today's collision behaviour, preserved. Fails if a second session
    /// silently overwrites the first athlete's clip of the same name.
    func testAnExistingOutputIsRefused() throws {
        let source = try makeFile("C0001.MP4")
        let publisher = LocalFolderPublisher(
            organizedRoot: root.appendingPathComponent("organized"),
            resizedRoot: root.appendingPathComponent("organized_resize")
        )
        _ = try publisher.prepare(source: source, athlete: "Ada", event: "E")

        let second = try makeFile("C0001.MP4")
        XCTAssertThrowsError(try publisher.prepare(source: second, athlete: "Ada", event: "E"))
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 0, count: 16).write(to: url)
        return url
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run:
```
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ClipPublisherTests
```
Expected: FAIL — `cannot find 'LocalFolderPublisher' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Where a tagged clip's bytes come from and go to.
public struct PublishTargets: Sendable {
    /// What the resizer reads. For a local session this is the original's new
    /// home after the move; for a read-only source it is the source itself.
    public let resizeSource: URL
    public let resizeDestination: URL

    public init(resizeSource: URL, resizeDestination: URL) {
        self.resizeSource = resizeSource
        self.resizeDestination = resizeDestination
    }
}

/// The end-stage of a sorting session: what happens to a clip once a coach has
/// named the athlete in it.
///
/// It exists because that stage is the only part of sorting that differs
/// between a Mac pointed at a working folder and an iPad pointed at the SD
/// card still in the camera bag. Everything before it — the athlete search,
/// playback, the resize queue — is identical, and duplicating it for a second
/// platform would have been the alternative.
public protocol ClipPublisher: Sendable {
    /// True when the original must not be written to.
    ///
    /// `SortingModel` writes an athlete tag into the original before resizing
    /// it. That is a *write*, and on an SD card the card is the only archive of
    /// a training session, so it is skipped rather than attempted-and-failed:
    /// a failure there would abort a clip that is otherwise perfectly
    /// processable.
    var maySkipSourceMetadata: Bool { get }

    /// Prepares the filesystem for one clip and reports where the resize reads
    /// from and writes to. Throws rather than overwriting anything.
    func prepare(source: URL, athlete: String, event: String) throws -> PublishTargets
}

/// Today's Mac behaviour: the original is moved into
/// `<organizedRoot>/<event>/<athlete>/`, and the resize is written to the same
/// tail under `<resizedRoot>`.
public struct LocalFolderPublisher: ClipPublisher {
    public let maySkipSourceMetadata = false

    private let organizedRoot: URL
    private let resizedRoot: URL

    public init(organizedRoot: URL, resizedRoot: URL) {
        self.organizedRoot = organizedRoot
        self.resizedRoot = resizedRoot
    }

    public func prepare(source: URL, athlete: String, event: String) throws -> PublishTargets {
        let tail = "\(event)/\(athlete)/\(source.lastPathComponent)"
        let organized = organizedRoot.appendingPathComponent(tail)
        let resized = resizedRoot.appendingPathComponent(tail)

        // Both are checked before either is created, so a half-published clip
        // cannot be left behind by a collision on the second path.
        guard !FileManager.default.fileExists(atPath: organized.path),
              !FileManager.default.fileExists(atPath: resized.path) else {
            throw SortingError.outputExists(organized.path)
        }
        try FileManager.default.createDirectory(
            at: organized.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: source, to: organized)
        return PublishTargets(resizeSource: organized, resizeDestination: resized)
    }
}

/// For a source that must not be touched — an SD card still holding the only
/// copy of a session. The original stays exactly where it is and the resizer
/// reads it in place; only the resize is written, under `resizedRoot`.
public struct ReadOnlySourcePublisher: ClipPublisher {
    public let maySkipSourceMetadata = true

    private let resizedRoot: URL

    public init(resizedRoot: URL) {
        self.resizedRoot = resizedRoot
    }

    public func prepare(source: URL, athlete: String, event: String) throws -> PublishTargets {
        let resized = resizedRoot
            .appendingPathComponent("\(event)/\(athlete)/\(source.lastPathComponent)")
        guard !FileManager.default.fileExists(atPath: resized.path) else {
            throw SortingError.outputExists(resized.path)
        }
        try FileManager.default.createDirectory(
            at: resized.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        return PublishTargets(resizeSource: source, resizeDestination: resized)
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run the filter from Step 2. Expected: PASS, 4 tests.

- [ ] **Step 5: Prove the read-only test can fail**

Add `try FileManager.default.moveItem(at: source, to: resized)` to
`ReadOnlySourcePublisher.prepare`, re-run, and confirm
`testTheReadOnlyPublisherLeavesTheSourceUntouched` fails naming the directory
contents. Revert.

- [ ] **Step 6: Commit**

```bash
git add Sources/SkiVideoCore/ClipPublisher.swift Tests/SkiVideoCoreTests/ClipPublisherTests.swift
git commit -m "Add the ClipPublisher seam, with a read-only conformer"
```

---

### Task 3: Route `SortingModel` through the seam

**Files:**
- Modify: `Sources/SkiVideoCore/SortingModel.swift` (`beginSorting`, `tagCurrentVideo`, `enqueueResize`, and the `organizedDirectory` / `resizedDirectory` properties)

**Interfaces:**
- Consumes: `PublishTargets`, `ClipPublisher`, `LocalFolderPublisher` from Task 2
- Produces: `SortingModel.publisher` — a `ClipPublisher?` set by `beginSorting`, defaulting to `LocalFolderPublisher` so Mac behaviour is unchanged

- [ ] **Step 1: Replace the two directory properties with a publisher**

In `SortingModel`, delete `private var organizedDirectory: URL?` and
`private var resizedDirectory: URL?`, and add:

```swift
    /// The session's end-stage. Nil until `beginSorting` chooses one.
    ///
    /// Defaults to `LocalFolderPublisher` over directories derived from the
    /// source, which is exactly what this model did inline before the seam
    /// existed — so a Mac session behaves identically.
    private var publisher: ClipPublisher?
```

- [ ] **Step 2: Build the publisher in `beginSorting`**

Replace these two lines in `beginSorting`:

```swift
            organizedDirectory = source.appendingPathComponent("organized", isDirectory: true)
            resizedDirectory = source.appendingPathComponent("organized_resize", isDirectory: true)
```

with:

```swift
            publisher = LocalFolderPublisher(
                organizedRoot: source.appendingPathComponent("organized", isDirectory: true),
                resizedRoot: source.appendingPathComponent("organized_resize", isDirectory: true)
            )
```

- [ ] **Step 3: Use it in `tagCurrentVideo`**

Replace the body between `guard let video = currentVideo, …` and
`enqueueResize(…)` with:

```swift
        guard let video = currentVideo,
              let publisher,
              let athlete = resolvedAthlete else {
            status = "Keep typing until one athlete matches, or add a new athlete."
            return
        }
        do {
            let athlete = try SortingLibrary.athleteFolderName(athlete)
            let targets = try publisher.prepare(source: video, athlete: athlete, event: eventFolder)
            enqueueResize(
                source: targets.resizeSource,
                destination: targets.resizeDestination,
                athlete: athlete,
                skipSourceMetadata: publisher.maySkipSourceMetadata
            )
            athleteQuery = ""
            removeCurrentVideo()
        } catch {
            errorMessage = error.localizedDescription
        }
```

- [ ] **Step 4: Gate the metadata write in `enqueueResize`**

Change the signature to
`private func enqueueResize(source: URL, destination: URL, athlete: String, skipSourceMetadata: Bool)`
and guard the existing call:

```swift
                    if !skipSourceMetadata {
                        // Writes an athlete tag into the *original*. Skipped for
                        // a read-only source: on an SD card this is a write to
                        // the only archive of the session, and failing here
                        // would abort a clip that resizes perfectly well.
                        try await pipeline.writeMetadata(athlete: athlete, to: source)
                    }
```

Apply the same argument at the other `enqueueResize` call site in
`addNewAthleteAndTag`.

- [ ] **Step 5: Run the pinned layout test plus the publisher tests**

Run:
```
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "SortingModelPublisherTests|ClipPublisherTests|SortingModelTests|SortingLibraryTests"
```
Expected: PASS. Task 1's characterisation test passing unchanged is the whole
point of this task.

- [ ] **Step 6: Build both schemes**

```bash
xcodegen generate
xcodebuild -project SkiVideoViewer.xcodeproj -scheme SkiVideoViewer -destination 'platform=macOS' build
xcodebuild -project SkiVideoViewer.xcodeproj -scheme SkiVideoViewer-iPad -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
```
Expected: both `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
git add Sources/SkiVideoCore/SortingModel.swift
git commit -m "Route sorting's output stage through ClipPublisher"
```

---

### Task 4: Choose a read-only session, writing to app storage

**Files:**
- Modify: `Sources/SkiVideoCore/SortingModel.swift`
- Test: `Tests/SkiVideoCoreTests/SortingModelPublisherTests.swift` (extend)

**Interfaces:**
- Consumes: `ReadOnlySourcePublisher` from Task 2
- Produces: `SortingModel.keepsSourceIntact: Bool` (public, `@Published`), read by the sheet in Task 5, and `SortingModel.outputRoot: URL` — where a read-only session writes

- [ ] **Step 1: Write the failing test**

```swift
    /// A read-only session must write its resize somewhere that is not the
    /// card. Fails if `keepsSourceIntact` is ignored and the session still
    /// builds a `LocalFolderPublisher` over the source — the mistake that
    /// would put `organized/` on a coach's SD card.
    func testAReadOnlySessionWritesNothingToTheSource() async throws {
        let card = root.appendingPathComponent("DCIM")
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 16).write(to: card.appendingPathComponent("C0001.MP4"))
        let before = try FileManager.default.contentsOfDirectory(atPath: card.path)
        let output = root.appendingPathComponent("app-storage")

        let model = await MainActor.run { () -> SortingModel in
            let model = SortingModel(mediaPipeline: NoOpMediaPipeline())
            model.sourcePath = card.path
            model.eventTitle = "Brunni"
            model.keepsSourceIntact = true
            model.outputRoot = output
            model.beginSorting()
            return model
        }
        await MainActor.run {
            model.athleteQuery = "Ada Example"
            model.addNewAthleteAndTag()
        }

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: card.path), before,
            "a read-only session must leave the card exactly as it found it"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: output.path),
            "the resize target directory should have been created under the output root"
        )
    }
```

- [ ] **Step 2: Run to verify it fails**

Run:
```
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SortingModelPublisherTests
```
Expected: FAIL — `value of type 'SortingModel' has no member 'keepsSourceIntact'`.

- [ ] **Step 3: Add the two properties and branch `beginSorting`**

```swift
    /// True when the source must not be written to — an SD card still holding
    /// the only copy of a session. Set before `beginSorting`.
    @Published public var keepsSourceIntact = false

    /// Where a source-preserving session writes its resizes. Ignored when
    /// `keepsSourceIntact` is false, because that session writes beside the
    /// source the way it always has.
    @Published public var outputRoot: URL = SortingModel.defaultOutputRoot()

    /// The app's Documents directory, which on iPadOS is what
    /// `UIFileSharingEnabled` exposes under "On My iPad" in Files — so a
    /// coach can reach the results without this app's help.
    static func defaultOutputRoot() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sorted", isDirectory: true)
    }
```

and in `beginSorting`, replace the Task 3 assignment with:

```swift
            publisher = keepsSourceIntact
                ? ReadOnlySourcePublisher(resizedRoot: outputRoot)
                : LocalFolderPublisher(
                    organizedRoot: source.appendingPathComponent("organized", isDirectory: true),
                    resizedRoot: source.appendingPathComponent("organized_resize", isDirectory: true)
                )
```

- [ ] **Step 4: Run to verify it passes**

Run the filter from Step 2. Expected: PASS, including Task 1's original test.

- [ ] **Step 5: Prove it can fail**

Force `keepsSourceIntact` to be ignored (always build the local publisher),
re-run, confirm the new test fails on the card's directory contents. Revert.

- [ ] **Step 6: Check nothing reached the real home directory**

```bash
ls ~/Library/Application\ Support/SkiVideoViewer
ls ~/Documents/Sorted 2>/dev/null && echo "LEAK: tests wrote to the real Documents"
```
Expected: no `Sorted` directory. If one exists, the test is not passing
`outputRoot` and must be fixed before committing.

- [ ] **Step 7: Commit**

```bash
git add Sources/SkiVideoCore/SortingModel.swift Tests/SkiVideoCoreTests/SortingModelPublisherTests.swift
git commit -m "Let a session preserve its source and write elsewhere"
```

---

### Task 5: Turn sorting on for iPad

**Files:**
- Modify: `Sources/SkiVideoViewer/iOS/IOSSecondaryScreenPresenter.swift`

**Interfaces:**
- Consumes: `SortingModel.keepsSourceIntact` from Task 4
- Produces: `canPresentSorting == true` on iPadOS, so `ContentView`'s existing "Sort & Resize…" toolbar button appears

- [ ] **Step 1: Read what the presenter does for comparison**

`presentComparison` already works on iPad by presenting a full-screen cover.
Read `Sources/SkiVideoViewer/iOS/IOSSecondaryScreenPresenter.swift` in full and
mirror that mechanism for sorting — do not invent a second presentation style.

- [ ] **Step 2: Report the capability and present the sheet**

Change `var canPresentSorting: Bool { false }` to `true`, and implement
`presentSorting` the way `presentComparison` is implemented, hosting
`SortingSheet`. Update the type's doc comment: it currently explains that
sorting is unavailable "yet", which will be stale.

- [ ] **Step 3: Default an iPad session to preserving its source**

Wherever the iPad constructs the `SortingModel` for that sheet, set
`keepsSourceIntact = true` before presenting. An iPad session's source is a
Files location — very often the card — and moving a coach's originals out of
it is never the intent on that platform.

- [ ] **Step 4: Build the iPad scheme**

```bash
xcodegen generate
xcodebuild -project SkiVideoViewer.xcodeproj -scheme SkiVideoViewer-iPad -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Confirm the button appears**

```bash
xcrun simctl install <booted-ipad-udid> <path-to-built>/SkiVideoViewer.app
xcrun simctl launch <booted-ipad-udid> dk.dyregod.video-viewer.ipad
xcrun simctl io <booted-ipad-udid> screenshot /tmp/sorting-button.png
```
Open the screenshot and confirm a "Sort & Resize…" item is in the toolbar.
**Report what the screenshot shows rather than asserting the button is
there** — this step has no automated assertion behind it.

- [ ] **Step 6: Commit**

```bash
git add Sources/SkiVideoViewer/iOS/IOSSecondaryScreenPresenter.swift
git commit -m "Offer Sort & Resize on iPad"
```

---

### Task 6: Verify against a real SD card

The only step in this plan that cannot be automated, and the one the whole
plan is for. Everything above is checked against temporary directories; a real
card is a different filesystem (exFAT), reached through a security-scoped URL,
and can be pulled out mid-session.

**Files:** none — this task produces a written report only.

- [ ] **Step 1: Build and install on the connected iPad**

```bash
xcodebuild -project SkiVideoViewer.xcodeproj -scheme SkiVideoViewer-iPad \
  -destination 'id=AAE2EEBC-E5DB-5FE6-A544-2AB94ECC8838' -allowProvisioningUpdates \
  -derivedDataPath /tmp/dd-device build
xcrun devicectl device install app --device AAE2EEBC-E5DB-5FE6-A544-2AB94ECC8838 \
  /tmp/dd-device/Build/Products/Debug-iphoneos/SkiVideoViewer.app
```

- [ ] **Step 2: Record the card's contents before the session**

Photograph or list the card's directory in the Files app, so Step 4 has
something to compare against.

- [ ] **Step 3: Run a session**

Insert the card, open Sort & Resize, choose the card's clip folder, tag two or
three clips, and let the resizes finish.

- [ ] **Step 4: Confirm the card is untouched**

Compare the card's contents against Step 2. **Every original must still be
present, in its original folder.** This is the plan's single most important
assertion and no unit test can make it — the tests use temporary directories,
not exFAT reached through a security scope.

- [ ] **Step 5: Report findings**

Write down: whether the picker reached the card at all, whether the card was
unchanged, how long a clip took to resize, and what happened if the card was
removed mid-session. Note anything surprising — this is the first time this
code has met real removable media, and the design assumed rather than measured
its behaviour.

---

## Self-Review

**Spec coverage.** Plan 1 of the spec asks for four things: the `ClipPublisher`
seam (Task 2), `LocalFolderPublisher` extracted unchanged (Tasks 1–3),
`canPresentSorting` enabled (Task 5), and outputs redirected to app storage
(Task 4). The spec's "a session whose source is read-only writes nothing to the
source" test is Task 2 Step 1 and Task 4 Step 1; its real-card confirmation is
Task 6.

**Out of scope, per the spec:** no Drive changes, no `DriveUploader`, no OAuth
scope change, no durable queue. Those are Plan 2.

**Type consistency.** `PublishTargets.resizeSource` / `.resizeDestination`,
`ClipPublisher.prepare(source:athlete:event:)` and `.maySkipSourceMetadata` are
used with these exact names in Tasks 2, 3 and 4.
`SortingModel.keepsSourceIntact` and `.outputRoot` are introduced in Task 4 and
consumed in Task 5.

**Known risk.** Task 1 characterises code it does not own, so its first run may
need the test adjusted to the real `SortingModel` API. That is expected and
called out in the task; production code must not move to satisfy it.
