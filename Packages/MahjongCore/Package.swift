// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MahjongCore",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "MahjongCore", targets: ["MahjongCore"]),
    ],
    targets: [
        .target(name: "MahjongCore"),
        .testTarget(name: "MahjongCoreTests", dependencies: ["MahjongCore"]),
    ],
    swiftLanguageModes: [.v5]
)
