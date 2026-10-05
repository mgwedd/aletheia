import Foundation

/// A model's weights to acquire, described independently of *where* they come
/// from. Identity (`id`, `fileName`) is stable across sources; `remoteURL` is
/// what a direct-download provider fetches; `expectedSHA256` (when the model is
/// pinned) is verified before the file is accepted.
///
/// This is the currency of the model-download seam: the direct-download MVP and
/// a later Apple Background Assets / CDN / App Store provider all take a
/// `ModelAsset`, so the distribution mechanism can change without touching the
/// call sites that ask for a model.
struct ModelAsset: Equatable {
    /// Stable identifier for the asset (e.g. the model's raw value).
    let id: String
    /// The on-disk file name the weights are saved as.
    let fileName: String
    /// Where a direct-download (HTTP) provider fetches the weights.
    let remoteURL: URL
    /// SHA-256 the finished file must match, or `nil` when the model isn't pinned
    /// yet (accepted unverified — see `LlamaModel.expectedSHA256`).
    let expectedSHA256: String?
    /// Rough download size, for progress/plumbing UI.
    let approximateSizeMB: Int
}

/// Acquires a model's weights to a local file, reporting progress and verifying
/// integrity — the seam that keeps the distribution mechanism swappable.
///
/// The direct-download MVP (`LlamaModelDownloader`) is one implementation.
/// Apple Background Assets, a model CDN, or a Mac App Store on-demand-resource
/// provider can be another later, conforming to this same contract so nothing at
/// the call site changes (the distribution-later goal in the roadmap).
protocol ModelDownloadProvider: AnyObject {
    /// Fetches `asset` to `destinationURL`, reporting fractional progress in
    /// `0...1` via `onProgress`. Verifies the finished file against
    /// `asset.expectedSHA256` when it's set and throws on mismatch — a corrupt or
    /// tampered model is never left in place.
    @MainActor
    func fetch(
        _ asset: ModelAsset,
        to destinationURL: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws
}

extension LlamaModel {
    /// This model as a source-agnostic `ModelAsset` for the download seam, so the
    /// same model can be fetched by any `ModelDownloadProvider`.
    var asset: ModelAsset {
        ModelAsset(
            id: rawValue,
            fileName: fileName,
            remoteURL: downloadURL,
            expectedSHA256: expectedSHA256,
            approximateSizeMB: approximateSizeMB
        )
    }
}
