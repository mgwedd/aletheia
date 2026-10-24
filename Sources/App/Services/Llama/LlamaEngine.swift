#if canImport(llama)
import Foundation
import llama

/// The real `LocalLLMEngine` — the pinned `ggml-org/llama.cpp` runtime (tag
/// `b11149`, see `project.yml`) driving the seam `LocalLLMEngine.swift`
/// defines, so the rest of the app (grammar-constrained note drafting,
/// swappable LoRA fine-tunes) is built once against a stable contract and
/// gets a working backend the moment this file compiles.
///
/// The C API calls below are compiled against the `llama.h` shipped in the
/// pinned XCFramework (`Packages/LlamaCpp`). The API reshuffles often, so
/// re-verify every symbol here when re-pinning to a newer build.
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
///
/// `@unchecked Sendable` rests on that split: the pointers are confined to
/// `queue`, and every other mutable property goes through `stateLock`.
final class LlamaEngine: LocalLLMEngine, @unchecked Sendable {
    private let modelURL: URL
    private let adapterURL: URL?
    /// The pinned size of `modelURL`, checked before the weights are loaded.
    /// `nil` skips the check (tests, files with no pin).
    private let expectedModelBytes: Int64?
    /// Loads the weights; replaceable so tests can stop short of the real load.
    private let modelLoader: (URL) -> OpaquePointer?
    /// The sampling this engine was constructed with. Every `generate`/
    /// `stream` call carries its own `LocalLLMRequest.sampling`, which is
    /// what actually drives decoding — this value only sizes the context
    /// `load()` warms up. A request's own prompt and reply size the window
    /// it actually runs in (`contextOnQueue`).
    private let defaultSampling: LocalLLMSampling
    /// What this Mac can read at once; caps the context window.
    private let budget: ContextBudget
    /// The current context's `n_ctx`; it only grows (see `contextOnQueue`).
    /// Written on `queue`, read from anywhere, so both go through `stateLock`.
    private(set) var contextTokens: Int {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _contextTokens }
        set { stateLock.lock(); _contextTokens = newValue; stateLock.unlock() }
    }
    /// The last request's prompt size in tokens (for tests and diagnostics).
    private(set) var lastPromptTokens: Int {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _lastPromptTokens }
        set { stateLock.lock(); _lastPromptTokens = newValue; stateLock.unlock() }
    }
    /// The last completed generation's run stats (for tests and diagnostics).
    private(set) var lastStats: AIRunStats? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _lastStats }
        set { stateLock.lock(); _lastStats = newValue; stateLock.unlock() }
    }
    private var _contextTokens = 0
    private var _lastPromptTokens = 0
    private var _lastStats: AIRunStats?

    /// How long the model may sit unused before it is unloaded (the keep-alive window).
    /// Tests shorten it; the idle timer reads it off the main thread.
    var idleDelay: TimeInterval {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _idleDelay }
        set { stateLock.lock(); _idleDelay = newValue; stateLock.unlock() }
    }
    private var _idleDelay: TimeInterval = 30 * 60
    private var idleGeneration = 0
    /// How many idle unloads have fired (for tests). Counted under `stateLock`.
    var idleUnloads: Int { stateLock.lock(); defer { stateLock.unlock() }; return _idleUnloads }
    private var _idleUnloads = 0

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
    init(modelURL: URL, sampling: LocalLLMSampling, budget: ContextBudget = .current) {
        self.modelURL = modelURL
        self.adapterURL = nil
        self.expectedModelBytes = nil
        self.modelLoader = Self.loadModelFromFile
        self.defaultSampling = sampling
        self.budget = budget
    }

    /// A base model with an optional LoRA adapter layered on it at load time.
    init(
        modelURL: URL,
        adapterURL: URL?,
        expectedModelBytes: Int64? = nil,
        sampling: LocalLLMSampling,
        budget: ContextBudget = .current,
        modelLoader: @escaping (URL) -> OpaquePointer? = LlamaEngine.loadModelFromFile
    ) {
        self.modelURL = modelURL
        self.adapterURL = adapterURL
        self.expectedModelBytes = expectedModelBytes
        self.modelLoader = modelLoader
        self.defaultSampling = sampling
        self.budget = budget
    }

    /// From a `ModelLoadPlan` — base + optional adapter, already validated
    /// compatible (see `FineTunedModel.swift`) before this is ever built.
    convenience init(plan: ModelLoadPlan, sampling: LocalLLMSampling) {
        self.init(modelURL: plan.baseURL, adapterURL: plan.adapterURL, expectedModelBytes: plan.base.expectedBytes, sampling: sampling)
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
                    // Warm the floor-size context too, so the first request skips it.
                    // Clamped so a small budget can't make the warm-up throw ContextBudgetError.
                    _ = try self.contextOnQueue(
                        promptTokens: 0, replyTokens: min(self.defaultSampling.maxTokens, self.budget.tokens))
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Marks the engine in use: cancels any pending idle unload. Call when a
    /// request is submitted.
    func markActive() {
        stateLock.lock()
        idleGeneration += 1
        stateLock.unlock()
    }

    /// Unloads after `idleDelay` unless a request is submitted first.
    /// Call when a request finishes.
    func scheduleIdleUnload() {
        stateLock.lock()
        idleGeneration += 1
        let generation = idleGeneration
        stateLock.unlock()
        // ponytail: one timer per finished request, each a cheap no-op once superseded; fine at this request rate.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + idleDelay) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let stale = self.idleGeneration != generation
            if !stale { self._idleUnloads += 1 }
            self.stateLock.unlock()
            if !stale { self.unload() }
        }
    }

    func unload() {
        queue.sync {
            teardownOnQueue()
            setState(.notLoaded)
        }
    }

    func generate(_ request: LocalLLMRequest) async throws -> String {
        let cancelled = LlamaEngineCancellationFlag()
        markActive()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                queue.async { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: LocalLLMEngineError.generationFailed(
                            "The built-in model engine was deallocated mid-generation."
                        ))
                        return
                    }
                    defer { self.scheduleIdleUnload() }
                    do {
                        if cancelled.isCancelled { throw CancellationError() }
                        try self.ensureLoadedOnQueue()
                        if cancelled.isCancelled { throw CancellationError() }
                        let text = try self.decodeOnQueue(
                            request: request,
                            isCancelled: { cancelled.isCancelled },
                            onToken: nil,
                            onStats: nil
                        )
                        if cancelled.isCancelled { throw CancellationError() }
                        continuation.resume(returning: text)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelled.cancel()
        }
    }

    func stream(_ request: LocalLLMRequest) -> AsyncThrowingStream<String, Error> {
        stream(request, onStats: nil)
    }

    func stream(
        _ request: LocalLLMRequest,
        onStats: (@Sendable (AIRunStats) -> Void)?
    ) -> AsyncThrowingStream<String, Error> {
        let cancelled = LlamaEngineCancellationFlag()
        markActive()
        return AsyncThrowingStream { continuation in
            // The consumer going away (Stop button, or the Task backing this
            // stream being cancelled) tears the stream down, which fires
            // this — the one signal the decode loop below polls, since it
            // runs on a plain DispatchQueue and has no Task of its own to
            // check `isCancelled` against.
            continuation.onTermination = { _ in cancelled.cancel() }
            queue.async { [weak self] in
                guard let self else { continuation.finish(); return }
                defer { self.scheduleIdleUnload() }
                do {
                    try self.ensureLoadedOnQueue()
                    _ = try self.decodeOnQueue(
                        request: request,
                        isCancelled: { cancelled.isCancelled },
                        onToken: { soFar in continuation.yield(soFar) },
                        onStats: onStats
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Load / unload (queue-confined)

    static let loadModelFromFile: (URL) -> OpaquePointer? = { url in
        llama_model_load_from_file(url.path, llama_model_default_params())
    }

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

            if let expectedModelBytes {
                try LlamaModelFile.verifySize(at: modelURL, expectedBytes: expectedModelBytes)
            }

            guard let loadedModel = modelLoader(modelURL) else {
                throw LocalLLMEngineError.loadFailed(
                    "Couldn't load the built-in model at \(modelURL.lastPathComponent)."
                )
            }
            model = loadedModel

            if let adapterURL {
                guard let loadedAdapter = llama_adapter_lora_init(loadedModel, adapterURL.path) else {
                    throw LocalLLMEngineError.loadFailed(
                        "Couldn't load the LoRA adapter at \(adapterURL.lastPathComponent)."
                    )
                }
                adapter = loadedAdapter
            }

            setState(.ready)
        } catch {
            teardownOnQueue()
            let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            setState(.failed(reason: reason))
            throw error
        }
    }

    /// The context for a prompt of `promptTokens` plus `replyTokens`, created or
    /// rebuilt only when the stable window it needs is bigger than the current
    /// one (the loaded model is kept; the KV cache is the cost of a bigger
    /// window). Throws `ContextBudgetError` when the prompt can't fit. Must
    /// only run on `queue`.
    private func contextOnQueue(promptTokens: Int, replyTokens: Int) throws -> OpaquePointer {
        guard let model else {
            throw LocalLLMEngineError.generationFailed("The built-in model isn't loaded.")
        }
        let target = try LlamaContextSize.contextTokens(
            promptTokens: promptTokens, replyTokens: replyTokens,
            trainContext: Int(llama_model_n_ctx_train(model)), budget: budget)
        if let context, contextTokens >= target { return context }

        if let context { llama_free(context) }
        context = nil
        contextTokens = 0

        // Flash attention and a q8_0 KV cache halve the cache's memory (the
        // limit on a long session) and speed up long-context attention; the
        // quantized V cache needs flash attention. A model or backend that
        // can't do that falls back to the library defaults rather than failing.
        var params = llama_context_default_params()
        params.n_ctx = UInt32(target)
        // n_batch is the most tokens one llama_decode takes (the prefill loop
        // feeds the prompt in chunks of it); a big ubatch speeds up prefill
        // on the GPU. 2048 keeps the compute buffer modest.
        params.n_batch = 2048
        params.n_ubatch = 2048
        // The GPU does the work; extra CPU threads (and the efficiency cores)
        // only add sync overhead, so use at most half the cores, up to 8.
        let threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount / 2)))
        params.n_threads = threads
        params.n_threads_batch = threads
        var fast = params
        fast.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        fast.type_k = GGML_TYPE_Q8_0
        fast.type_v = GGML_TYPE_Q8_0
        guard let created = llama_init_from_model(model, fast) ?? llama_init_from_model(model, params) else {
            throw LocalLLMEngineError.outOfMemory
        }

        if let adapter {
            // llama_set_adapters_lora takes a small array of adapters +
            // per-adapter scales (we apply one, at full strength) and
            // returns non-zero if the context rejected the pairing —
            // fail closed rather than silently generating off the base
            // model with the adapter quietly not applied.
            var adapters: [OpaquePointer?] = [adapter]
            var scales: [Float] = [1.0]
            let applied = adapters.withUnsafeMutableBufferPointer { adaptersBuffer in
                scales.withUnsafeMutableBufferPointer { scalesBuffer in
                    llama_set_adapters_lora(created, adaptersBuffer.baseAddress, adaptersBuffer.count, scalesBuffer.baseAddress)
                }
            }
            guard applied == 0 else {
                llama_free(created)
                throw LocalLLMEngineError.loadFailed(
                    "The LoRA adapter couldn't be applied to the loaded model (code \(applied))."
                )
            }
        }
        context = created
        contextTokens = target
        return created
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
        contextTokens = 0
        if let model {
            llama_model_free(model)
        }
        model = nil
    }

    /// Guards `llama_backend_init()` to exactly one call for the process's
    /// lifetime, regardless of how many `LlamaEngine` instances exist.
    private static let backendInitialized: Void = { llama_backend_init() }()

    // MARK: - Decoding (queue-confined)

    /// Tokenizes the request (through the model's chat template), builds a sampler chain matching
    /// `request.sampling` (and `request.grammar`, if set), then decodes
    /// token-by-token until end-of-generation or `sampling.maxTokens`.
    /// `onToken`, when given, is called with the growing full text after
    /// every token (for `stream`); `generate` passes `nil` and only reads
    /// the return value. Must only run on `queue`.
    private func decodeOnQueue(
        request: LocalLLMRequest,
        isCancelled: () -> Bool,
        onToken: ((String) -> Void)?,
        onStats: (@Sendable (AIRunStats) -> Void)?
    ) throws -> String {
        guard let model else {
            throw LocalLLMEngineError.generationFailed("The built-in model isn't loaded.")
        }
        guard let vocab = llama_model_get_vocab(model) else {
            throw LocalLLMEngineError.generationFailed("The built-in model has no vocabulary.")
        }

        guard let tokens = LlamaPrompt.tokens(
            model: model, vocab: vocab, system: request.system, turns: request.turns, prompt: request.prompt
        ), !tokens.isEmpty else {
            throw LocalLLMEngineError.generationFailed("Couldn't tokenize the prompt.")
        }

        lastPromptTokens = tokens.count
        // Sized from the real prompt; throws ContextBudgetError rather than cutting it.
        let context = try contextOnQueue(promptTokens: tokens.count, replyTokens: request.sampling.maxTokens)
        // Every request starts from an empty cache (the context is reused).
        llama_memory_clear(llama_get_memory(context), true)

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

        // Apply top-k before repeat penalties when sampling so the penalty pass
        // only scans the top candidates instead of a 128k–256k vocabulary (see
        // llama.h's note on llama_sampler_init_penalties). Grammar still runs
        // first above so top-k only keeps grammar-valid tokens.
        if !request.sampling.isGreedy, let topK = llama_sampler_init_top_k(40) {
            llama_sampler_chain_add(chain, topK)
        }

        // Apply repeat penalty when enabled (> 1.0) so 3B/8B models don't get
        // stuck repeating bullet items on clinical notes and digests.
        if request.sampling.repeatPenalty > 1.0 && request.sampling.repeatLastN > 0 {
            if let penalties = llama_sampler_init_penalties(
                llama_vocab_n_tokens(vocab),
                Int32(request.sampling.repeatLastN),
                Float(request.sampling.repeatPenalty),
                0.0,
                0.0
            ) {
                llama_sampler_chain_add(chain, penalties)
            }
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
        let readStart = DispatchTime.now().uptimeNanoseconds
        var readEnd: UInt64?
        // llama_decode takes at most n_batch tokens: feed the prompt in chunks,
        // keeping the last one for the loop below, which samples from it.
        let chunk = Int(llama_n_batch(context))
        var offset = 0
        while promptCount - offset > chunk {
            if isCancelled() { return output }
            guard llama_decode(context, llama_batch_get_one(tokenStore + offset, Int32(chunk))) == 0 else {
                throw LocalLLMEngineError.generationFailed("The model failed to decode a batch.")
            }
            offset += chunk
        }
        var batch = llama_batch_get_one(tokenStore + offset, Int32(promptCount - offset))

        var produced = 0
        while produced < maxTokens {
            if isCancelled() { break }
            guard llama_decode(context, batch) == 0 else {
                throw LocalLLMEngineError.generationFailed("The model failed to decode a batch.")
            }
            if readEnd == nil {
                readEnd = DispatchTime.now().uptimeNanoseconds
            }
            // llama_sampler_sample applies the whole chain (grammar included)
            // to the last token's logits, picks one, and feeds it back to
            // every sampler in the chain (including the grammar's own
            // state) in one call — no separate "accept" step needed.
            let next = llama_sampler_sample(chain, context, -1)
            if llama_vocab_is_eog(vocab, next) { break }
            output += piece(for: next, vocab: vocab)
            produced += 1
            onToken?(output)
            // Reuse the same stable storage for the single next token, so the
            // batch keeps pointing at live memory for the decode above on the
            // following iteration.
            tokenStore.pointee = next
            batch = llama_batch_get_one(tokenStore, 1)
        }
        if let readEnd, !isCancelled() {
            let writeEnd = DispatchTime.now().uptimeNanoseconds
            let stats = AIRunStats(
                promptTokens: promptCount,
                promptNanos: Int(readEnd &- readStart),
                outputTokens: produced,
                outputNanos: Int(writeEnd &- readEnd)
            )
            lastStats = stats
            onStats?(stats)
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
/// file has its own copy.
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
