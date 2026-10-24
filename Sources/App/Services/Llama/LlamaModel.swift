import Foundation

/// A downloadable GGUF model for the embedded llama.cpp backend, mirroring
/// `WhisperModel`: chosen sizes, human descriptions, and a download URL.
///
/// Models are refreshed *separately* from the app itself (the design goal):
/// the llama.cpp runtime ships inside the app and updates with it, while these
/// weights are downloaded on demand into Application Support, like the Whisper
/// models. Both are first-party, ungated `ggml-org` (the llama.cpp project)
/// conversions, pinned to an immutable Hugging Face commit and a SHA-256.
enum LlamaModel: String, CaseIterable, Identifiable, Codable, Hashable {
    case llama31_8b = "meta-llama-3.1-8b-instruct-q4_0"
    case gemma4_e2b = "gemma-4-e2b-it-q4_0"

    var id: String { rawValue }

    /// The model offered by default (and used when a persisted raw value is
    /// unknown, e.g. a retired model from an older release): the 8B on 16 GB+
    /// Macs (the same threshold `ModelAdvisor` uses for its 8B tier), otherwise
    /// the lighter Gemma 4 E2B.
    static func recommended(for hardware: HardwareCapabilities) -> LlamaModel {
        hardware.physicalMemoryGB >= 16 ? .llama31_8b : .gemma4_e2b
    }

    var displayName: String {
        switch self {
        case .llama31_8b: return "Llama 3.1 8B (Instruct) — recommended, 16 GB+ Macs"
        case .gemma4_e2b: return "Gemma 4 E2B (Instruct) — lighter, 8 GB Macs"
        }
    }

    var shortName: String {
        switch self {
        case .llama31_8b: return "Llama 3.1 8B"
        case .gemma4_e2b: return "Gemma 4 E2B"
        }
    }

    /// Download size in MB (10^6 bytes), from the Hugging Face LFS size.
    var approximateSizeMB: Int {
        switch self {
        case .llama31_8b: return 6036   // 6,036,116,480 bytes
        case .gemma4_e2b: return 2841   // 2,841,481,184 bytes
        }
    }

    var fileName: String {
        switch self {
        case .llama31_8b: return "meta-llama-3.1-8b-instruct-q4_0.gguf"
        case .gemma4_e2b: return "gemma-4-E2B-it-Q4_0.gguf"
        }
    }

    /// Hugging Face repo (under `ggml-org`) the weights come from.
    private var repo: String {
        switch self {
        case .llama31_8b: return "Meta-Llama-3.1-8B-Instruct-Q4_0-GGUF"
        case .gemma4_e2b: return "gemma-4-E2B-it-GGUF"
        }
    }

    /// Immutable repo commit the download is pinned to, so the bytes can't change
    /// under `expectedSHA256`.
    var revision: String {
        switch self {
        case .llama31_8b: return "0aba27dd2f1c7f4941a94a5c59d80e0a256f9ff8"
        case .gemma4_e2b: return "b4243c156154b6dca9324415f8c7ccc098b4aed1"
        }
    }

    /// SHA-256 of the exact GGUF asset (the file's Hugging Face LFS oid),
    /// verified by `LlamaModelDownloader` before a download is accepted. There is
    /// no unpinned path: a mismatch deletes the file and throws.
    var expectedSHA256: String {
        switch self {
        case .llama31_8b: return "b4778681efbd6898fe1965e74f810b3b7dfdf6afab01df9c88c1b0e6e9ca122d"
        case .gemma4_e2b: return "8e30dff3ac4c8434c49a7036fa15564bdbb6044e42bf04550bf1a096ad7e6a52"
        }
    }

    /// Exact size in bytes of the pinned GGUF asset (its Hugging Face LFS size);
    /// checked on every load so a truncated file is refused without a re-hash.
    var expectedBytes: Int64 {
        switch self {
        case .llama31_8b: return 6_036_116_480
        case .gemma4_e2b: return 2_841_481_184
        }
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggml-org/\(repo)/resolve/\(revision)/\(fileName)")!
    }

    /// The license the weights are offered under, shown before the download.
    var licenseName: String {
        switch self {
        case .llama31_8b: return "Llama 3.1 Community License"
        case .gemma4_e2b: return "Apache License 2.0"
        }
    }

    /// Where that license can be read (opened in the user's browser).
    var licenseURL: URL {
        switch self {
        case .llama31_8b: return URL(string: "https://github.com/meta-llama/llama-models/blob/main/models/llama3_1/LICENSE")!
        case .gemma4_e2b: return URL(string: "https://ai.google.dev/gemma/docs/gemma_4_license")!
        }
    }

    /// Acceptable-use terms the license incorporates, if any.
    var acceptableUseURL: URL? {
        switch self {
        case .llama31_8b: return URL(string: "https://github.com/meta-llama/llama-models/blob/main/models/llama3_1/USE_POLICY.md")!
        case .gemma4_e2b: return nil
        }
    }

    /// Attribution the license asks for wherever the model is named.
    var attribution: String? {
        switch self {
        case .llama31_8b: return "Built with Llama"
        case .gemma4_e2b: return nil
        }
    }
}

enum LlamaModelFile {
    /// Cheap load-time check that the stored model is the pinned size
    /// (the counterpart of `WhisperModelFile.verifySize`).
    static func verifySize(at url: URL, expectedBytes: Int64) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let actual = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard actual == expectedBytes else {
            throw LocalLLMEngineError.loadFailed(
                "The AI model file is damaged or incomplete. Open Settings › AI and models and download it again."
            )
        }
    }
}
