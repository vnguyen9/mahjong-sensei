// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Recognition",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "Recognition", targets: ["Recognition"]),
    ],
    dependencies: [
        .package(path: "../MahjongCore"),
    ],
    targets: [
        .target(name: "Recognition", dependencies: ["MahjongCore"]),
        .testTarget(name: "RecognitionTests", dependencies: ["Recognition", "MahjongCore"]),
    ],
    swiftLanguageModes: [.v5]
)
