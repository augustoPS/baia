// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WorkspaceLayout",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WorkspaceLayout", targets: ["WorkspaceLayout"]),
    ],
    targets: [
        .target(name: "WorkspaceLayout"),
        .testTarget(name: "WorkspaceLayoutTests", dependencies: ["WorkspaceLayout"]),
    ]
)
