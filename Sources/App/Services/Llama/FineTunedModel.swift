import Foundation

/// A LoRA adapter — a small set of fine-tuning weights applied *on top of* a base
/// GGUF model at load time, rather than a whole replacement model. This is the
/// cheap, swappable way to get a therapy-tuned model: ship/download a ~tens-of-MB
/// adapter for a base the user already has, instead of a multi-gigabyte full
/// fine-tune.
///
/// Described independently of *where* it comes from (same as `ModelAsset`), so the
/// download seam (`ModelDownloadProvider`) fetches an adapter with no new plumbing
/// — `asset` below maps it straight onto that seam.
///
/// An adapter is only valid on the exact base it was trained against; applying it
/// to a different base produces silent garbage. `baseModelID` records that base so
/// a mismatch is caught and **fails closed** before any weights are loaded (see
/// `ModelLoadPlan`).
struct LoRAAdapter: Equatable, Identifiable, Codable, Hashable {
    /// Stable identifier for the adapter (used as the download asset id).
    let id: String
    /// Human-facing name for Settings (e.g. "Therapy notes (SOAP) v1").
    let displayName: String
    /// On-disk file name the adapter is saved as (GGUF LoRA).
    let fileName: String
    /// Where a direct-download provider fetches the adapter.
    let remoteURL: URL
    /// SHA-256 the finished file must match, or `nil` when not pinned yet
    /// (accepted unverified — mirrors `LlamaModel.expectedSHA256`).
    let expectedSHA256: String?
    /// Rough download size, for progress UI. Adapters are small vs. base weights.
    let approximateSizeMB: Int
    /// Raw value of the `LlamaModel` this adapter was trained against. An adapter
    /// is only sound on this exact base.
    let baseModelID: String

    /// The base model this adapter targets, if it maps to one the app knows about.
    var baseModel: LlamaModel? { LlamaModel(rawValue: baseModelID) }

    /// This adapter as a source-agnostic `ModelAsset`, so the same download seam
    /// that fetches base weights fetches an adapter with no new code.
    var asset: ModelAsset {
        ModelAsset(
            id: id,
            fileName: fileName,
            remoteURL: remoteURL,
            expectedSHA256: expectedSHA256,
            approximateSizeMB: approximateSizeMB
        )
    }
}

/// Why an adapter can't be applied to a given base — surfaced to the user rather
/// than swallowed, so a wrong pairing is a clear message, never quiet nonsense.
enum LoRACompatibilityError: LocalizedError, Equatable {
    /// The adapter was trained against a different base than the one selected.
    case baseMismatch(adapter: String, expectedBase: String, actualBase: String)

    var errorDescription: String? {
        switch self {
        case let .baseMismatch(adapter, expectedBase, actualBase):
            return "The adapter “\(adapter)” was trained for \(expectedBase), "
                + "but the selected model is \(actualBase). Choose the matching "
                + "base model, or an adapter built for this one."
        }
    }
}

extension LoRAAdapter {
    /// Whether this adapter is sound on `base` — i.e. it was trained against it.
    func isCompatible(with base: LlamaModel) -> Bool {
        baseModelID == base.rawValue
    }

    /// Throws `LoRACompatibilityError.baseMismatch` unless this adapter targets
    /// `base`. The fail-closed gate: callers validate *before* loading weights, so
    /// a mismatched adapter never reaches the runtime.
    func validate(against base: LlamaModel) throws {
        guard isCompatible(with: base) else {
            throw LoRACompatibilityError.baseMismatch(
                adapter: displayName,
                expectedBase: baseModel?.shortName ?? baseModelID,
                actualBase: base.shortName
            )
        }
    }
}

/// What the engine should actually load: a base model, optionally with a LoRA
/// adapter layered on it. The throwing initializer is the single place adapter
/// compatibility is enforced, so an unsound pairing can't be constructed — the
/// "swappable adapter, fails closed on mismatch" contract in one value.
///
/// The plan is data only (which files, where); the on-device application of the
/// adapter to the base happens in the real engine during the Mac bring-up. Until
/// then this stays fully testable without a runtime.
struct ModelLoadPlan: Equatable {
    let base: LlamaModel
    let adapter: LoRAAdapter?

    /// A plain base model, no adapter.
    init(base: LlamaModel) {
        self.base = base
        self.adapter = nil
    }

    /// A base model with a LoRA adapter. Throws if the adapter wasn't trained for
    /// `base`, so a mismatch is caught here rather than at load time.
    init(base: LlamaModel, adapter: LoRAAdapter) throws {
        try adapter.validate(against: base)
        self.base = base
        self.adapter = adapter
    }

    /// On-disk location of the base weights (downloaded, alongside Whisper models).
    var baseURL: URL { LlamaRuntime.modelURL(for: base) }

    /// On-disk location of the adapter file, or `nil` when there's no adapter.
    var adapterURL: URL? { adapter.map { LlamaRuntime.adapterURL(for: $0) } }

    /// True when an adapter is layered on the base.
    var usesAdapter: Bool { adapter != nil }
}
