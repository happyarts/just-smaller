// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "just-smaller",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "JustSmallerKit", targets: ["JustSmallerKit"]),
        .executable(name: "just-smaller", targets: ["just-smaller"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "JustSmallerKit",
            resources: [
                .process("Resources"),
            ]
        ),
        .executableTarget(
            name: "just-smaller",
            dependencies: [
                "JustSmallerKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "JustSmallerKitTests",
            dependencies: ["JustSmallerKit"]
        ),
    ]
)
