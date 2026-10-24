#if canImport(llama)
import Foundation
import llama

/// The embedded local-LLM backend: the official llama.cpp runtime compiled into
/// the app, answering entirely on-device with no server and no external process.
///
/// Compiled against the `llama.h` in the pinned XCFramework (`Packages/LlamaCpp`);
/// re-verify the C calls when re-pinning.
final class LlamaAssistant: Assistant {
    private let modelURL: URL
    private let expectedModelBytes: Int64?
    private let maxTokensOverride: Int?
    private let engineOverride: LocalLLMEngine?

    /// One engine per model file, shared by every assistant made for it: the
    /// app builds a new assistant per use, and the loaded weights and context
    /// (sized by `LlamaEngine`) must outlive each one.
    private static let enginesLock = NSLock()
    nonisolated(unsafe) private static var engines: [URL: LlamaEngine] = [:]

    /// Frees every loaded model, context and KV cache (lock, model or backend
    /// change). The cache is emptied now; the teardown runs on each engine's
    /// own queue, behind any decode in flight, off the caller's thread so
    /// locking never waits on a long generation.
    static func unloadAll() {
        enginesLock.lock()
        let all = Array(engines.values)
        engines.removeAll()
        enginesLock.unlock()
        for engine in all { DispatchQueue.global(qos: .userInitiated).async { engine.unload() } }
    }

    /// Number of cached engines (for tests).
    static var cachedEngineCount: Int {
        enginesLock.lock()
        defer { enginesLock.unlock() }
        return engines.count
    }

    /// Caches an engine for tests, without loading anything.
    static func cacheForTesting(_ engine: LlamaEngine, at url: URL) {
        enginesLock.lock()
        engines[url] = engine
        enginesLock.unlock()
    }

    private var engine: LlamaEngine {
        Self.enginesLock.lock()
        defer { Self.enginesLock.unlock() }
        if let existing = Self.engines[modelURL] { return existing }
        let created = LlamaEngine(
            modelURL: modelURL,
            adapterURL: nil,
            expectedModelBytes: expectedModelBytes,
            sampling: LocalLLMSampling(maxTokens: maxTokensOverride ?? ContextBudget.replyHeadroomTokens)
        )
        Self.engines[modelURL] = created
        return created
    }

    private var activeEngine: LocalLLMEngine {
        engineOverride ?? engine
    }

    /// `maxTokens` defaults to nil so each `AITask` picks its own reply cap
    /// (`ContextBudget.replyHeadroomTokens` for notes and chat, smaller caps for
    /// digests and compaction). Passing an explicit value overrides the task cap.
    init(modelURL: URL, expectedModelBytes: Int64? = nil, maxTokens: Int? = nil, engineOverride: LocalLLMEngine? = nil) {
        self.modelURL = modelURL
        self.expectedModelBytes = expectedModelBytes
        self.maxTokensOverride = maxTokens
        self.engineOverride = engineOverride
    }

    func isReachable() async -> Bool { FileManager.default.fileExists(atPath: modelURL.path) }
    func listModels() async throws -> [String] { [modelURL.deletingPathExtension().lastPathComponent] }
    func hasModel(_ name: String) async -> Bool { FileManager.default.fileExists(atPath: modelURL.path) }

    /// Weights are fetched by `LlamaModelDownloader`, not here; nothing to pull.
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {
        onProgress(1.0, "ready")
    }

    func request(
        system: String,
        turns: [PromptTurn] = [],
        prompt: String,
        task: AITask = .note,
        grammar: LocalLLMGrammar? = nil
    ) -> LocalLLMRequest {
        LocalLLMRequest(
            system: system,
            turns: turns,
            prompt: prompt,
            sampling: LocalLLMSampling.forTask(task, maxTokens: maxTokensOverride),
            grammar: grammar
        )
    }

    /// The model isn't downloaded: a setup step, said plainly instead of a load error.
    private var missingModel: LocalLLMEngineError? {
        if engineOverride != nil { return nil }
        return FileManager.default.fileExists(atPath: modelURL.path) ? nil : .modelNotDownloaded
    }

    /// Loads the weights in the background (on session open) so the first note
    /// or question doesn't wait for them. The idle unload still applies.
    func warmUp(model _: String) {
        guard missingModel == nil else { return }
        let engine = engine
        Task.detached(priority: .utility) {
            try? await engine.load()
            engine.scheduleIdleUnload()
        }
    }

    func generate(model: String, system: String, prompt: String) async throws -> String {
        try await generate(model: model, system: system, prompt: prompt, task: .note, grammar: nil)
    }

    func generate(model: String, system: String, prompt: String, task: AITask) async throws -> String {
        try await generate(model: model, system: system, prompt: prompt, task: task, grammar: nil)
    }

    func generate(
        model: String, system: String, prompt: String, task: AITask, grammar: LocalLLMGrammar?
    ) async throws -> String {
        try await generate(model: model, system: system, turns: [], prompt: prompt, task: task, grammar: grammar)
    }

    func generate(
        model _: String, system: String, turns: [PromptTurn], prompt: String, task: AITask, grammar: LocalLLMGrammar?
    ) async throws -> String {
        if let missingModel { throw missingModel }
        return try await activeEngine.generate(
            request(system: system, turns: turns, prompt: prompt, task: task, grammar: grammar))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Token-by-token streaming of the growing full text; a Stop in the UI
    /// cancels the engine's decode loop.
    func stream(model: String, system: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        stream(model: model, system: system, prompt: prompt, task: .note, grammar: nil, onStats: nil)
    }

    func stream(
        model: String, system: String, prompt: String, onStats: (@Sendable (AIRunStats) -> Void)?
    ) -> AsyncThrowingStream<String, Error> {
        stream(model: model, system: system, prompt: prompt, task: .note, grammar: nil, onStats: onStats)
    }

    func stream(
        model: String, system: String, prompt: String, task: AITask, onStats: (@Sendable (AIRunStats) -> Void)?
    ) -> AsyncThrowingStream<String, Error> {
        stream(model: model, system: system, prompt: prompt, task: task, grammar: nil, onStats: onStats)
    }

    func stream(
        model: String,
        system: String,
        prompt: String,
        task: AITask,
        grammar: LocalLLMGrammar?,
        onStats: (@Sendable (AIRunStats) -> Void)?
    ) -> AsyncThrowingStream<String, Error> {
        stream(model: model, system: system, turns: [], prompt: prompt, task: task, grammar: grammar, onStats: onStats)
    }

    func stream(
        model _: String,
        system: String,
        turns: [PromptTurn],
        prompt: String,
        task: AITask,
        grammar: LocalLLMGrammar?,
        onStats: (@Sendable (AIRunStats) -> Void)?
    ) -> AsyncThrowingStream<String, Error> {
        if let missingModel { return AsyncThrowingStream { $0.finish(throwing: missingModel) } }
        let expectedTokens = ContextBudget.estimatedTokens(system: system, prompt: PromptTurn.flattened(turns, then: prompt))
        return activeEngine.stream(
            request(system: system, turns: turns, prompt: prompt, task: task, grammar: grammar),
            onStats: onStats.map { callback in
                { @Sendable raw in
                    var stats = raw
                    stats.expectedPromptTokens = expectedTokens
                    stats.task = task
                    callback(stats)
                }
            }
        )
    }
}
#endif
