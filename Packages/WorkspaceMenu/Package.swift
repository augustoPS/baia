// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WorkspaceMenu",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WorkspaceMenu", targets: ["WorkspaceMenu"]),
    ],
    targets: [
        .target(name: "WorkspaceMenu"),
        .testTarget(name: "WorkspaceMenuTests", dependencies: ["WorkspaceMenu"]),
    ]
)
