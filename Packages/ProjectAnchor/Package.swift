// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ProjectAnchor",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ProjectAnchor", targets: ["ProjectAnchor"]),
    ],
    targets: [
        .target(name: "ProjectAnchor"),
        .testTarget(name: "ProjectAnchorTests", dependencies: ["ProjectAnchor"]),
    ]
)
