// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PaneActivity",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PaneActivity", targets: ["PaneActivity"]),
    ],
    targets: [
        .target(name: "PaneActivity"),
        .testTarget(name: "PaneActivityTests", dependencies: ["PaneActivity"]),
    ]
)
