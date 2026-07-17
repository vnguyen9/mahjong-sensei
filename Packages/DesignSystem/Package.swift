// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DesignSystem",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
    ],
    dependencies: [
        .package(path: "../MahjongCore"),
    ],
    targets: [
        .target(name: "DesignSystem", dependencies: ["MahjongCore"]),
    ],
    swiftLanguageModes: [.v5]
)
