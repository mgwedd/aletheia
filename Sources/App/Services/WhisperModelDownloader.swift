import Foundation

enum ModelDownloadError: LocalizedError, Equatable {
    case noDestination
    case downloadFailed(String)
    case integrityCheckFailed(expected: String, actual: String)
    case insufficientDiskSpace(neededMB: Int)

    var errorDescription: String? {
        switch self {
        case .noDestination: return "No download destination was set."
        case .downloadFailed(let message): return "Couldn't download the model: \(message)"
        case .integrityCheckFailed:
            return "The downloaded model failed its integrity check and was discarded. Please try downloading it again."
        case .insufficientDiskSpace(let neededMB):
            let formatted = String(format: "%.1f GB", Double(neededMB) / 1024.0)
            return "Not enough free disk space to download the model (at least \(formatted) required)."
        }
    }
}

/// Downloads a whisper.cpp ggml model file from Hugging Face, with progress, so
/// getting a working transcription model never requires a Terminal or Homebrew.
///
/// The transfer is made by the bundled network helper (the app has no network
/// access); this class asks it for the model by `AssetID`, then the client
/// verifies the pinned SHA-256 and swaps the file in.
final class WhisperModelDownloader: ObservableObject {
    @Published var progress: Double = 0
    @Published var isDownloading = false
    @Published var lastError: String?

    private let helper: NetworkHelping

    init(helper: NetworkHelping = NetworkHelperClient.shared) {
        self.helper = helper
    }

    @MainActor
    func download(_ model: WhisperModel, to destinationURL: URL) async throws {
        isDownloading = true
        progress = 0
        lastError = nil
        defer { isDownloading = false }

        do {
            try await helper.download(
                AssetID(model),
                expectedSHA256: model.expectedSHA256,
                to: destinationURL
            ) { [weak self] fraction in
                DispatchQueue.main.async { self?.progress = fraction }
            }
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }
}
