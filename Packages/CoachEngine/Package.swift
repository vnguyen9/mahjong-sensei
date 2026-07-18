// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoachEngine",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "CoachEngine", targets: ["CoachEngine"]),
    ],
    dependencies: [
        .package(path: "../MahjongCore"),
        .package(path: "../EfficiencyEngine"),
        .package(path: "../ScoringEngine"),
    ],
    targets: [
        .target(name: "CoachEngine", dependencies: ["MahjongCore", "EfficiencyEngine", "ScoringEngine"]),
        .testTarget(name: "CoachEngineTests",
                   dependencies: ["CoachEngine", "MahjongCore", "EfficiencyEngine", "ScoringEngine"]),
    ],
    swiftLanguageModes: [.v5]
)
