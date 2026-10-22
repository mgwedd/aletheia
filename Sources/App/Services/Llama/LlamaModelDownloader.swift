import Foundation

/// Downloads a GGUF model for the embedded llama.cpp backend, with progress,
/// so getting a working local model never needs a Terminal step. Mirrors
/// `WhisperModelDownloader`; weights land in Application Support and refresh
/// independently of the app binary.
///
/// One app-wide instance (`shared`), so Settings, the setup checklist and the
/// AI-engine alert all see the same transfer: progress survives closing a
/// window, and a second request joins the running download instead of
/// racing it on the `.partial` file. The transfer itself is made by the bundled
/// network helper (the app has no network access).
final class LlamaModelDownloader: ObservableObject {
    static let shared = LlamaModelDownloader()

    /// Extra free disk space required beyond the model's own size (512 MB).
    static let diskSpaceHeadroomMB = 512

    @Published var progress: Double = 0
    @Published var isDownloading = false
    @Published var statusText = ""
    @Published var lastError: String?

    private let helper: NetworkHelping
    /// The running `download`, so a second caller waits on it.
    @MainActor private var inFlight: (destination: URL, task: Task<Void, Error>)?

    init(helper: NetworkHelping = NetworkHelperClient.shared) {
        self.helper = helper
    }

    /// Fetches a built-in `LlamaModel`, driving `@Published progress`. A call
    /// while the same file is downloading waits for that download; a different
    /// file is refused. Loaded weights are dropped after a successful download
    /// so a re-downloaded model is the one that runs.
    @MainActor
    func download(_ model: LlamaModel, to destinationURL: URL, onProgress: @escaping (Double) -> Void = { _ in }) async throws {
        if let inFlight {
            guard inFlight.destination == destinationURL else {
                throw ModelDownloadError.downloadFailed("Another AI model is downloading. Try again when it finishes.")
            }
            return try await inFlight.task.value
        }
        let task = Task { @MainActor in
            try await fetch(model.asset, to: destinationURL, onProgress: onProgress)
            LlamaRuntime.unloadAll()
        }
        inFlight = (destinationURL, task)
        defer { inFlight = nil }
        try await task.value
    }

    /// `ModelDownloadProvider`: the direct-download (HTTP) implementation of the
    /// seam. Drives `@Published progress`/`isDownloading` for the Settings UI and
    /// also forwards progress to `onProgress`, verifying the pinned digest before
    /// the file is accepted.
    @MainActor
    func fetch(
        _ asset: ModelAsset,
        to destinationURL: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let directory = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.verifyAvailableDiskSpace(for: asset, at: directory)

        isDownloading = true
        progress = 0
        statusText = "Downloading model…"
        lastError = nil
        defer {
            isDownloading = false
            statusText = ""
        }

        try? FileManager.default.removeItem(at: ModelFileInstaller.partialURL(for: destinationURL))
        guard let model = LlamaModel(rawValue: asset.id) else {
            throw ModelDownloadError.downloadFailed("That model isn't one Aletheia can download.")
        }
        do {
            try await helper.download(
                AssetID(model),
                expectedSHA256: asset.expectedSHA256,
                to: destinationURL
            ) { [weak self] fraction in
                let status = Self.statusLabel(forProgress: fraction)
                DispatchQueue.main.async {
                    self?.progress = fraction
                    self?.statusText = status
                    onProgress(fraction)
                }
            }
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Free bytes on the volume holding `url`, or `nil` if the filesystem doesn't report it.
    static func availableDiskBytes(at url: URL) -> Int64? {
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage {
            return available
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
           let free = attrs[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return nil
    }

    /// Checks that the volume holding `directory` has enough free space for
    /// `asset.approximateSizeMB` plus `diskSpaceHeadroomMB`.
    static func verifyAvailableDiskSpace(
        for asset: ModelAsset,
        at directory: URL,
        availableBytesProvider: (URL) -> Int64? = LlamaModelDownloader.availableDiskBytes(at:)
    ) throws {
        guard asset.approximateSizeMB > 0, let available = availableBytesProvider(directory) else { return }
        let neededMB = asset.approximateSizeMB + diskSpaceHeadroomMB
        let neededBytes = Int64(neededMB) * 1_048_576
        if available < neededBytes {
            throw ModelDownloadError.insufficientDiskSpace(neededMB: neededMB)
        }
    }
}

extension LlamaModelDownloader: ModelDownloadProvider {}

extension LlamaModelDownloader {
    static func statusLabel(forProgress fraction: Double) -> String {
        if fraction >= 1.0 {
            return "Verifying downloaded model…"
        }
        return "Downloading model… (\(Int(min(max(fraction, 0), 1) * 100))%)"
    }
}
