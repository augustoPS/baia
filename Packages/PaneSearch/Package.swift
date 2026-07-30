// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PaneSearch",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PaneSearch", targets: ["PaneSearch"]),
    ],
    targets: [
        .target(name: "PaneSearch"),
        .testTarget(name: "PaneSearchTests", dependencies: ["PaneSearch"]),
    ]
)
