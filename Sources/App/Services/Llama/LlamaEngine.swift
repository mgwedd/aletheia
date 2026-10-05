#if canImport(llama)
import Foundation
import llama

/// The real `LocalLLMEngine` — the pinned `ggml-org/llama.cpp` runtime (tag
/// `b11149`, see `project.yml`) driving the seam `LocalLLMEngine.swift`
/// defines, so the rest of the app (grammar-constrained note drafting,
/// swappable LoRA fine-tunes) is built once against a stable contract and
/// gets a working backend the moment this file compiles.
///
/// ⚠️ Staged / needs Mac verification. This whole file sits behind
/// `#if canImport(llama)`, so — like `LlamaAssistant` next to it — it has
/// never been compiled by CI; the package stays commented in `project.yml`
/// until a maintainer runs `scripts/verify-llama-bringup.sh` on a Mac. The
/// C API calls below track `llama.h` exactly as it reads at the pinned
/// commit (fetched and cross-checked line-by-line while writing this, not
/// recalled from memory — the API reshuffled several times across
/// 2024–2025). Re-verify every symbol here before ever re-pinning to a
/// newer revision.
///
/// Threading: deliberately not actor-isolated. `generate`/`stream` run a
/// blocking, potentially multi-second `llama_decode` loop; hopping onto an
/// actor's executor for that would either tie the actor up for the whole
/// generation or force awkward suspension points mid-C-call. Instead, all
/// model/context/adapter access — load, decode, unload — is funneled onto
/// one private serial `DispatchQueue`, so those pointers are only ever
/// touched from that one queue and two generations can never race each
/// other, without pulling Swift concurrency into a C loop that doesn't
/// suspend. Callers still see a normal `async` seam via checked
/// continuations; a stream's cancellation crosses back in through a small
/// lock-guarded flag, the same pattern `LlamaAssistant` next to this file
/// already uses for its own decode loop.
final class LlamaEngine: LocalLLMEngine {
    private let modelURL: URL
    private let adapterURL: URL?
    /// The sampling this engine was constructed with. Every `generate`/
    /// `stream` call carries its own `LocalLLMRequest.sampling`, which is
    /// what actually drives decoding — this value's only job is sizing the
    /// context window at load time (`n_ctx` must be fixed before any
    /// request is seen), so a caller that plans on long completions gets a
    /// context big enough to hold them.
    private let defaultSampling: LocalLLMSampling

    /// Serializes every touch of `model`/`context`/`adapter`: load, decode,
    /// unload. See the threading note on the type.
    private let queue = DispatchQueue(label: "com.aletheia.llamaEngine", qos: .userInitiated)

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var adapter: OpaquePointer?

    private let stateLock = NSLock()
    private var _state: LocalLLMEngineState = .notLoaded

    var state: LocalLLMEngineState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _state
    }

    private func setState(_ newState: LocalLLMEngineState) {
        stateLock.lock()
        _state = newState
        stateLock.unlock()
    }

    /// A plain base model, no adapter.
    init(modelURL: URL, sampling: LocalLLMSampling) {
        self.modelURL = modelURL
        self.adapterURL = nil
        self.defaultSampling = sampling
    }

    /// A base model with an optional LoRA adapter layered on it at load time.
    init(modelURL: URL, adapterURL: URL?, sampling: LocalLLMSampling) {
        self.modelURL = modelURL
        self.adapterURL = adapterURL
        self.defaultSampling = sampling
    }

    /// From a `ModelLoadPlan` — base + optional adapter, already validated
    /// compatible (see `FineTunedModel.swift`) before this is ever built.
    convenience init(plan: ModelLoadPlan, sampling: LocalLLMSampling) {
        self.init(modelURL: plan.baseURL, adapterURL: plan.adapterURL, sampling: sampling)
    }

    deinit {
        // No queue hop needed: nothing else can hold a reference at this
        // point, so there's no concurrent access to serialize against.
        teardownOnQueue()
    }

    // MARK: - LocalLLMEngine

    func load() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else { continuation.resume(); return }
                do {
                    try self.ensureLoadedOnQueue()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func unload() {
        queue.sync {
            teardownOnQueue()
            setState(.notLoaded)
        }
    }

    func generate(_ request: LocalLLMRequest) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: LocalLLMEngineError.generationFailed(
                        "The built-in model engine was deallocated mid-generation."
                    ))
                    return
                }
                do {
                    try self.ensureLoadedOnQueue()
                    let text = try self.decodeOnQueue(request: request, isCancelled: { false }, onToken: nil)
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stream(_ request: LocalLLMRequest) -> AsyncThrowingStream<String, Error> {
        let cancelled = LlamaEngineCancellationFlag()
        return AsyncThrowingStream { continuation in
            // The consumer going away (Stop button, or the Task backing this
            // stream being cancelled) tears the stream down, which fires
            // this — the one signal the decode loop below polls, since it
            // runs on a plain DispatchQueue and has no Task of its own to
            // check `isCancelled` against.
            continuation.onTermination = { _ in cancelled.cancel() }
            queue.async { [weak self] in
                guard let self else { continuation.finish(); return }
                do {
                    try self.ensureLoadedOnQueue()
                    _ = try self.decodeOnQueue(
                        request: request,
                        isCancelled: { cancelled.isCancelled },
                        onToken: { soFar in continuation.yield(soFar) }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Load / unload (queue-confined)

    /// Loads weights (and the adapter, if any) unless already `.ready`.
    /// Must only run on `queue`.
    private func ensureLoadedOnQueue() throws {
        if case .ready = state { return }

        setState(.loading)
        do {
            // llama_backend_init() must run exactly once per process; a
            // `static let` initializer runs at most once even if several
            // engines (or reloads) reach this line, and Swift guarantees
            // that init is thread-safe.
            _ = Self.backendInitialized

            let modelParams = llama_model_default_params()
            guard let loadedModel = llama_model_load_from_file(modelURL.path, modelParams) else {
                throw LocalLLMEngineError.loadFailed(
                    "Couldn't load the built-in model at \(modelURL.lastPathComponent)."
                )
            }
            model = loadedModel

            var contextParams = llama_context_default_params()
            // Size the context to comfortably hold prompt + completion for
            // the sampling this engine was built with, capped at what the
            // model was actually trained on (0 from llama_model_n_ctx_train
            // means "unknown", so don't cap in that case).
            let trainCtx = Int(llama_model_n_ctx_train(loadedModel))
            let desiredCtx = max(2048, defaultSampling.maxTokens * 4)
            contextParams.n_ctx = UInt32(trainCtx > 0 ? min(desiredCtx, trainCtx) : desiredCtx)
            contextParams.n_batch = 512
            let threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount))
            contextParams.n_threads = threads
            contextParams.n_threads_batch = threads

            guard let loadedContext = llama_init_from_model(loadedModel, contextParams) else {
                throw LocalLLMEngineError.loadFailed(
                    "Couldn't create an inference context for the built-in model."
                )
            }
            context = loadedContext

            if let adapterURL {
                guard let loadedAdapter = llama_adapter_lora_init(loadedModel, adapterURL.path) else {
                    throw LocalLLMEngineError.loadFailed(
                        "Couldn't load the LoRA adapter at \(adapterURL.lastPathComponent)."
                    )
                }
                adapter = loadedAdapter

                // llama_set_adapters_lora takes a small array of adapters +
                // per-adapter scales (we apply one, at full strength) and
                // returns non-zero if the context rejected the pairing —
                // fail closed rather than silently generating off the base
                // model with the adapter quietly not applied.
                var adapters: [OpaquePointer?] = [loadedAdapter]
                var scales: [Float] = [1.0]
                let applied = adapters.withUnsafeMutableBufferPointer { adaptersBuffer in
                    scales.withUnsafeMutableBufferPointer { scalesBuffer in
                        llama_set_adapters_lora(
                            loadedContext,
                            adaptersBuffer.baseAddress,
                            adaptersBuffer.count,
                            scalesBuffer.baseAddress
                        )
                    }
                }
                guard applied == 0 else {
                    throw LocalLLMEngineError.loadFailed(
                        "The LoRA adapter at \(adapterURL.lastPathComponent) couldn't be applied "
                            + "to the loaded model (code \(applied))."
                    )
                }
            }

            setState(.ready)
        } catch {
            teardownOnQueue()
            let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            setState(.failed(reason: reason))
            throw error
        }
    }

    /// Frees adapter/context/model in dependency order (an adapter is only
    /// valid while its model is alive; a context references its model too).
    /// Must only run on `queue`.
    private func teardownOnQueue() {
        if let adapter {
            llama_adapter_lora_free(adapter)
        }
        adapter = nil
        if let context {
            llama_free(context)
        }
        context = nil
        if let model {
            llama_model_free(model)
        }
        model = nil
    }

    /// Guards `llama_backend_init()` to exactly one call for the process's
    /// lifetime, regardless of how many `LlamaEngine` instances exist.
    private static let backendInitialized: Void = { llama_backend_init() }()

    // MARK: - Decoding (queue-confined)

    /// Tokenizes `request.composedPrompt`, builds a sampler chain matching
    /// `request.sampling` (and `request.grammar`, if set), then decodes
    /// token-by-token until end-of-generation or `sampling.maxTokens`.
    /// `onToken`, when given, is called with the growing full text after
    /// every token (for `stream`); `generate` passes `nil` and only reads
    /// the return value. Must only run on `queue`.
    private func decodeOnQueue(
        request: LocalLLMRequest,
        isCancelled: () -> Bool,
        onToken: ((String) -> Void)?
    ) throws -> String {
        guard let model, let context else {
            throw LocalLLMEngineError.generationFailed("The built-in model isn't loaded.")
        }
        guard let vocab = llama_model_get_vocab(model) else {
            throw LocalLLMEngineError.generationFailed("The built-in model has no vocabulary.")
        }

        let prompt = request.composedPrompt
        let promptLength = Int32(prompt.utf8.count)

        // First call with a nil buffer reports the token count as a negative
        // number (llama_tokenize's documented "how many would fit" signal);
        // negate it to size the real buffer.
        let needed = -llama_tokenize(vocab, prompt, promptLength, nil, 0, true, true)
        guard needed > 0 else {
            throw LocalLLMEngineError.generationFailed("Couldn't tokenize the prompt.")
        }
        var tokens = [llama_token](repeating: 0, count: Int(needed))
        guard llama_tokenize(vocab, prompt, promptLength, &tokens, needed, true, true) >= 0 else {
            throw LocalLLMEngineError.generationFailed("Couldn't tokenize the prompt.")
        }

        guard let chain = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw LocalLLMEngineError.generationFailed("Couldn't create a sampler chain.")
        }
        defer { llama_sampler_free(chain) }

        // A grammar constrains the logits *before* the terminal sampler picks
        // a token, so it's added first in the chain — the same ordering
        // llama.h's own sampling-API doc comment uses for top_k/top_p ahead
        // of the terminal greedy/dist sampler.
        if let grammar = request.grammar {
            guard let grammarSampler = llama_sampler_init_grammar(vocab, grammar.gbnf, "root") else {
                throw LocalLLMEngineError.generationFailed(
                    "The \"\(grammar.label)\" grammar failed to parse."
                )
            }
            llama_sampler_chain_add(chain, grammarSampler)
        }

        if request.sampling.isGreedy {
            // Clinical notes default to greedy: reproducible output for the
            // same transcript (see LocalLLMSampling.deterministic).
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_temp(Float(request.sampling.temperature)))
            // 0xFFFFFFFF is LLAMA_DEFAULT_SEED (a random seed each call);
            // used verbatim since the macro isn't imported into Swift.
            let seed = request.sampling.seed ?? 0xFFFFFFFF
            llama_sampler_chain_add(chain, llama_sampler_init_dist(seed))
        }

        var output = ""
        let maxTokens = max(1, request.sampling.maxTokens)

        // `llama_batch_get_one` stores the token pointer inside the batch it
        // returns, and that pointer has to stay valid until the *next*
        // `llama_decode`. Swift's inout-to-pointer bridging (`&tokens`,
        // `&next`) only guarantees a pointer for the duration of the single
        // call it's passed to, so pointing a batch at a local and decoding it
        // a loop iteration later would read freed stack memory. Back both the
        // prompt and each subsequent single token with one stable heap buffer
        // the batch can safely reference across iterations.
        let promptCount = tokens.count
        let tokenStore = UnsafeMutablePointer<llama_token>.allocate(capacity: max(promptCount, 1))
        defer { tokenStore.deallocate() }
        tokens.withUnsafeBufferPointer { src in
            tokenStore.update(from: src.baseAddress!, count: promptCount)
        }
        var batch = llama_batch_get_one(tokenStore, Int32(promptCount))

        var produced = 0
        while produced < maxTokens {
            if isCancelled() { break }
            guard llama_decode(context, batch) == 0 else {
                throw LocalLLMEngineError.generationFailed("The model failed to decode a batch.")
            }
            // llama_sampler_sample applies the whole chain (grammar included)
            // to the last token's logits, picks one, and feeds it back to
            // every sampler in the chain (including the grammar's own
            // state) in one call — no separate "accept" step needed.
            let next = llama_sampler_sample(chain, context, -1)
            if llama_vocab_is_eog(vocab, next) { break }
            output += piece(for: next, vocab: vocab)
            onToken?(output)
            // Reuse the same stable storage for the single next token, so the
            // batch keeps pointing at live memory for the decode above on the
            // following iteration.
            tokenStore.pointee = next
            batch = llama_batch_get_one(tokenStore, 1)
            produced += 1
        }
        return output
    }

    /// Detokenizes a single token to its text piece.
    private func piece(for token: llama_token, vocab: OpaquePointer) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        guard count > 0 else { return "" }
        return String(decoding: buffer[0..<Int(count)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// A thread-safe one-way "stop" flag for a single `stream(_:)` call — the
/// same small pattern `LlamaAssistant` uses for its own streaming decode
/// loop, kept private and duplicated here (rather than shared) since each
/// file is independently staged behind `#if canImport(llama)`.
private final class LlamaEngineCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
    func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}
#endif
