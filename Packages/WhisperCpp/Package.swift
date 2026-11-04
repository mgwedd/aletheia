// swift-tools-version: 5.9
import PackageDescription

// The official whisper.cpp runtime (ggml-org), as the prebuilt XCFramework the
// project publishes with each build: Metal on (shaders embedded), Core ML
// with fallback, arm64 + x86_64. Pinned by URL and checksum, so nothing floats.
//
// To update: pick the build tag whose commit matches the wanted v-release
// (v-tags carry no assets), then `swift package compute-checksum <zip>`.
//
// The `upstream:` line pins the release tag and the commit it names, and
// `upstream-zip:` pins upstream's zip. The url/checksum below may instead name
// our build of that zip with an AVX2 x86_64 slice (arm64 left as upstream's):
// see scripts/build-x86-runtime.sh and .github/workflows/runtime-x86.yml.
// scripts/check-runtime-pins.sh keeps these lines and the url in step.
// upstream: ggml-org/whisper.cpp b5454 d1be6fde11ac6e0407606b4e42fe72d34add8037
// upstream-zip: e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b
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
            url: "https://github.com/mgwedd/aletheia/releases/download/runtime-x86avx2-cpu-b11149-b5454/whisper-b5454-x86avx2-xcframework.zip",
            checksum: "8e393b89ea2c5b8c5836e15376051d19a79d3a48c4a9cd1843c116dff591fd1b"
        )
    ]
)
