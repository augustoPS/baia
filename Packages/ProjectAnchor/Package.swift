// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProjectAnchor",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ProjectAnchor", targets: ["ProjectAnchor"]),
    ],
    targets: [
        .target(name: "ProjectAnchor"),
        .testTarget(name: "ProjectAnchorTests", dependencies: ["ProjectAnchor"]),
    ]
)
