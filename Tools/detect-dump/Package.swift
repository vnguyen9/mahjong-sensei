// swift-tools-version: 6.2
import PackageDescription

// macOS-only fixture harness — runs the app's detector on still photos from the
// command line. Never shipped; lives outside Packages/ so the app graph is untouched.
let package = Package(
    name: "detect-dump",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Packages/Recognition"),
        .package(path: "../../Packages/MahjongCore"),
    ],
    targets: [
        .executableTarget(
            name: "detect-dump",
            dependencies: [
                .product(name: "Recognition", package: "Recognition"),
                .product(name: "MahjongCore", package: "MahjongCore"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
