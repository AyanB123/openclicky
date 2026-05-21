// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenClickyMarkdown",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "OpenClickyMarkdown",
            targets: ["OpenClickyMarkdown"]
        )
    ],
    dependencies: [
        .package(path: "../OpenClickyUI")
    ],
    targets: [
        .target(
            name: "OpenClickyMarkdown",
            dependencies: [
                .product(name: "OpenClickyUI", package: "OpenClickyUI")
            ],
            path: "Sources/OpenClickyMarkdown"
        )
    ]
)
