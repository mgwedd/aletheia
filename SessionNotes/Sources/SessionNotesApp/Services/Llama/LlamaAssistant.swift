#if canImport(llama)
import Foundation
import llama

/// The embedded local-LLM backend: the official llama.cpp runtime compiled into
/// the app, answering entirely on-device with no server and no external process.
///
/// ⚠️ Staged / needs Mac verification. This whole file is behind
/// `#if canImport(llama)`, so it is only compiled once the pinned `llama.cpp`
/// Swift package is added (see README › Embedded llama.cpp and the commented
/// stanza in `project.yml`). It has therefore NOT been compiled by CI. The C
/// API symbol names and pointer lifetimes below track llama.cpp's public
/// `llama.h` as of the pin; verify them against the exact pinned revision when
/// bringing this up on a Mac, and adjust if the API has shifted.
final class LlamaAssistant: Assistant {
    enum LlamaError: LocalizedError {
        case modelLoadFailed, contextInitFailed, tokenizeFailed, samplerInitFailed, decodeFailed

        var errorDescription: String? { "The built-in model couldn't complete a response." }
    }

    private let modelURL: URL
    private let maxTokens: Int
    private var model: OpaquePointer?

    init(modelURL: URL, maxTokens: Int = 512) {
        self.modelURL = modelURL
        self.maxTokens = maxTokens
    }

    deinit {
        if let model { llama_model_free(model) }
    }

    func isReachable() async -> Bool { FileManager.default.fileExists(atPath: modelURL.path) }
    func listModels() async throws -> [String] { [modelURL.deletingPathExtension().lastPathComponent] }
    func hasModel(_ name: String) async -> Bool { FileManager.default.fileExists(atPath: modelURL.path) }

    /// Weights are fetched by `LlamaModelDownloader`, not here; nothing to pull.
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {
        onProgress(1.0, "ready")
    }

    func generate(model _: String, prompt: String) async throws -> String {
        // Inference is blocking; run it off the calling thread.
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try self.runInference(prompt: prompt)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func ensureModelLoaded() throws {
        guard model == nil else { return }
        llama_backend_init()
        let params = llama_model_default_params()
        guard let loaded = llama_model_load_from_file(modelURL.path, params) else {
            throw LlamaError.modelLoadFailed
        }
        model = loaded
    }

    private func runInference(prompt: String) throws -> String {
        try ensureModelLoaded()
        guard let model else { throw LlamaError.modelLoadFailed }
        let vocab = llama_model_get_vocab(model)

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = 4096
        contextParams.n_batch = 512
        guard let context = llama_init_from_model(model, contextParams) else {
            throw LlamaError.contextInitFailed
        }
        defer { llama_free(context) }

        // Tokenize the prompt (add BOS, parse special tokens).
        let byteCount = Int32(prompt.utf8.count)
        let needed = -llama_tokenize(vocab, prompt, byteCount, nil, 0, true, true)
        guard needed > 0 else { throw LlamaError.tokenizeFailed }
        var tokens = [llama_token](repeating: 0, count: Int(needed))
        guard llama_tokenize(vocab, prompt, byteCount, &tokens, needed, true, true) >= 0 else {
            throw LlamaError.tokenizeFailed
        }

        // Greedy sampler for stable, reproducible clinical summaries.
        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw LlamaError.samplerInitFailed
        }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var output = ""
        var batch = llama_batch_get_one(&tokens, Int32(tokens.count))
        var produced = 0
        while produced < maxTokens {
            guard llama_decode(context, batch) == 0 else { throw LlamaError.decodeFailed }
            var next = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, next) { break }
            output += piece(for: next, vocab: vocab)
            batch = llama_batch_get_one(&next, 1)
            produced += 1
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func piece(for token: llama_token, vocab: OpaquePointer?) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        guard count > 0 else { return "" }
        return String(decoding: buffer[0..<Int(count)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
#endif
