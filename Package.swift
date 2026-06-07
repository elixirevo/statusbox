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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "StatusBox",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
