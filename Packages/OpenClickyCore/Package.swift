// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenClickyCore",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "OpenClickyCore",
            targets: ["OpenClickyCore"]
        )
    ],
    targets: [
        .target(
            name: "OpenClickyCore",
            dependencies: [],
            path: "Sources/OpenClickyCore"
        )
    ]
)
