import Foundation

/// The embedded llama.cpp backend ("Built-in Model") as a `FeatureModule`.
///
/// Shipped in every tier: a therapist gets working AI with nothing to
/// install. Ollama stays available as an alternative engine.
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
    let tier: BuildTier = .production
}
