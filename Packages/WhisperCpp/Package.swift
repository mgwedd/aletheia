// swift-tools-version: 5.9
import PackageDescription

// The official whisper.cpp runtime (ggml-org), as the prebuilt XCFramework the
// project publishes with each build: Metal on (shaders embedded), Core ML
// with fallback, arm64 + x86_64. Pinned by URL and checksum, so nothing floats.
//
// To update: pick the build tag whose commit matches the wanted v-release
// (v-tags carry no assets), then `swift package compute-checksum <zip>`.
let package = Package(
    name: "WhisperCpp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WhisperCpp", targets: ["whisper"])
    ],
    targets: [
        .binaryTarget(
            name: "whisper",
            // Build b5454 = v1.9.5 (commit d1be6fde11ac6e0407606b4e42fe72d34add8037).
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
        )
    ]
)
