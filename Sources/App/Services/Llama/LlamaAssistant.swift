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
    private let maxTokens: Int

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
        let created = LlamaEngine(modelURL: modelURL, sampling: LocalLLMSampling(maxTokens: maxTokens))
        Self.engines[modelURL] = created
        return created
    }

    /// `maxTokens` defaults to the reply room every prompt budget keeps, so a
    /// long note isn't cut short.
    init(modelURL: URL, maxTokens: Int = ContextBudget.replyHeadroomTokens) {
        self.modelURL = modelURL
        self.maxTokens = maxTokens
    }

    func isReachable() async -> Bool { FileManager.default.fileExists(atPath: modelURL.path) }
    func listModels() async throws -> [String] { [modelURL.deletingPathExtension().lastPathComponent] }
    func hasModel(_ name: String) async -> Bool { FileManager.default.fileExists(atPath: modelURL.path) }

    /// Weights are fetched by `LlamaModelDownloader`, not here; nothing to pull.
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {
        onProgress(1.0, "ready")
    }

    private func request(system: String, prompt: String) -> LocalLLMRequest {
        LocalLLMRequest(system: system, prompt: prompt, sampling: LocalLLMSampling(maxTokens: maxTokens))
    }

    /// The model isn't downloaded: a setup step, said plainly instead of a load error.
    private var missingModel: LocalLLMEngineError? {
        FileManager.default.fileExists(atPath: modelURL.path) ? nil : .modelNotDownloaded
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

    func generate(model _: String, system: String, prompt: String) async throws -> String {
        if let missingModel { throw missingModel }
        return try await engine.generate(request(system: system, prompt: prompt))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Token-by-token streaming of the growing full text; a Stop in the UI
    /// cancels the engine's decode loop.
    func stream(model _: String, system: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        if let missingModel { return AsyncThrowingStream { $0.finish(throwing: missingModel) } }
        return engine.stream(request(system: system, prompt: prompt))
    }
}
#endif
