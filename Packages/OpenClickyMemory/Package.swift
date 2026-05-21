// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenClickyMemory",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "OpenClickyMemory",
            targets: ["OpenClickyMemory"]
        )
    ],
    dependencies: [
        .package(path: "../OpenClickyCore"),
        .package(path: "../OpenClickyUI")
    ],
    targets: [
        .target(
            name: "OpenClickyMemory",
            dependencies: [
                .product(name: "OpenClickyCore", package: "OpenClickyCore"),
                .product(name: "OpenClickyUI", package: "OpenClickyUI")
            ],
            path: "Sources/OpenClickyMemory"
        )
    ]
)
