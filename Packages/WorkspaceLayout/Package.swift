// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WorkspaceLayout",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "WorkspaceLayout", targets: ["WorkspaceLayout"]),
    ],
    dependencies: [
        // Acyclic: `PaneControl` imports Foundation and nothing else. The
        // dependency exists so the wire-to-layout translation the app target
        // used to own (`ControlDirection` -> `FocusDirection`,
        // `ControlLayoutNode` -> `PaneTree`) is a tested pure function here
        // instead of a switch with no test bundle behind it.
        .package(path: "../PaneControl"),
    ],
    targets: [
        .target(name: "WorkspaceLayout", dependencies: [
            .product(name: "PaneControl", package: "PaneControl"),
        ]),
        .testTarget(name: "WorkspaceLayoutTests", dependencies: [
            "WorkspaceLayout",
            .product(name: "PaneControl", package: "PaneControl"),
        ]),
    ]
)
