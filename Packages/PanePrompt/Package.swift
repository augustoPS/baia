// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PanePrompt",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PanePrompt", targets: ["PanePrompt"]),
    ],
    targets: [
        .target(name: "PanePrompt"),
        .testTarget(name: "PanePromptTests", dependencies: ["PanePrompt"]),
    ]
)
