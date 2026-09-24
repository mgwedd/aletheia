import Foundation

/// Lifecycle state of the embedded local-LLM engine.
enum LocalLLMEngineState: Equatable {
    /// The runtime isn't in this build, or no model is present.
    case unavailable(reason: String)
    /// Available, but weights aren't loaded into memory yet.
    case notLoaded
    /// Loading weights.
    case loading
    /// Loaded and able to answer.
    case ready
    /// A load or generation failed.
    case failed(reason: String)

    var isReady: Bool { self == .ready }
}

/// Errors surfaced by a local-LLM engine. All are non-fatal — callers degrade
/// (e.g. fall back to Ollama) rather than crash.
enum LocalLLMEngineError: LocalizedError, Equatable {
    case unavailable(String)
    case loadFailed(String)
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason),
             .loadFailed(let reason),
             .generationFailed(let reason):
            return reason
        }
    }
}

/// The embedded local-LLM engine seam: a self-contained, lifecycle-managed
/// abstraction over an on-device model.
///
/// The rest of the app talks to this — never the llama.cpp C API directly — so
/// the runtime, GBNF-constrained decoding, and fine-tuned / LoRA models can
/// evolve behind a stable contract. A build without the runtime linked gets
/// `UnavailableLocalLLMEngine`, which fails clearly instead of crashing, so the
/// production build (which ships no runtime) is unaffected.
protocol LocalLLMEngine: AnyObject {
    /// Current lifecycle state.
    var state: LocalLLMEngineState { get }

    /// Load weights into memory. Idempotent and safe to call before `generate`;
    /// `generate`/`stream` may also load lazily.
    func load() async throws

    /// Release weights/context and return to `.notLoaded` (or stay
    /// `.unavailable`). Safe to call when nothing is loaded.
    func unload()

    /// Generate a full completion for `request`.
    func generate(_ request: LocalLLMRequest) async throws -> String

    /// Stream the growing *full text so far* (cumulative, not deltas) for
    /// `request`, so callers render one uniform shape regardless of backend.
    func stream(_ request: LocalLLMRequest) -> AsyncThrowingStream<String, Error>
}

extension LocalLLMEngine {
    /// Default streaming: run the batch `generate` and emit the whole answer
    /// once. The real engine overrides this with token-by-token streaming.
    func stream(_ request: LocalLLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(try await generate(request))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The engine used when the llama runtime isn't compiled into this build — the
/// production and preview tiers, and any build before the package is pinned.
/// Every operation fails with a clear, non-fatal error so callers degrade
/// gracefully (the app keeps working; the built-in model simply isn't offered).
final class UnavailableLocalLLMEngine: LocalLLMEngine {
    private let reason: String

    init(reason: String = "The built-in model isn't included in this build.") {
        self.reason = reason
    }

    var state: LocalLLMEngineState { .unavailable(reason: reason) }

    func load() async throws { throw LocalLLMEngineError.unavailable(reason) }

    func unload() {}

    func generate(_ request: LocalLLMRequest) async throws -> String {
        throw LocalLLMEngineError.unavailable(reason)
    }

    func stream(_ request: LocalLLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: LocalLLMEngineError.unavailable(reason)) }
    }
}

/// Composition root for the local-LLM engine. Returns the real engine only when
/// the llama runtime is linked (`#if canImport(llama)`); otherwise a graceful
/// `UnavailableLocalLLMEngine`. The real engine is wired in when the pinned
/// llama.cpp package is added and Mac-verified — until then both branches return
/// an unavailable engine, so every current build behaves identically.
enum LocalLLMEngineFactory {
    static func make(
        modelURL: URL,
        sampling: LocalLLMSampling = .deterministic
    ) -> LocalLLMEngine {
        #if canImport(llama)
        // TODO(llama pin): return the real LlamaEngine(modelURL:sampling:) here,
        // conforming to LocalLLMEngine, once the pinned package + engine land and
        // are verified on a Mac. Kept as unavailable until then so enabling the
        // package can't half-wire the app.
        return UnavailableLocalLLMEngine(
            reason: "The built-in model runtime is present but not yet wired to the engine seam."
        )
        #else
        return UnavailableLocalLLMEngine()
        #endif
    }
}
