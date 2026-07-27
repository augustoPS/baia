// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaneChrome",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PaneChrome", targets: ["PaneChrome"]),
    ],
    dependencies: [
        // Acyclic: `BaiaSettings` imports Darwin and Foundation and nothing else.
        // The dependency exists so `accent(for:)` is a tested pure function in
        // the one-second loop rather than a switch in the app target, which has
        // no test bundle. `focusAccent` was decoded, stored and tested for a
        // week while nothing read it, which is what an untestable wiring buys.
        .package(path: "../BaiaSettings"),
    ],
    targets: [
        .target(name: "PaneChrome", dependencies: [
            .product(name: "BaiaSettings", package: "BaiaSettings"),
        ]),
        .testTarget(name: "PaneChromeTests", dependencies: ["PaneChrome"]),
    ]
)
