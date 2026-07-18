// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VerseBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VerseBar", targets: ["VerseBar"]),
    ],
    targets: [
        .executableTarget(name: "VerseBar", path: "Sources"),
    ],
    swiftLanguageModes: [.v5]
)
