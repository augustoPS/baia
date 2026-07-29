// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WorkspaceMenu",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "WorkspaceMenu", targets: ["WorkspaceMenu"]),
    ],
    targets: [
        .target(name: "WorkspaceMenu"),
        .testTarget(name: "WorkspaceMenuTests", dependencies: ["WorkspaceMenu"]),
    ]
)
