import Foundation

/// Availability facts for the embedded llama.cpp backend, kept in one place so
/// the resolver/UI can ask "can we actually run a local model right now?".
///
/// `isBuilt` is true only when the app was compiled with the llama.cpp package
/// linked in (`Packages/LlamaCpp`), as every shipping build is. It's driven by
/// `#if canImport(llama)`.
enum LlamaRuntime {
    /// Previously downloadable weights remain on disk after a catalog upgrade
    /// until the user removes them in Settings.
    struct RetiredModelFile: Identifiable {
        let name: String
        let fileName: String
        let approximateSizeMB: Int
        var id: String { fileName }
    }

    static let retiredModelFiles: [RetiredModelFile] = [
        .init(name: "MedLlama 2 7B", fileName: "MedLlama-2-7B.q4_K_S.gguf", approximateSizeMB: 3857),
        .init(name: "MedGemma 4B", fileName: "medgemma-4b-it-Q4_K_M.gguf", approximateSizeMB: 2490),
    ]

    static func retiredDownloadedModels(in directory: URL = modelsDirectory) -> [RetiredModelFile] {
        retiredModelFiles.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.fileName).path) }
    }

    static func removeRetiredModel(_ model: RetiredModelFile, in directory: URL = modelsDirectory) throws {
        guard retiredModelFiles.contains(where: { $0.fileName == model.fileName }) else { return }
        unloadAll()
        let url = directory.appendingPathComponent(model.fileName)
        try? FileManager.default.removeItem(at: ModelFileInstaller.partialURL(for: url))
        try? FileManager.default.removeItem(at: ModelFileInstaller.legacyResumeDataURL(for: url))
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

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

    /// Other `LlamaModel` cases (besides `active`) whose GGUF files exist in `directory`.
    static func unusedDownloadedModels(
        besides active: LlamaModel,
        in directory: URL = modelsDirectory
    ) -> [LlamaModel] {
        LlamaModel.allCases.filter { model in
            model != active && FileManager.default.fileExists(atPath: directory.appendingPathComponent(model.fileName).path)
        }
    }

    /// Removes the on-disk GGUF (and any partial/resume files) for `model` in `directory`.
    static func removeModel(_ model: LlamaModel, in directory: URL = modelsDirectory) throws {
        unloadAll()
        let url = directory.appendingPathComponent(model.fileName)
        try? FileManager.default.removeItem(at: ModelFileInstaller.partialURL(for: url))
        try? FileManager.default.removeItem(at: ModelFileInstaller.legacyResumeDataURL(for: url))
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
