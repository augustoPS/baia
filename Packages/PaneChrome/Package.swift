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
        // The theme catalog and the terminal configuration types, so the
        // `Settings` → theme derivations are tested here rather than in the app
        // target, which has no test bundle. This is the first local package to
        // depend on libghostty.
        //
        // It takes `GhosttyTerminal` as well as `GhosttyTheme`, which is the
        // part worth stating: `TerminalTheme` and `TerminalConfiguration` are
        // defined there, and so is the rendering half (`View/`, `Surface/`,
        // `Platform/`) that `make test` deliberately stays clear of. Measured
        // before being taken, and again after: `make test` runs green with no
        // Metal, no window and no signing, because importing a module links it
        // without instantiating anything in it.
        //
        // The seam holds only while this package's API stays value-shaped. A
        // function here taking a controller or a surface would put a live
        // renderer behind a call the one-second loop makes.
        .package(path: "../../upstream/libghostty-spm"),
    ],
    targets: [
        .target(name: "PaneChrome", dependencies: [
            .product(name: "BaiaSettings", package: "BaiaSettings"),
            .product(name: "GitWorkspace", package: "GitWorkspace"),
            .product(name: "GhosttyTheme", package: "libghostty-spm"),
            .product(name: "GhosttyTerminal", package: "libghostty-spm"),
        ]),
        .testTarget(name: "PaneChromeTests", dependencies: [
            "PaneChrome",
            .product(name: "GitWorkspace", package: "GitWorkspace"),
            .product(name: "BaiaSettings", package: "BaiaSettings"),
        ]),
    ]
)
