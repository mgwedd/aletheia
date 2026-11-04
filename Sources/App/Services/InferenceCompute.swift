import Foundation

/// Whether the on-device engines (whisper.cpp and llama.cpp) run on the GPU.
///
/// Apple silicon runs both on Metal. Intel Macs run them on the CPU: the
/// bundled ggml Metal kernels are built for Apple GPUs (simdgroup matrix
/// multiply, flash attention), which Intel and AMD GPUs lack, and the
/// `Benchmarks (Intel)` workflow measures both paths on an Intel runner.
enum InferenceCompute {
    static func usesGPU(on hardware: HardwareCapabilities) -> Bool {
        hardware.isAppleSilicon
    }

    /// This Mac's choice, read once.
    static let usesGPU = usesGPU(on: .current())
}
