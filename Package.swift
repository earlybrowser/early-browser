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
        // Reader Mode's extraction: Mozilla Readability, unmodified (Apache-2.0).
        .target(name: "EarlyWeb", dependencies: ["EarlyCore"], resources: [.copy("Resources/Readability")]),
        // Compile the native application layer without its executable entry
        // point so lifecycle/settings integration can be tested without UI automation.
        .target(name: "EarlyBrowser", dependencies: ["EarlyCore", "EarlyWeb"], path: "Sources/Early", exclude: ["EarlyApp.swift"]),
        .testTarget(name: "EarlyCoreTests", dependencies: ["EarlyCore"]),
        .testTarget(name: "EarlyWebTests", dependencies: ["EarlyWeb", "EarlyCore"]),
        .testTarget(name: "EarlyBrowserTests", dependencies: ["EarlyBrowser", "EarlyCore", "EarlyWeb"])
    ],
    swiftLanguageModes: [.v6]
)
