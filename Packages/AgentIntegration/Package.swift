// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentIntegration",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AgentIntegration", targets: ["AgentIntegration"]),
    ],
    targets: [
        .target(
            name: "AgentIntegration",
            // Embedded rather than copied into a bundle. `baia install-hooks` has
            // to write this file wherever the owner's hooks live, which is not
            // inside the app, so the bytes travel in the binary. The direct
            // analogue of herdr's `include_str!`.
            resources: [.embedInCode("Resources/baia-agent-state.sh")]
        ),
        .testTarget(name: "AgentIntegrationTests", dependencies: ["AgentIntegration"]),
    ]
)
