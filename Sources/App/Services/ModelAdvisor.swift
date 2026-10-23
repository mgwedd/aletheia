import Foundation

struct ModelRecommendation: Equatable {
    let whisperModel: WhisperModel
    let summary: String
}

/// Recommends model sizes from the Mac's capabilities, so the user doesn't
/// have to know what "8B" means. Bigger models are more accurate but need
/// more memory and are slower, so the tiers key off RAM (and Apple Silicon,
/// which runs these far faster than Intel).
enum ModelAdvisor {
    static func recommend(for hardware: HardwareCapabilities) -> ModelRecommendation {
        let whisper: WhisperModel

        switch (hardware.isAppleSilicon, hardware.physicalMemoryGB) {
        case (true, 16...):
            whisper = .mediumEn
        case (true, 8...):
            whisper = .smallEn
        case (false, 16...):
            // Capable Intel Mac, but no Neural Engine — keep transcription
            // lighter so it stays responsive.
            whisper = .smallEn
        case (_, 8...):
            whisper = .baseEn
        default:
            // 4–6 GB or unknown: smallest everything.
            whisper = .baseEn
        }

        let summary = "\(hardware.shortDescription) → \(whisper.shortName) transcription and \(LlamaModel.recommended(for: hardware).shortName) for summaries."
        return ModelRecommendation(whisperModel: whisper, summary: summary)
    }

    /// Tokens of prompt this Mac can have the model read at once: 16K on 8 GB,
    /// 32K on 16 GB, 64K on 32 GB or more. An Intel Mac, which runs the model
    /// far slower, gets one tier lower. Never below 8K.
    static func contextBudgetTokens(for hardware: HardwareCapabilities) -> Int {
        let tokens: Int
        switch hardware.physicalMemoryGB {
        case 32...: tokens = 65_536
        case 16...: tokens = 32_768
        case 8...: tokens = 16_384
        default: tokens = 8_192
        }
        return hardware.isAppleSilicon ? tokens : max(8_192, tokens / 2)
    }

    static func current() -> ModelRecommendation {
        recommend(for: .current())
    }
}
