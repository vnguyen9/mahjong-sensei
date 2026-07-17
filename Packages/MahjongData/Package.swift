// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MahjongData",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "MahjongData", targets: ["MahjongData"]),
    ],
    dependencies: [
        .package(path: "../MahjongCore"),
    ],
    targets: [
        .target(name: "MahjongData", dependencies: ["MahjongCore"]),
        .testTarget(name: "MahjongDataTests", dependencies: ["MahjongData", "MahjongCore"]),
    ],
    swiftLanguageModes: [.v5]
)
