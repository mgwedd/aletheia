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
        .package(path: "Packages/WhisperCpp"),
        .package(path: "Packages/LlamaCpp")
    ],
    targets: [
        .target(
            name: "WhisperEngine",
            dependencies: [
                .product(name: "WhisperCpp", package: "WhisperCpp")
            ],
            path: "Sources/WhisperEngine",
            resources: [.process("ggml-silero-v6.2.0.bin")]
        ),
        .target(
            name: "Aletheia",
            dependencies: [
                "WhisperEngine",
                .product(name: "LlamaCpp", package: "LlamaCpp")
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
            dependencies: ["Aletheia", "WhisperEngine"],
            path: "Tests/AletheiaTests",
            swiftSettings: [
                .define("DEBUG"),
                .define("ALETHEIA_PREVIEW"),
                .define("ALETHEIA_DEV")
            ]
        )
    ]
)
