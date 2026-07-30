// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentIntegration",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AgentIntegration", targets: ["AgentIntegration"]),
    ],
    targets: [
        .target(name: "AgentIntegration"),
        .testTarget(name: "AgentIntegrationTests", dependencies: ["AgentIntegration"]),
    ]
)
