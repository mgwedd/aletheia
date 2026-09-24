import Foundation

/// The embedded llama.cpp backend ("Built-in Model") as a `FeatureModule`.
///
/// This is a *must-have* for production eventually — a therapist should get
/// working AI with nothing to install — but it isn't stable yet (the runtime is
/// still staged behind `#if canImport(llama)`, the pinned dependency is not yet
/// added, and the in-wizard model download hasn't launched reliably). So it
/// ships developer-build-only (`.dev`) until it's proven, then graduates to
/// preview and finally production.
///
/// Gating governs whether the backend is *offered* — the "Built-in model" engine
/// option and the llama.cpp model-management section. It's independent of, and
/// additional to, `LlamaRuntime.isBuilt` (whether the package is even linked):
/// production must not advertise a "Built-in model" engine choice that today
/// silently falls back to Ollama. It never affects an already-selected backend's
/// ability to run — `AssistantBackendResolver` still resolves safely.
struct EmbeddedLlamaFeatureModule: FeatureModule {
    /// Also usable as `EmbeddedLlamaFeatureModule.id` at call sites that only
    /// need the identifier to query the registry, without constructing an instance.
    static let id = "embeddedLlama"

    var id: String { Self.id }
    let title = "Built-in Model"
    let tier: BuildTier = .dev
}
