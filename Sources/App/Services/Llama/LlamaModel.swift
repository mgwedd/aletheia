import Foundation

/// A downloadable GGUF model for the embedded llama.cpp backend, mirroring
/// `WhisperModel`: chosen sizes, human descriptions, and a download URL.
///
/// Models are refreshed *separately* from the app itself (the design goal):
/// the llama.cpp runtime ships inside the app and updates with it, while these
/// weights are downloaded on demand into Application Support, like the Whisper
/// models. Sizes are approximate (Q4_K_M quantization).
enum LlamaModel: String, CaseIterable, Identifiable, Codable, Hashable {
    case llama32_1b = "llama-3.2-1b-instruct-q4_k_m"
    case llama32_3b = "llama-3.2-3b-instruct-q4_k_m"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .llama32_1b: return "Llama 3.2 1B (Instruct) — fastest, lightest"
        case .llama32_3b: return "Llama 3.2 3B (Instruct) — recommended"
        }
    }

    var shortName: String {
        switch self {
        case .llama32_1b: return "Llama 3.2 1B"
        case .llama32_3b: return "Llama 3.2 3B"
        }
    }

    var approximateSizeMB: Int {
        switch self {
        case .llama32_1b: return 808
        case .llama32_3b: return 2020
        }
    }

    var fileName: String { "\(rawValue).gguf" }

    /// Pinned SHA-256 of the exact GGUF asset, checked by `LlamaModelDownloader`
    /// before a downloaded model is accepted. `nil` means "not pinned yet" — the
    /// download proceeds unverified, which is why the embedded backend stays
    /// staged (see README › Embedded llama.cpp): pinning these is part of the
    /// on-a-Mac bring-up. Hugging Face stores LFS blobs *by* their SHA-256, so
    /// the value can be read from the file's LFS pointer (`oid sha256:…`) without
    /// downloading the whole weight, then confirmed against a real download.
    var expectedSHA256: String? {
        switch self {
        case .llama32_1b: return nil
        case .llama32_3b: return nil
        }
    }

    /// Official GGUF conversions published by ggml-org (the llama.cpp project),
    /// keeping the weights on a first-party source rather than a random mirror.
    /// The exact asset paths must be confirmed on a real Mac during the staged
    /// bring-up (see README › Embedded llama.cpp), and a SHA-256 added here for
    /// integrity before this backend ships enabled.
    var downloadURL: URL {
        switch self {
        case .llama32_1b:
            return URL(string: "https://huggingface.co/ggml-org/Llama-3.2-1B-Instruct-GGUF/resolve/main/llama-3.2-1b-instruct-q4_k_m.gguf")!
        case .llama32_3b:
            return URL(string: "https://huggingface.co/ggml-org/Llama-3.2-3B-Instruct-GGUF/resolve/main/llama-3.2-3b-instruct-q4_k_m.gguf")!
        }
    }
}
