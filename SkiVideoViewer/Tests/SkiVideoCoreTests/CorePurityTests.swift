import XCTest

final class CorePurityTests: XCTestCase {
    /// `Sources/SkiVideoCore` must stay portable. The iOS platform component is
    /// not installed on all dev machines, so we cannot rely on a cross-compile
    /// to catch AppKit or Process creeping in. This scans the sources instead.
    func testCoreSourcesAvoidPlatformSpecificAPIs() throws {
        let coreDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SkiVideoCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/SkiVideoCore", isDirectory: true)

        let forbidden = [
            "import AppKit",
            "import UIKit",
            "import SwiftUI",
            "Process(",
        ]

        let files = try FileManager.default
            .contentsOfDirectory(at: coreDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }

        XCTAssertFalse(files.isEmpty, "No sources found at \(coreDirectory.path)")

        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(
                    contents.contains(token),
                    "\(file.lastPathComponent) contains forbidden token '\(token)'"
                )
            }
        }
    }
}
