// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenClickyUI",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "OpenClickyUI",
            targets: ["OpenClickyUI"]
        )
    ],
    dependencies: [
        .package(path: "../OpenClickyCore")
    ],
    targets: [
        .target(
            name: "OpenClickyUI",
            dependencies: [
                .product(name: "OpenClickyCore", package: "OpenClickyCore")
            ],
            path: "Sources/OpenClickyUI"
        )
    ]
)
