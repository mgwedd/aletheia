// swift-tools-version: 5.9
import PackageDescription

// The official llama.cpp runtime (ggml-org), as the prebuilt XCFramework the
// project publishes with each build: Metal on (shaders embedded), arm64 +
// x86_64 macOS slice. The framework's Clang module is `llama`. Pinned by URL
// and checksum, so nothing floats.
//
// To update: pick the new build tag, then `swift package compute-checksum <zip>`
// and re-verify every `llama.h` call in Sources/App/Services/Llama.
//
// The `upstream:` line pins the release tag and the commit it names, and
// `upstream-zip:` pins upstream's zip. The url/checksum below may instead name
// our build of that zip with an AVX2 x86_64 slice (arm64 left as upstream's):
// see scripts/build-x86-runtime.sh and .github/workflows/runtime-x86.yml.
// scripts/check-runtime-pins.sh keeps these lines and the url in step.
// upstream: ggml-org/llama.cpp b11149 d2e54583c7452353eb35d40431281f6ee984332f
// upstream-zip: b7331e4c203fde68e999e1a238e375a7e13e4000f8d4353f0e8900dea23c5fb1
let package = Package(
    name: "LlamaCpp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LlamaCpp", targets: ["llama"])
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/mgwedd/aletheia/releases/download/runtime-x86avx2-cpu-b11149-b5454/llama-b11149-x86avx2-xcframework.zip",
            checksum: "4679998dec398e28de329653af28b2be600afa5824458502be3cfeff154b5a53"
        )
    ]
)
