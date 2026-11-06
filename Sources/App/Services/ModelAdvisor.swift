import Foundation

struct ModelRecommendation: Equatable {
    let whisperModel: WhisperModel
    let medGemmaModel: LlamaModel
    /// The AI effort a fresh install starts each feature at.
    let effort: AnswerEffort
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
        default:
            // Intel (whisper.cpp runs on the CPU there, see InferenceCompute),
            // or 4–6 GB: the smallest model keeps a session's transcript
            // within a few times its length.
            whisper = .baseEn
        }
        // Intel runs the AI on the CPU, several times slower than Apple
        // silicon, so a long note or answer starts at one pass.
        let effort: AnswerEffort = hardware.isAppleSilicon ? .default : .fast

        let medGemma = medGemma(for: hardware)
        let summary = "\(hardware.shortDescription) → \(whisper.shortName) transcription and \(LlamaModel.recommended(for: hardware).shortName) for summaries."
        return ModelRecommendation(whisperModel: whisper, medGemmaModel: medGemma, effort: effort, summary: summary)
    }

    /// The curated medical default, the same on every Mac.
    static func medGemma(for hardware: HardwareCapabilities) -> LlamaModel {
        LlamaModel.medGemma(for: hardware)
    }

    /// Memory-based maximum context. The 27B's weights leave less room for a
    /// cache at 32 GB, so its window stays at 32K until 48 GB. Intel runs the
    /// AI on the CPU, where a bigger window makes the first answer minutes
    /// slower, so it stays at 8K whatever its memory. The engine still checks
    /// the real tokenizer and GGUF limit.
    static func contextBudgetTokens(for hardware: HardwareCapabilities, model: LlamaModel? = nil) -> Int {
        let tokens: Int
        switch hardware.physicalMemoryGB {
        case 32...: tokens = 65_536
        case 16...: tokens = 32_768
        case 8...: tokens = 16_384
        default: tokens = 8_192
        }
        let hardwareTokens = hardware.isAppleSilicon ? tokens : 8_192
        guard let model else { return hardwareTokens }
        let modelMemoryCap = model == .medgemma_27b && hardware.physicalMemoryGB < 48 ? 32_768 : hardwareTokens
        return min(hardwareTokens, modelMemoryCap, model.contextWindowTokens)
    }

    static func current() -> ModelRecommendation {
        recommend(for: .current())
    }
}
