// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PaneChrome",
    platforms: [.macOS(.v26)],
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
        // Acyclic: `GitWorkspace` imports only Foundation. The dependency exists
        // so the command palette's translation from `GitWorkspace`'s vocabulary
        // (`Project.Kind`, `RepositoryStatus`) into this package's own
        // (`PaletteRowKind`, `PaneStatusRun`) is a tested pure function here
        // instead of a switch in the app target, which has no test bundle.
        .package(path: "../GitWorkspace"),
    ],
    targets: [
        .target(name: "PaneChrome", dependencies: [
            .product(name: "BaiaSettings", package: "BaiaSettings"),
            .product(name: "GitWorkspace", package: "GitWorkspace"),
        ]),
        .testTarget(name: "PaneChromeTests", dependencies: [
            "PaneChrome",
            .product(name: "GitWorkspace", package: "GitWorkspace"),
        ]),
    ]
)
