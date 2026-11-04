import Foundation

/// A snapshot of what this Mac can comfortably run, used to recommend model
/// sizes. Kept as a plain value so the recommendation logic can be tested
/// with fabricated hardware.
struct HardwareCapabilities: Equatable {
    let isAppleSilicon: Bool
    let physicalMemoryGB: Int
    let coreCount: Int
    let chipDescription: String
    /// Whether the CPU has what the x86_64 speech and AI runtimes are built
    /// for: AVX2, FMA, F16C and BMI2 (Intel Haswell, 2013, and later).
    /// Always true on Apple silicon.
    var hasAVX2: Bool = true

    static func current() -> HardwareCapabilities {
        let memoryGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        let cores = ProcessInfo.processInfo.processorCount
        let appleSilicon = sysctlInt("hw.optional.arm64") == 1
        let chip = sysctlString("machdep.cpu.brand_string")
            ?? sysctlString("hw.model")
            ?? (appleSilicon ? "Apple Silicon" : "Mac")
        return HardwareCapabilities(
            isAppleSilicon: appleSilicon,
            physicalMemoryGB: memoryGB,
            coreCount: cores,
            chipDescription: chip,
            hasAVX2: appleSilicon || avx2Features.allSatisfy { sysctlInt($0) == 1 }
        )
    }

    /// The `hw.optional` keys macOS sets to 1 when the CPU has each feature.
    static let avx2Features = ["hw.optional.avx2_0", "hw.optional.fma", "hw.optional.f16c", "hw.optional.bmi2"]

    var shortDescription: String {
        // Lead with the real chip (e.g. "Apple M3 Pro") — captured from
        // machdep.cpu.brand_string — then CPU cores and unified memory, which is
        // the actual limiter for on-device Whisper/LLM inference. (macOS exposes
        // no API for Neural Engine or GPU core counts, so those aren't shown.)
        "\(chipDescription) · \(coreCount)-core CPU · \(physicalMemoryGB) GB memory"
    }

    static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
