// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Aletheia",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "Aletheia",
            targets: ["Aletheia"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "Aletheia",
            dependencies: [
                .product(name: "SwiftWhisper", package: "SwiftWhisper")
            ],
            path: "Sources/App",
            exclude: [
                "AletheiaApp.swift",
                "Resources/Info.plist",
                "Resources/Aletheia.entitlements",
                "Resources/AletheiaDev.entitlements"
            ],
            swiftSettings: [
                .define("DEBUG"),
                .define("ALETHEIA_PREVIEW"),
                .define("ALETHEIA_DEV")
            ]
        ),
        .testTarget(
            name: "AletheiaTests",
            dependencies: ["Aletheia"],
            path: "Tests/AletheiaTests",
            swiftSettings: [
                .define("DEBUG"),
                .define("ALETHEIA_PREVIEW"),
                .define("ALETHEIA_DEV")
            ]
        )
    ]
)
