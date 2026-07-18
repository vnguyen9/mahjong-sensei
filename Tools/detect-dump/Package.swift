// swift-tools-version: 6.2
import PackageDescription

// macOS-only fixture + video harness — runs the app's detector on still photos
// and recorded video from the command line. Never shipped; lives outside
// Packages/ so the app graph is untouched.
let package = Package(
    name: "detect-dump",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Packages/Recognition"),
        .package(path: "../../Packages/MahjongCore"),
    ],
    targets: [
        // Shared JSONL frame-stream codec + model-loading path + track-replay
        // engine, used by the three executables below (and unit-tested
        // directly by HarnessKitTests).
        .target(
            name: "HarnessKit",
            dependencies: [
                .product(name: "Recognition", package: "Recognition"),
                .product(name: "MahjongCore", package: "MahjongCore"),
            ]
        ),
        .executableTarget(
            name: "detect-dump",
            dependencies: [
                "HarnessKit",
                .product(name: "Recognition", package: "Recognition"),
                .product(name: "MahjongCore", package: "MahjongCore"),
            ]
        ),
        .executableTarget(
            name: "video-dump",
            dependencies: [
                "HarnessKit",
                .product(name: "Recognition", package: "Recognition"),
            ]
        ),
        .executableTarget(
            name: "track-replay",
            dependencies: [
                "HarnessKit",
                .product(name: "Recognition", package: "Recognition"),
                .product(name: "MahjongCore", package: "MahjongCore"),
            ]
        ),
        .testTarget(
            name: "HarnessKitTests",
            dependencies: [
                "HarnessKit",
                .product(name: "Recognition", package: "Recognition"),
                .product(name: "MahjongCore", package: "MahjongCore"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
