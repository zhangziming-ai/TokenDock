// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TokenDock",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TokenDock", targets: ["TokenDock"])
    ],
    targets: [
        .executableTarget(name: "TokenDock")
    ]
)

