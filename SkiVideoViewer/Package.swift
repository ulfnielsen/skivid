// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "SkiVideoViewer",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "SkiVideoViewer", targets: ["SkiVideoViewer"]),
    ],
    targets: [
        .executableTarget(name: "SkiVideoViewer"),
        .testTarget(
            name: "SkiVideoViewerTests",
            dependencies: ["SkiVideoViewer"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
