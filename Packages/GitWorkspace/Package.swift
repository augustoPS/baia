// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitWorkspace",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GitWorkspace", targets: ["GitWorkspace"]),
    ],
    targets: [
        .target(name: "GitWorkspace"),
        .testTarget(name: "GitWorkspaceTests", dependencies: ["GitWorkspace"]),
    ]
)
