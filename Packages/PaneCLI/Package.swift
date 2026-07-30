// swift-tools-version: 6.2
import PackageDescription

// The CLI's decidable half, split out of the `baia-cli` tool target so
// `make test` can reach it: that target is an XcodeGen tool under `CLI/` and
// the test loop iterates `Packages/*`, so anything left there is untested by
// construction. Parsing, exit statuses, help text and rendering are decidable
// from their inputs, so they live here; the sockets, the environment reads and
// the stream writes stay in the tool.
let package = Package(
    name: "PaneCLI",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PaneCLI", targets: ["PaneCLI"]),
    ],
    dependencies: [
        .package(path: "../PaneControl"),
    ],
    targets: [
        .target(name: "PaneCLI", dependencies: ["PaneControl"]),
        // PaneControl by name as well as through PaneCLI: the tests build the
        // wire types they assert against, so they depend on it directly rather
        // than on it happening to arrive transitively.
        .testTarget(name: "PaneCLITests", dependencies: ["PaneCLI", "PaneControl"]),
    ]
)
