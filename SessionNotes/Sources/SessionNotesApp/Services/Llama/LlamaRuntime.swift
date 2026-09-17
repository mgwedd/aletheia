import Foundation

/// Availability facts for the embedded llama.cpp backend, kept in one place so
/// the resolver/UI can ask "can we actually run a local model right now?".
///
/// `isBuilt` is true only when the app was compiled with the llama.cpp package
/// linked in (see README › Embedded llama.cpp). It's driven by
/// `#if canImport(llama)`, so today — before the pinned dependency is added and
/// verified on a Mac — it's false, and the tiered backend resolves `localLlama`
/// down to Ollama. Adding the dependency flips it on with no other changes.
enum LlamaRuntime {
    /// Whether the llama.cpp module is linked into this build.
    static var isBuilt: Bool {
        #if canImport(llama)
        return true
        #else
        return false
        #endif
    }

    /// On-disk location for a downloaded GGUF, alongside the Whisper models in
    /// Application Support. Weights refresh separately from the app.
    static func modelURL(for model: LlamaModel) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SessionNotes", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(model.fileName)
    }

    /// True only when the runtime is linked *and* the model file is present, so
    /// the backend can actually answer.
    static func isAvailable(model: LlamaModel) -> Bool {
        isBuilt && FileManager.default.fileExists(atPath: modelURL(for: model).path)
    }
}
