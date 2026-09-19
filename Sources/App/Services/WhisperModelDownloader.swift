import Foundation

enum ModelDownloadError: LocalizedError {
    case noDestination
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDestination: return "No download destination was set."
        case .downloadFailed(let message): return "Couldn't download the model: \(message)"
        }
    }
}

/// Downloads a whisper.cpp ggml model file straight from Hugging Face, with
/// progress, so getting a working transcription model never requires a
/// Terminal or Homebrew.
///
/// Note on concurrency: this downloader only ever runs one transfer at a
/// time (the Settings UI disables the button while a download is in
/// flight), so `destinationURL`/`continuation` are safe to touch from the
/// delegate's background queue without extra locking.
final class WhisperModelDownloader: NSObject, ObservableObject {
    @Published var progress: Double = 0
    @Published var isDownloading = false
    @Published var lastError: String?

    private var continuation: CheckedContinuation<Void, Error>?
    private var destinationURL: URL?
    private lazy var session: URLSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    @MainActor
    func download(_ model: WhisperModel, to destinationURL: URL) async throws {
        isDownloading = true
        progress = 0
        lastError = nil
        defer { isDownloading = false }

        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.destinationURL = destinationURL

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            session.downloadTask(with: model.downloadURL).resume()
        }
    }
}

extension WhisperModelDownloader: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.progress = fraction }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let destinationURL else {
            continuation?.resume(throwing: ModelDownloadError.noDestination)
            continuation = nil
            return
        }
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            continuation?.resume()
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        DispatchQueue.main.async { self.lastError = error.localizedDescription }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
