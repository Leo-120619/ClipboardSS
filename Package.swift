// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ClipboardSS",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ClipboardCore", targets: ["ClipboardCore"]),
        .executable(name: "ClipboardSS", targets: ["ClipboardSS"])
    ],
    targets: [
        .target(
            name: "ClipboardCore"
        ),
        .executableTarget(
            name: "ClipboardSS",
            dependencies: ["ClipboardCore"]
        ),
        .testTarget(
            name: "ClipboardCoreTests",
            dependencies: ["ClipboardCore"]
        ),
        .testTarget(
            name: "ClipboardSSTests",
            dependencies: ["ClipboardSS"]
        )
    ]
)
