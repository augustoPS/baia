// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaneControl",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PaneControl", targets: ["PaneControl"]),
    ],
    targets: [
        .target(name: "PaneControl"),
        .testTarget(name: "PaneControlTests", dependencies: ["PaneControl"]),
    ]
)
