// swift-tools-version: 6.0
// SPDX-License-Identifier: MPL-2.0

import PackageDescription

let package = Package(
    name: "EarlyCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EarlyCore", targets: ["EarlyCore"]),
        .library(name: "EarlyWeb", targets: ["EarlyWeb"])
    ],
    targets: [
        .target(name: "EarlyCore"),
        .target(name: "EarlyWeb", dependencies: ["EarlyCore"]),
        .testTarget(name: "EarlyCoreTests", dependencies: ["EarlyCore"]),
        .testTarget(name: "EarlyWebTests", dependencies: ["EarlyWeb", "EarlyCore"])
    ],
    swiftLanguageModes: [.v6]
)
