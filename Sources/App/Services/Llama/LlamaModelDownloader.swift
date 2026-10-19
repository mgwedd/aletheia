import Foundation

/// Downloads a GGUF model for the embedded llama.cpp backend, with progress,
/// so getting a working local model never needs a Terminal step. Mirrors
/// `WhisperModelDownloader`; weights land in Application Support and refresh
/// independently of the app binary.
///
/// One app-wide instance (`shared`), so Settings, the setup checklist and the
/// AI-engine alert all see the same transfer: progress survives closing a
/// window, and a second request joins the running download instead of
/// racing it on the `.partial` file. One transfer at a time, so
/// `destinationURL`/`continuation` are safe to touch from the delegate's
/// background queue without extra locking.
final class LlamaModelDownloader: NSObject, ObservableObject {
    static let shared = LlamaModelDownloader()

    /// Extra free disk space required beyond the model's own size (512 MB).
    static let diskSpaceHeadroomMB = 512

    @Published var progress: Double = 0
    @Published var isDownloading = false
    @Published var statusText = ""
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
    /// The running `download`, so a second caller waits on it.
    @MainActor private var inFlight: (destination: URL, task: Task<Void, Error>)?

    func setDestinationForTesting(_ url: URL) {
        destinationURL = url
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
            progressHandler = nil
        }

        try? FileManager.default.removeItem(at: Self.partialURL(for: destinationURL))
        self.destinationURL = destinationURL
        self.expectedSHA256 = asset.expectedSHA256
        self.progressHandler = onProgress

        let resumeURL = Self.resumeDataURL(for: destinationURL)
        let savedResumeData = (try? Data(contentsOf: resumeURL)).flatMap { $0.isEmpty ? nil : $0 }
        if savedResumeData != nil {
            try? FileManager.default.removeItem(at: resumeURL)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            if let savedResumeData {
                session.downloadTask(withResumeData: savedResumeData).resume()
            } else {
                session.downloadTask(with: asset.remoteURL).resume()
            }
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
            try? fm.removeItem(at: resumeDataURL(for: destination))
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    static func partialURL(for destination: URL) -> URL {
        destination.appendingPathExtension("partial")
    }

    static func resumeDataURL(for destination: URL) -> URL {
        destination.appendingPathExtension("resume")
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
        let status = Self.statusLabel(forProgress: fraction)
        DispatchQueue.main.async {
            self.progress = fraction
            self.statusText = status
            self.progressHandler?(fraction)
        }
    }

    static func statusLabel(forProgress fraction: Double) -> String {
        if fraction >= 1.0 {
            return "Verifying downloaded model…"
        }
        return "Downloading model… (\(Int(min(max(fraction, 0), 1) * 100))%)"
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
            DispatchQueue.main.async {
                self.progress = 1.0
                self.statusText = Self.statusLabel(forProgress: 1.0)
                self.progressHandler?(1.0)
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
        if let destinationURL,
           let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
           !resumeData.isEmpty {
            try? resumeData.write(to: Self.resumeDataURL(for: destinationURL), options: .atomic)
        }
        DispatchQueue.main.async { self.lastError = error.localizedDescription }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
