import SkiVideoCore
import UniformTypeIdentifiers
import XCTest
@testable import SkiVideoViewer

/// Exercises the two former `NSOpenPanel` call sites (`chooseDirectory()` and
/// `chooseClientSecretsFile()`) through the `FolderPicker` seam.
///
/// `AppKitFolderPicker` itself cannot be unit-tested — `NSOpenPanel.runModal()`
/// blocks on user interaction — so this file is the real, *executing*
/// coverage for Task 4's wiring. The equivalent tests appended to
/// `Tests/SkiVideoCoreTests/ViewerModelIntentTests.swift.pending` do not
/// compile or run until Task 6 moves `ViewerModel` into `SkiVideoCore`; they
/// exist there only so that file is ready in advance.
///
/// This target cannot reuse `SkiVideoCoreTests/FakeSeams.swift`'s
/// `FakeFolderPicker` — `Package.swift` does not declare a test-to-test
/// dependency between `SkiVideoCoreTests` and `SkiVideoViewerTests` — so a
/// second, identical fake is defined below.
@MainActor
final class FolderPickerWiringTests: XCTestCase {
    private var temporaryDirectory: URL?

    private final class FakeFolderPicker: FolderPicker {
        var folderToReturn: URL?
        var fileToReturn: URL?
        private(set) var pickFolderCallCount = 0
        private(set) var pickFileCallCount = 0

        func pickFolder(startingAt: URL?) async -> URL? {
            pickFolderCallCount += 1
            return folderToReturn
        }

        func pickFile(ofType: UTType) async -> URL? {
            pickFileCallCount += 1
            return fileToReturn
        }
    }

    override func tearDown() async throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    /// `VideoLibrary.scan` only inspects file extensions, so empty files are
    /// enough to give the model a populated library.
    private func makeLibrary() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let athlete = root.appendingPathComponent("Idun", isDirectory: true)
        try FileManager.default.createDirectory(at: athlete, withIntermediateDirectories: true)
        for name in ["a.mp4", "b.mp4"] {
            FileManager.default.createFile(
                atPath: athlete.appendingPathComponent(name).path,
                contents: Data()
            )
        }
        temporaryDirectory = root
        return root
    }

    func testChooseDirectoryOpensWhatThePickerReturns() async throws {
        let picker = FakeFolderPicker()
        picker.folderToReturn = try makeLibrary()
        let model = ViewerModel(input: AppKitInputSource(), folderPicker: picker)

        await model.chooseDirectory()

        XCTAssertEqual(picker.pickFolderCallCount, 1)
        XCTAssertEqual(model.athletes.count, 1)
        XCTAssertEqual(model.athletes.first?.name, "Idun")
    }

    func testChooseDirectoryDoesNothingWhenCancelled() async throws {
        let picker = FakeFolderPicker()
        picker.folderToReturn = nil
        let model = ViewerModel(input: AppKitInputSource(), folderPicker: picker)

        await model.chooseDirectory()

        XCTAssertEqual(picker.pickFolderCallCount, 1)
        XCTAssertTrue(model.athletes.isEmpty)
    }

    func testChooseClientSecretsFileStoresWhatThePickerReturns() async throws {
        let picker = FakeFolderPicker()
        let secretsURL = URL(fileURLWithPath: "/tmp/does-not-need-to-exist-client_secret.json")
        picker.fileToReturn = secretsURL
        let model = ViewerModel(input: AppKitInputSource(), folderPicker: picker)

        await model.chooseClientSecretsFile()

        XCTAssertEqual(picker.pickFileCallCount, 1)
        XCTAssertEqual(model.clientSecretsPath, secretsURL.path)
    }

    func testChooseClientSecretsFileDoesNothingWhenCancelled() async throws {
        let picker = FakeFolderPicker()
        picker.fileToReturn = nil
        let model = ViewerModel(input: AppKitInputSource(), folderPicker: picker)
        let pathBefore = model.clientSecretsPath

        await model.chooseClientSecretsFile()

        XCTAssertEqual(picker.pickFileCallCount, 1)
        XCTAssertEqual(model.clientSecretsPath, pathBefore)
    }
}
