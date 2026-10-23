import Foundation

/// Thrown by `UnavailableAssistant` in builds that don't include the built-in
/// model runtime (for example a `swift test` build without llama.cpp).
enum BuiltInModelUnavailableError: LocalizedError, Equatable {
    case unavailable

    var errorDescription: String? {
        "The built-in AI model isn't available in this build of Aletheia."
    }
}

/// The assistant used when the built-in engine isn't linked: every request fails
/// with `BuiltInModelUnavailableError`. It never falls back to another engine.
struct UnavailableAssistant: Assistant {
    func isReachable() async -> Bool { false }
    func listModels() async throws -> [String] { throw BuiltInModelUnavailableError.unavailable }
    func hasModel(_ name: String) async -> Bool { false }
    func generate(model: String, system: String, prompt: String) async throws -> String {
        throw BuiltInModelUnavailableError.unavailable
    }
    func stream(model: String, system: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: BuiltInModelUnavailableError.unavailable) }
    }
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {
        throw BuiltInModelUnavailableError.unavailable
    }
}
