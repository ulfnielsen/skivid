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
            dependencies: ["SkiVideoCore"]
        ),
        .testTarget(
            name: "SkiVideoCoreTests",
            dependencies: ["SkiVideoCore"]
        ),
        // Tests the app target itself, including the AppKit seam
        // implementations. A test target can @testable import an executable
        // target from swift-tools 5.5 onward.
        .testTarget(
            name: "SkiVideoViewerTests",
            dependencies: ["SkiVideoViewer", "SkiVideoCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
