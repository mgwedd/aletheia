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
    case medgemma15_4b = "medgemma-1.5-4b-it-q4_k_m"
    case medgemma_27b = "medgemma-27b-text-it-q4_k_m"
    case apertus8b_meditronFO = "apertus-8b-meditronfo-q4_k_m"

    var id: String { rawValue }

    /// The model offered by default (and used when a persisted raw value is
    /// unknown or retired): medical 4B on most Macs, 27B on Apple silicon
    /// with enough memory for the weights and a useful working context.
    static func recommended(for hardware: HardwareCapabilities) -> LlamaModel {
        hardware.isAppleSilicon && hardware.physicalMemoryGB >= 48 ? .medgemma_27b : .medgemma15_4b
    }

    /// The model an earlier version picked for a user who never chose one
    /// (Llama 3.1 8B from 16 GB, else Gemma 4 E2B), when it is downloaded and
    /// this Mac's default is not.
    static func previousDefault(on hardware: HardwareCapabilities, isDownloaded: (LlamaModel) -> Bool) -> LlamaModel? {
        guard !isDownloaded(recommended(for: hardware)) else { return nil }
        let previous: [LlamaModel] = hardware.physicalMemoryGB >= 16 ? [.llama31_8b, .gemma4_e2b] : [.gemma4_e2b, .llama31_8b]
        return previous.first { $0.isSupported(on: hardware) && isDownloaded($0) }
    }

    /// The default medical model for this Mac.
    static func medGemma(for hardware: HardwareCapabilities) -> LlamaModel {
        recommended(for: hardware)
    }

    func isSupported(on hardware: HardwareCapabilities) -> Bool {
        switch self {
        case .medgemma_27b:
            return hardware.isAppleSilicon && hardware.physicalMemoryGB >= 32
        case .apertus8b_meditronFO:
            return hardware.physicalMemoryGB >= 16
        default:
            return true
        }
    }

    /// The curated medical models. An explicitly selected legacy general model
    /// remains selectable, so an upgrade does not silently change that choice.
    static func offered(for hardware: HardwareCapabilities, including current: LlamaModel? = nil) -> [LlamaModel] {
        var models: [LlamaModel] = [.medgemma15_4b]
        if LlamaModel.apertus8b_meditronFO.isSupported(on: hardware) { models.append(.apertus8b_meditronFO) }
        if LlamaModel.medgemma_27b.isSupported(on: hardware) { models.append(.medgemma_27b) }
        if let current, !models.contains(current), (current == .llama31_8b || current == .gemma4_e2b) {
            models.append(current)
        }
        return models
    }

    var displayName: String {
        switch self {
        case .llama31_8b: return "Llama 3.1 8B (Instruct) — previous selection"
        case .gemma4_e2b: return "Gemma 4 E2B (Instruct) — previous selection"
        case .medgemma15_4b: return "MedGemma 1.5 4B — default for supported Macs"
        case .medgemma_27b: return "MedGemma 27B text — higher quality, 32 GB+ Apple silicon"
        case .apertus8b_meditronFO: return "Apertus 8B MeditronFO — Experimental, 16 GB+ Macs"
        }
    }

    var shortName: String {
        switch self {
        case .llama31_8b: return "Llama 3.1 8B"
        case .gemma4_e2b: return "Gemma 4 E2B"
        case .medgemma15_4b: return "MedGemma 1.5 4B"
        case .medgemma_27b: return "MedGemma 27B text"
        case .apertus8b_meditronFO: return "Apertus 8B MeditronFO"
        }
    }

    /// Download size in MB (10^6 bytes), from the Hugging Face LFS size.
    var approximateSizeMB: Int {
        switch self {
        case .llama31_8b: return 6036     // 6,036,116,480 bytes
        case .gemma4_e2b: return 2841     // 2,841,481,184 bytes
        case .medgemma15_4b: return 2490  // 2,489,894,976 bytes
        case .medgemma_27b: return 16546  // 16,546,405,376 bytes
        case .apertus8b_meditronFO: return 5058 // 5,057,886,624 bytes
        }
    }

    /// Maximum context configured by the app for the model. The actual prompt
    /// budget can be lower on Macs with less memory.
    var contextWindowTokens: Int {
        switch self {
        case .llama31_8b: return 131_072
        case .gemma4_e2b: return 131_072
        case .medgemma15_4b: return 131_072
        case .medgemma_27b: return 131_072
        case .apertus8b_meditronFO: return 65_536
        }
    }

    var fileName: String {
        switch self {
        case .llama31_8b: return "meta-llama-3.1-8b-instruct-q4_0.gguf"
        case .gemma4_e2b: return "gemma-4-E2B-it-Q4_0.gguf"
        case .medgemma15_4b: return "medgemma-1.5-4b-it-Q4_K_M.gguf"
        case .medgemma_27b: return "medgemma-27b-text-it-Q4_K_M.gguf"
        case .apertus8b_meditronFO: return "Apertus-8B-MeditronFO.Q4_K_M.gguf"
        }
    }

    /// Hugging Face `<owner>/<repo>` the weights come from.
    private var repo: String {
        switch self {
        case .llama31_8b: return "ggml-org/Meta-Llama-3.1-8B-Instruct-Q4_0-GGUF"
        case .gemma4_e2b: return "ggml-org/gemma-4-E2B-it-GGUF"
        case .medgemma15_4b: return "unsloth/medgemma-1.5-4b-it-GGUF"
        case .medgemma_27b: return "unsloth/medgemma-27b-text-it-GGUF"
        case .apertus8b_meditronFO: return "mradermacher/Apertus-8B-MeditronFO-GGUF"
        }
    }

    /// Immutable repo commit the download is pinned to, so the bytes can't change
    /// under `expectedSHA256`.
    var revision: String {
        switch self {
        case .llama31_8b: return "0aba27dd2f1c7f4941a94a5c59d80e0a256f9ff8"
        case .gemma4_e2b: return "b4243c156154b6dca9324415f8c7ccc098b4aed1"
        case .medgemma15_4b: return "3855f948626b7ae42bccd082757f15078c53e758"
        case .medgemma_27b: return "334fbf6811c963d223f6ac107a459347353f068d"
        case .apertus8b_meditronFO: return "8a227f00a1c2e0471f7f4237dac01b9107eecc51"
        }
    }

    /// SHA-256 of the exact GGUF asset (the file's Hugging Face LFS oid),
    /// verified by `LlamaModelDownloader` before a download is accepted. There is
    /// no unpinned path: a mismatch deletes the file and throws.
    var expectedSHA256: String {
        switch self {
        case .llama31_8b: return "b4778681efbd6898fe1965e74f810b3b7dfdf6afab01df9c88c1b0e6e9ca122d"
        case .gemma4_e2b: return "8e30dff3ac4c8434c49a7036fa15564bdbb6044e42bf04550bf1a096ad7e6a52"
        case .medgemma15_4b: return "b31becdf4f39561800505514cce67681604fe449d04dd35c8c92fd7848c6d7bd"
        case .medgemma_27b: return "383b1c414d3f2f1a9c577a61e623d29a4ed4f7834f60b9e5412f5ff4e8aaf080"
        case .apertus8b_meditronFO: return "97b145fd6a5d5226dfad93a272b638a581d0f7e9e34d33bca02509c2d16a95ef"
        }
    }

    /// Exact size in bytes of the pinned GGUF asset (its Hugging Face LFS size);
    /// checked on every load so a truncated file is refused without a re-hash.
    var expectedBytes: Int64 {
        switch self {
        case .llama31_8b: return 6_036_116_480
        case .gemma4_e2b: return 2_841_481_184
        case .medgemma15_4b: return 2_489_894_976
        case .medgemma_27b: return 16_546_405_376
        case .apertus8b_meditronFO: return 5_057_886_624
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
        case .medgemma15_4b, .medgemma_27b: return "Health AI Developer Foundations Terms"
        case .apertus8b_meditronFO: return "Apache License 2.0"
        }
    }

    /// Where that license can be read (opened in the user's browser).
    var licenseURL: URL {
        switch self {
        case .llama31_8b: return URL(string: "https://github.com/meta-llama/llama-models/blob/main/models/llama3_1/LICENSE")!
        case .gemma4_e2b: return URL(string: "https://ai.google.dev/gemma/docs/gemma_4_license")!
        case .medgemma15_4b, .medgemma_27b: return URL(string: "https://developers.google.com/health-ai-developer-foundations/terms")!
        case .apertus8b_meditronFO: return URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!
        }
    }

    /// Acceptable-use terms the license incorporates, if any.
    var acceptableUseURL: URL? {
        switch self {
        case .llama31_8b: return URL(string: "https://github.com/meta-llama/llama-models/blob/main/models/llama3_1/USE_POLICY.md")!
        case .gemma4_e2b: return nil
        case .medgemma15_4b, .medgemma_27b: return URL(string: "https://developers.google.com/health-ai-developer-foundations/prohibited-use-policy")!
        case .apertus8b_meditronFO: return nil
        }
    }

    /// Attribution the license asks for wherever the model is named.
    var attribution: String? {
        switch self {
        case .llama31_8b: return "Built with Llama"
        case .gemma4_e2b, .medgemma15_4b, .medgemma_27b, .apertus8b_meditronFO: return nil
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
