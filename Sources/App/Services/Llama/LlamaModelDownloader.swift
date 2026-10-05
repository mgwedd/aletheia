import Foundation

/// Downloads a GGUF model for the embedded llama.cpp backend, with progress,
/// so getting a working local model never needs a Terminal step. Mirrors
/// `WhisperModelDownloader`; weights land in Application Support and refresh
/// independently of the app binary.
///
/// Concurrency note: one transfer at a time (the Settings button disables while
/// in flight), so `destinationURL`/`continuation` are safe to touch from the
/// delegate's background queue without extra locking.
final class LlamaModelDownloader: NSObject, ObservableObject {
    @Published var progress: Double = 0
    @Published var isDownloading = false
    @Published var lastError: String?

    private var continuation: CheckedContinuation<Void, Error>?
    private var destinationURL: URL?
    /// Digest to verify the finished download against, captured from the asset at
    /// download start; `nil` means the model isn't pinned yet (download accepted
    /// unverified — see `LlamaModel.expectedSHA256`).
    private var expectedSHA256: String?
    /// Progress sink for the in-flight fetch, so a caller using the seam gets
    /// updates too — not only the `@Published progress` the Settings UI binds to.
    private var progressHandler: ((Double) -> Void)?
    private lazy var session: URLSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    /// Convenience for the built-in models the Settings UI offers: fetch a
    /// `LlamaModel` and drive `@Published progress`. Callers unchanged.
    @MainActor
    func download(_ model: LlamaModel, to destinationURL: URL) async throws {
        try await fetch(model.asset, to: destinationURL, onProgress: { _ in })
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
        isDownloading = true
        progress = 0
        lastError = nil
        defer { isDownloading = false; progressHandler = nil }

        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.destinationURL = destinationURL
        self.expectedSHA256 = asset.expectedSHA256
        self.progressHandler = onProgress

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            session.downloadTask(with: asset.remoteURL).resume()
        }
    }

    /// Verifies the file just moved into place against the pinned digest, if any.
    /// A mismatch deletes the file (so a corrupt or tampered model is never left
    /// behind looking valid) and throws. Runs on the delegate's background queue,
    /// so hashing multi-gigabyte weights never blocks the main thread.
    private func verifyIntegrity(of fileURL: URL) throws {
        guard let expectedSHA256 else { return }
        let actual = try ModelDigest.sha256(ofFileAt: fileURL)
        guard actual.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            try? FileManager.default.removeItem(at: fileURL)
            throw ModelDownloadError.integrityCheckFailed(expected: expectedSHA256, actual: actual)
        }
    }
}

extension LlamaModelDownloader: ModelDownloadProvider {}

extension LlamaModelDownloader: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async {
            self.progress = fraction
            self.progressHandler?(fraction)
        }
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
            try verifyIntegrity(of: destinationURL)
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
