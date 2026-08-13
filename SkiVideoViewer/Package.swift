// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "SkiVideoViewer",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
    ],
    products: [
        .library(name: "SkiVideoCore", targets: ["SkiVideoCore"]),
        .executable(name: "SkiVideoViewer", targets: ["SkiVideoViewer"]),
    ],
    targets: [
        .target(name: "SkiVideoCore"),
        .executableTarget(
            name: "SkiVideoViewer",
            dependencies: ["SkiVideoCore"],
            // The iPad shell is built by the Xcode project, not by SwiftPM.
            // SwiftPM would otherwise try to compile UIKit sources for macOS.
            exclude: ["iOS"]
        ),
        .testTarget(
            name: "SkiVideoCoreTests",
            dependencies: ["SkiVideoCore"]
        ),
        // Tests the app target itself, including the AppKit seam
        // implementations. A test target can @testable import an executable
        // target from swift-tools 5.5 onward.
        //
        // Depends on `SkiVideoCoreTests` too, so `RemoteAnalysisIdentityTests`
        // can reuse that target's `RemoteLibraryTestSupport` helpers and its
        // `FakeRemoteProvider` rather than keeping a second copy of either.
        .testTarget(
            name: "SkiVideoViewerTests",
            dependencies: ["SkiVideoViewer", "SkiVideoCore", "SkiVideoCoreTests"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
