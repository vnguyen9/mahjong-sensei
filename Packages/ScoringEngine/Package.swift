// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ScoringEngine",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "ScoringEngine", targets: ["ScoringEngine"]),
    ],
    dependencies: [
        .package(path: "../MahjongCore"),
    ],
    targets: [
        .target(name: "ScoringEngine", dependencies: ["MahjongCore"]),
        .testTarget(name: "ScoringEngineTests", dependencies: ["ScoringEngine", "MahjongCore"]),
    ],
    swiftLanguageModes: [.v5]
)
