import Foundation

struct ModelRecommendation: Equatable {
    let whisperModel: WhisperModel
    /// Ollama model tag recommended for this Mac (used when the LLM backend is
    /// Ollama; the size tier also guides any other local backend).
    let ollamaModel: String
    let summary: String
}

/// Recommends model sizes from the Mac's capabilities, so the user doesn't
/// have to know what "8B" means. Bigger models are more accurate but need
/// more memory and are slower, so the tiers key off RAM (and Apple Silicon,
/// which runs these far faster than Intel).
enum ModelAdvisor {
    static func recommend(for hardware: HardwareCapabilities) -> ModelRecommendation {
        let whisper: WhisperModel
        let ollama: String

        switch (hardware.isAppleSilicon, hardware.physicalMemoryGB) {
        case (true, 16...):
            whisper = .mediumEn
            ollama = "llama3.1:8b"
        case (true, 8...):
            whisper = .smallEn
            ollama = "llama3.2:3b"
        case (false, 16...):
            // Capable Intel Mac, but no Neural Engine — keep transcription
            // lighter so it stays responsive.
            whisper = .smallEn
            ollama = "llama3.1:8b"
        case (_, 8...):
            whisper = .baseEn
            ollama = "llama3.2:3b"
        default:
            // 4–6 GB or unknown: smallest everything.
            whisper = .baseEn
            ollama = "llama3.2:1b"
        }

        let summary = "\(hardware.shortDescription) → \(whisper.shortName) transcription and \(ollama) for summaries."
        return ModelRecommendation(whisperModel: whisper, ollamaModel: ollama, summary: summary)
    }

    static func current() -> ModelRecommendation {
        recommend(for: .current())
    }
}
