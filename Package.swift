// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EarlyCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EarlyCore", targets: ["EarlyCore"])
    ],
    targets: [
        .target(name: "EarlyCore"),
        .testTarget(name: "EarlyCoreTests", dependencies: ["EarlyCore"])
    ],
    swiftLanguageModes: [.v6]
)
