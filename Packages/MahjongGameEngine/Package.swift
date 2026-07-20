// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MahjongGameEngine",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "MahjongGameEngine", targets: ["MahjongGameEngine"])],
    dependencies: [
        .package(path: "../MahjongCore"),
        .package(path: "../ScoringEngine"),
        .package(path: "../EfficiencyEngine"),
        .package(path: "../CoachEngine"),
    ],
    targets: [
        .target(name: "MahjongGameEngine", dependencies: ["MahjongCore", "ScoringEngine", "EfficiencyEngine", "CoachEngine"]),
        .testTarget(
            name: "MahjongGameEngineTests",
            dependencies: ["MahjongGameEngine", "MahjongCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
