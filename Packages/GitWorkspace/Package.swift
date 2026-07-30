// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GitWorkspace",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "GitWorkspace", targets: ["GitWorkspace"]),
    ],
    targets: [
        .target(name: "GitWorkspace"),
        .testTarget(name: "GitWorkspaceTests", dependencies: ["GitWorkspace"]),
    ]
)
