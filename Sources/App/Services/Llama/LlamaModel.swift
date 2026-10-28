import Foundation

/// A downloadable GGUF model for the embedded llama.cpp backend, mirroring
/// `WhisperModel`: chosen sizes, human descriptions, and a download URL.
///
/// Models are refreshed *separately* from the app itself (the design goal):
/// the llama.cpp runtime ships inside the app and updates with it, while these
/// weights are downloaded on demand into Application Support, like the Whisper
/// models. Each is pinned to an immutable Hugging Face commit and a SHA-256.
enum LlamaModel: String, CaseIterable, Identifiable, Codable, Hashable {
    case llama31_8b = "meta-llama-3.1-8b-instruct-q4_0"
    case gemma4_e2b = "gemma-4-e2b-it-q4_0"
    case medllama2_7b = "medllama-2-7b-q4_k_s"
    case medgemma_4b = "medgemma-4b-it-q4_k_m"
    case medgemma_27b = "medgemma-27b-text-it-q4_k_m"

    var id: String { rawValue }

    /// The model offered by default (and used when a persisted raw value is
    /// unknown, e.g. a retired model from an older release): the 8B on 16 GB+
    /// Macs (the same threshold `ModelAdvisor` uses for its 8B tier), otherwise
    /// the lighter Gemma 4 E2B.
    static func recommended(for hardware: HardwareCapabilities) -> LlamaModel {
        hardware.physicalMemoryGB >= 16 ? .llama31_8b : .gemma4_e2b
    }

    /// The MedGemma variant that fits `hardware`: 27B (~16.5 GB) on 32 GB+
    /// Macs where the weights and context fit in memory, otherwise 4B (~2.5 GB).
    static func medGemma(for hardware: HardwareCapabilities) -> LlamaModel {
        hardware.physicalMemoryGB >= 32 ? .medgemma_27b : .medgemma_4b
    }

    /// Models offered in Settings for `hardware`: the general-purpose models,
    /// MedLlama 2, and the MedGemma size that fits this Mac's memory.
    static func offered(for hardware: HardwareCapabilities, including current: LlamaModel? = nil) -> [LlamaModel] {
        var models: [LlamaModel] = [.llama31_8b, .gemma4_e2b, .medllama2_7b, medGemma(for: hardware)]
        if let current, !models.contains(current) {
            models.append(current)
        }
        return models
    }

    var displayName: String {
        switch self {
        case .llama31_8b: return "Llama 3.1 8B (Instruct) — recommended, 16 GB+ Macs"
        case .gemma4_e2b: return "Gemma 4 E2B (Instruct) — lighter, 8 GB Macs"
        case .medllama2_7b: return "MedLlama 2 7B — medical, 8 GB+ Macs"
        case .medgemma_4b: return "MedGemma 4B (Instruct) — medical, 8 GB+ Macs"
        case .medgemma_27b: return "MedGemma 27B (Instruct) — medical, 32 GB+ Macs"
        }
    }

    var shortName: String {
        switch self {
        case .llama31_8b: return "Llama 3.1 8B"
        case .gemma4_e2b: return "Gemma 4 E2B"
        case .medllama2_7b: return "MedLlama 2 7B"
        case .medgemma_4b: return "MedGemma 4B"
        case .medgemma_27b: return "MedGemma 27B"
        }
    }

    /// Download size in MB (10^6 bytes), from the Hugging Face LFS size.
    var approximateSizeMB: Int {
        switch self {
        case .llama31_8b: return 6036     // 6,036,116,480 bytes
        case .gemma4_e2b: return 2841     // 2,841,481,184 bytes
        case .medllama2_7b: return 3857   // 3,856,740,032 bytes
        case .medgemma_4b: return 2490    // 2,489,894,720 bytes
        case .medgemma_27b: return 16546  // 16,546,405,376 bytes
        }
    }

    /// Context window (in tokens) the model was trained for (`n_ctx_train` in
    /// the GGUF header): 4K for Llama 2-based MedLlama 2, 128K for the others.
    var contextWindowTokens: Int {
        switch self {
        case .llama31_8b: return 131_072
        case .gemma4_e2b: return 131_072
        case .medllama2_7b: return 4_096
        case .medgemma_4b: return 131_072
        case .medgemma_27b: return 131_072
        }
    }

    var fileName: String {
        switch self {
        case .llama31_8b: return "meta-llama-3.1-8b-instruct-q4_0.gguf"
        case .gemma4_e2b: return "gemma-4-E2B-it-Q4_0.gguf"
        case .medllama2_7b: return "MedLlama-2-7B.q4_K_S.gguf"
        case .medgemma_4b: return "medgemma-4b-it-Q4_K_M.gguf"
        case .medgemma_27b: return "medgemma-27b-text-it-Q4_K_M.gguf"
        }
    }

    /// Hugging Face `<owner>/<repo>` the weights come from.
    private var repo: String {
        switch self {
        case .llama31_8b: return "ggml-org/Meta-Llama-3.1-8B-Instruct-Q4_0-GGUF"
        case .gemma4_e2b: return "ggml-org/gemma-4-E2B-it-GGUF"
        case .medllama2_7b: return "garcianacho/MedLlama-2-7B-GGUF"
        case .medgemma_4b: return "unsloth/medgemma-4b-it-GGUF"
        case .medgemma_27b: return "unsloth/medgemma-27b-text-it-GGUF"
        }
    }

    /// Immutable repo commit the download is pinned to, so the bytes can't change
    /// under `expectedSHA256`.
    var revision: String {
        switch self {
        case .llama31_8b: return "0aba27dd2f1c7f4941a94a5c59d80e0a256f9ff8"
        case .gemma4_e2b: return "b4243c156154b6dca9324415f8c7ccc098b4aed1"
        case .medllama2_7b: return "d2790389ba379e2d3d8ed8912c6849b168414100"
        case .medgemma_4b: return "fa17ea2647ef236db91adfe1465a61ab6562cf2c"
        case .medgemma_27b: return "334fbf6811c963d223f6ac107a459347353f068d"
        }
    }

    /// SHA-256 of the exact GGUF asset (the file's Hugging Face LFS oid),
    /// verified by `LlamaModelDownloader` before a download is accepted. There is
    /// no unpinned path: a mismatch deletes the file and throws.
    var expectedSHA256: String {
        switch self {
        case .llama31_8b: return "b4778681efbd6898fe1965e74f810b3b7dfdf6afab01df9c88c1b0e6e9ca122d"
        case .gemma4_e2b: return "8e30dff3ac4c8434c49a7036fa15564bdbb6044e42bf04550bf1a096ad7e6a52"
        case .medllama2_7b: return "b4596079c3ba3e374677aa56029a96a8274a36db1e4dc273cfaf08344e57d733"
        case .medgemma_4b: return "d842e8d2aca3fc5e613c5f9255e693768eeccae729e5c2653159eb79afe751f3"
        case .medgemma_27b: return "383b1c414d3f2f1a9c577a61e623d29a4ed4f7834f60b9e5412f5ff4e8aaf080"
        }
    }

    /// Exact size in bytes of the pinned GGUF asset (its Hugging Face LFS size);
    /// checked on every load so a truncated file is refused without a re-hash.
    var expectedBytes: Int64 {
        switch self {
        case .llama31_8b: return 6_036_116_480
        case .gemma4_e2b: return 2_841_481_184
        case .medllama2_7b: return 3_856_740_032
        case .medgemma_4b: return 2_489_894_720
        case .medgemma_27b: return 16_546_405_376
        }
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(fileName)")!
    }

    /// The license the weights are offered under, shown before the download.
    var licenseName: String {
        switch self {
        case .llama31_8b: return "Llama 3.1 Community License"
        case .gemma4_e2b: return "Apache License 2.0"
        case .medllama2_7b: return "Llama 2 Community License"
        case .medgemma_4b, .medgemma_27b: return "Health AI Developer Foundations Terms"
        }
    }

    /// Where that license can be read (opened in the user's browser).
    var licenseURL: URL {
        switch self {
        case .llama31_8b: return URL(string: "https://github.com/meta-llama/llama-models/blob/main/models/llama3_1/LICENSE")!
        case .gemma4_e2b: return URL(string: "https://ai.google.dev/gemma/docs/gemma_4_license")!
        case .medllama2_7b: return URL(string: "https://github.com/meta-llama/llama-models/blob/main/models/llama2/LICENSE")!
        case .medgemma_4b, .medgemma_27b: return URL(string: "https://developers.google.com/health-ai-developer-foundations/terms")!
        }
    }

    /// Acceptable-use terms the license incorporates, if any.
    var acceptableUseURL: URL? {
        switch self {
        case .llama31_8b: return URL(string: "https://github.com/meta-llama/llama-models/blob/main/models/llama3_1/USE_POLICY.md")!
        case .gemma4_e2b: return nil
        case .medllama2_7b: return URL(string: "https://github.com/meta-llama/llama-models/blob/main/models/llama2/USE_POLICY.md")!
        case .medgemma_4b, .medgemma_27b: return URL(string: "https://developers.google.com/health-ai-developer-foundations/prohibited-use-policy")!
        }
    }

    /// Attribution the license asks for wherever the model is named.
    var attribution: String? {
        switch self {
        case .llama31_8b: return "Built with Llama"
        case .gemma4_e2b, .medllama2_7b, .medgemma_4b, .medgemma_27b: return nil
        }
    }
}

enum LlamaModelFile {
    /// Cheap load-time check that the stored model is the pinned size
    /// (the counterpart of `WhisperModelFile.verifySize`).
    static func verifySize(at url: URL, expectedBytes: Int64) throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            throw LocalLLMEngineError.modelNotDownloaded
        }
        let actual = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard actual == expectedBytes else {
            throw LocalLLMEngineError.loadFailed(
                "The AI model file is damaged or incomplete. Open Settings › AI and models and download it again."
            )
        }
    }
}
