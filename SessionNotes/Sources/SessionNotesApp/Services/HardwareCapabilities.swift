import Foundation

/// A snapshot of what this Mac can comfortably run, used to recommend model
/// sizes. Kept as a plain value so the recommendation logic can be tested
/// with fabricated hardware.
struct HardwareCapabilities: Equatable {
    let isAppleSilicon: Bool
    let physicalMemoryGB: Int
    let coreCount: Int
    let chipDescription: String

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
            chipDescription: chip
        )
    }

    var shortDescription: String {
        let arch = isAppleSilicon ? "Apple Silicon" : "Intel"
        return "\(arch), \(physicalMemoryGB) GB memory"
    }

    private static func sysctlInt(_ name: String) -> Int64? {
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
