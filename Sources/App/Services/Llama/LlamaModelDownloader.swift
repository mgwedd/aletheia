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
    /// download start. Always set before a transfer begins; there is no unverified path.
    private var expectedSHA256 = ""
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
        try? FileManager.default.removeItem(at: Self.partialURL(for: destinationURL))
        self.destinationURL = destinationURL
        self.expectedSHA256 = asset.expectedSHA256
        self.progressHandler = onProgress

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            session.downloadTask(with: asset.remoteURL).resume()
        }
    }

    /// Moves the finished download to `<destination>.partial`, verifies it there,
    /// and only then replaces `destination`. Any failure deletes the partial and
    /// leaves an existing good model untouched; an unverified file is never at
    /// the final path. Synchronous: the URLSession temp file vanishes when the
    /// delegate returns, and hashing runs on the delegate queue, not main.
    static func installVerified(from location: URL, to destination: URL, expectedSHA256: String) throws {
        let fm = FileManager.default
        let partial = partialURL(for: destination)
        try? fm.removeItem(at: partial)
        try fm.moveItem(at: location, to: partial)
        do {
            try ModelDigest.verify(fileAt: partial, expectedSHA256: expectedSHA256)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: partial)
            } else {
                try fm.moveItem(at: partial, to: destination)
            }
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    static func partialURL(for destination: URL) -> URL {
        destination.appendingPathExtension("partial")
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
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ModelDownloadError.downloadFailed("HTTP \(http.statusCode)")
            }
            try Self.installVerified(from: location, to: destinationURL, expectedSHA256: expectedSHA256)
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
