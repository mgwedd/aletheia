// swift-tools-version: 5.9
import PackageDescription

// The official llama.cpp runtime (ggml-org), as the prebuilt XCFramework the
// project publishes with each build: Metal on (shaders embedded), arm64 +
// x86_64 macOS slice. The framework's Clang module is `llama`. Pinned by URL
// and checksum, so nothing floats.
//
// To update: pick the new build tag, then `swift package compute-checksum <zip>`
// and re-verify every `llama.h` call in Sources/App/Services/Llama.
let package = Package(
    name: "LlamaCpp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LlamaCpp", targets: ["llama"])
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11149/llama-b11149-xcframework.zip",
            checksum: "b7331e4c203fde68e999e1a238e375a7e13e4000f8d4353f0e8900dea23c5fb1"
        )
    ]
)
