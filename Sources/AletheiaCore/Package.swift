// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AletheiaCore",
    platforms: [.macOS(.v14)],
    products: [
        // Static: the Xcode app target embeds this as a framework otherwise,
        // which drags in the privacy-manifest-scan step for local packages —
        // that step was found to corrupt the app's Info.plist synthesis
        // (dropping CFBundleIdentifier), crashing app-sandbox init on launch.
        // Static linking avoids the embedded-framework path entirely.
        .library(name: "AletheiaCore", type: .static, targets: ["AletheiaCore"])
    ],
    targets: [
        .target(name: "AletheiaCore"),
        .testTarget(name: "AletheiaCoreTests", dependencies: ["AletheiaCore"])
    ]
)
