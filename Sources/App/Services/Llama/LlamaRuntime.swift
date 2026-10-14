import Foundation

/// Availability facts for the embedded llama.cpp backend, kept in one place so
/// the resolver/UI can ask "can we actually run a local model right now?".
///
/// `isBuilt` is true only when the app was compiled with the llama.cpp package
/// linked in (`Packages/LlamaCpp`), as every shipping build is. It's driven by
/// `#if canImport(llama)`.
enum LlamaRuntime {
    /// Whether the llama.cpp module is linked into this build.
    static var isBuilt: Bool {
        #if canImport(llama)
        return true
        #else
        return false
        #endif
    }

    /// Frees the built-in model and its KV cache (no-op when not linked).
    static func unloadAll() {
        #if canImport(llama)
        LlamaAssistant.unloadAll()
        #endif
    }

    /// The directory downloaded weights live in, alongside the Whisper models in
    /// Application Support. Weights refresh separately from the app.
    static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aletheia", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// On-disk location for a downloaded base GGUF.
    static func modelURL(for model: LlamaModel) -> URL {
        modelsDirectory.appendingPathComponent(model.fileName)
    }

    /// On-disk location for a downloaded LoRA adapter, in an `Adapters/`
    /// subfolder so adapters and base weights don't collide by name.
    static func adapterURL(for adapter: LoRAAdapter) -> URL {
        modelsDirectory
            .appendingPathComponent("Adapters", isDirectory: true)
            .appendingPathComponent(adapter.fileName)
    }
}
