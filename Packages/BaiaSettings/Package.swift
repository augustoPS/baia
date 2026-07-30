// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BaiaSettings",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BaiaSettings", targets: ["BaiaSettings"]),
    ],
    targets: [
        .target(name: "BaiaSettings"),
        .testTarget(name: "BaiaSettingsTests", dependencies: ["BaiaSettings"]),
    ]
)
