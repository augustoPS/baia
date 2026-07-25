// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaneChrome",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PaneChrome", targets: ["PaneChrome"]),
    ],
    targets: [
        .target(name: "PaneChrome"),
        .testTarget(name: "PaneChromeTests", dependencies: ["PaneChrome"]),
    ]
)
