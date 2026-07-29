// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PanePrompt",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PanePrompt", targets: ["PanePrompt"]),
    ],
    targets: [
        .target(name: "PanePrompt"),
        .testTarget(name: "PanePromptTests", dependencies: ["PanePrompt"]),
    ]
)
