// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenClickyBrowser",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "OpenClickyBrowser",
            targets: ["OpenClickyBrowser"]
        )
    ],
    dependencies: [
        .package(path: "../OpenClickyCore"),
        .package(path: "../OpenClickyUI")
    ],
    targets: [
        .target(
            name: "OpenClickyBrowser",
            dependencies: [
                .product(name: "OpenClickyCore", package: "OpenClickyCore"),
                .product(name: "OpenClickyUI", package: "OpenClickyUI")
            ],
            path: "Sources/OpenClickyBrowser"
        )
    ]
)
