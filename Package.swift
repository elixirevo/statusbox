// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "StatusBox",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "StatusBox", targets: ["StatusBox"])
    ],
    targets: [
        .executableTarget(
            name: "StatusBox",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
