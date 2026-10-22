import Foundation

/// Talks to the bundled XPC service (`Contents/XPCServices`). Each command uses
/// its own short-lived connection, which launchd starts on demand.
final class XPCNetworkHelperConnection: NetworkHelperConnection, @unchecked Sendable {
    func checkForUpdates() async throws -> Data {
        try await run { connection, finish in
            let proxy = try Self.proxy(connection, finish)
            proxy.checkForUpdates { data, error in
                if let error {
                    finish(.failure(error))
                } else if let data {
                    finish(.success(data))
                } else {
                    finish(.failure(ModelDownloadError.downloadFailed("The update feed was empty.")))
                }
            }
        }
    }

    func download(
        asset: AssetID,
        into file: FileHandle,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let receiver = ProgressReceiver(progress)
        try await run { (connection: NSXPCConnection, finish: @escaping (Result<Void, Error>) -> Void) in
            let proxy = try Self.proxy(connection, finish)
            proxy.download(asset: asset.rawValue, into: file, progress: receiver) { error in
                withExtendedLifetime(receiver) {
                    if let error { finish(.failure(error)) } else { finish(.success(())) }
                }
            }
        }
    }

    // MARK: - Plumbing

    private static func proxy<T>(
        _ connection: NSXPCConnection,
        _ finish: @escaping (Result<T, Error>) -> Void
    ) throws -> NetworkHelperProtocol {
        let remote = connection.remoteObjectProxyWithErrorHandler { error in
            finish(.failure(error))
        }
        guard let proxy = remote as? NetworkHelperProtocol else {
            throw ModelDownloadError.downloadFailed("The network helper isn't available.")
        }
        return proxy
    }

    /// Opens a connection, runs `body`, and resumes exactly once with the first
    /// result (a reply, an XPC error, or the connection dropping), then closes it.
    private func run<T>(
        _ body: @escaping (NSXPCConnection, @escaping (Result<T, Error>) -> Void) throws -> Void
    ) async throws -> T {
        let connection = NSXPCConnection(serviceName: NetworkHelperConstants.serviceName)
        connection.remoteObjectInterface = NetworkHelperInterface.make()
        let once = Once<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                once.arm(continuation) { connection.invalidate() }
                connection.interruptionHandler = {
                    once.finish(.failure(ModelDownloadError.downloadFailed("The network helper stopped unexpectedly. Try again.")))
                }
                connection.invalidationHandler = {
                    once.finish(.failure(CancellationError()))
                }
                connection.resume()
                do {
                    try body(connection) { result in
                        once.finish(result.mapError(NetworkHelperClientError.map))
                    }
                } catch {
                    once.finish(.failure(error))
                }
            }
        } onCancel: {
            once.finish(.failure(CancellationError()))
        }
    }
}

/// Resumes a continuation at most once, then runs a cleanup.
private final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var cleanup: (() -> Void)?
    private var done = false

    func arm(_ continuation: CheckedContinuation<T, Error>, cleanup: @escaping () -> Void) {
        lock.lock()
        if done {
            // Cancelled before the call started.
            lock.unlock()
            cleanup()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        self.cleanup = cleanup
        lock.unlock()
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let continuation = self.continuation
        let cleanup = self.cleanup
        self.continuation = nil
        self.cleanup = nil
        lock.unlock()
        cleanup?()
        continuation?.resume(with: result)
    }
}

/// The reply proxy the helper reports progress through.
private final class ProgressReceiver: NSObject, NetworkHelperProgress, @unchecked Sendable {
    private let handler: @Sendable (Int64, Int64) -> Void

    init(_ handler: @escaping @Sendable (Int64, Int64) -> Void) {
        self.handler = handler
    }

    func report(bytesWritten: Int64, bytesExpected: Int64) {
        handler(bytesWritten, bytesExpected)
    }
}
