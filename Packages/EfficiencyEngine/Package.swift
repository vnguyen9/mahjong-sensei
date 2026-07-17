// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EfficiencyEngine",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "EfficiencyEngine", targets: ["EfficiencyEngine"]),
    ],
    dependencies: [
        .package(path: "../MahjongCore"),
    ],
    targets: [
        .target(name: "EfficiencyEngine", dependencies: ["MahjongCore"]),
        .testTarget(name: "EfficiencyEngineTests", dependencies: ["EfficiencyEngine", "MahjongCore"]),
    ],
    swiftLanguageModes: [.v5]
)
