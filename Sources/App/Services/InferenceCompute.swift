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

    /// Threads for the CPU path: one per physical core. Hyper-threads share a
    /// core's vector units, so they only add contention to matrix work. A VM
    /// can give the app fewer cores than the host has, so never more than
    /// that.
    static func cpuThreads(physicalCores: Int, activeCores: Int) -> Int {
        max(1, min(physicalCores, activeCores))
    }

    /// This Mac's CPU-path thread count, read once.
    static let cpuThreads: Int = {
        let active = ProcessInfo.processInfo.activeProcessorCount
        var physical: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let found = sysctlbyname("hw.physicalcpu", &physical, &size, nil, 0) == 0
        return cpuThreads(physicalCores: found ? Int(physical) : active, activeCores: active)
    }()
}
