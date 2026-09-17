import Foundation

/// The local large-language-model integration used for summaries and chat.
///
/// This is an adapter seam: today the only implementation is `OllamaClient`
/// (talking to a local Ollama server), but any backend that can generate
/// text from a prompt — a different local runtime, or a future on-device
/// model — can conform without the rest of the app changing. Everything the
/// UI needs goes through this protocol and `AssistantService`, never a
/// concrete client type.
protocol Assistant {
    /// Whether the backend is currently reachable/usable.
    func isReachable() async -> Bool

    /// Models the backend has available locally.
    func listModels() async throws -> [String]

    /// Whether a specific model is available (accepting `name`, `name:latest`,
    /// or any `name:tag`).
    func hasModel(_ name: String) async -> Bool

    /// Generate a completion for a prompt with the named model, steered by a
    /// system prompt (the app's/user's standing instructions).
    func generate(model: String, system: String, prompt: String) async throws -> String

    /// Download a model, reporting progress as (fraction 0...1, status text).
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws
}
