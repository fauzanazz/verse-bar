// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PlayerStudio",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PlayerStudio", targets: ["PlayerStudio"]),
    ],
    targets: [
        .executableTarget(name: "PlayerStudio", path: "Sources"),
        .testTarget(name: "PlayerStudioTests", dependencies: ["PlayerStudio"], path: "Tests"),
    ],
    swiftLanguageModes: [.v5]
)
