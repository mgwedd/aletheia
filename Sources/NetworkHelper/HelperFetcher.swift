import Foundation

/// The helper's only way onto the network.
///
/// Every request is a plain GET with no body, sent through an ephemeral
/// session that keeps no cookies, cache or credentials. A request is made only
/// to an https URL on `HelperAllowlist`, and a redirect is followed only when
/// it stays on that list.
final class HelperFetcher {
    /// The largest response `fetchData` accepts (the appcast is a few KB).
    static let maxDataBytes = 256 * 1024

    private let configuration: URLSessionConfiguration

    /// `configuration` is injectable so tests can register a stub URLProtocol.
    init(configuration: URLSessionConfiguration = HelperFetcher.makeConfiguration()) {
        self.configuration = configuration
    }

    /// Ephemeral, with no cookie jar, URL cache or credential store.
    static func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 12 * 60 * 60
        return config
    }

    // MARK: - Commands

    /// The appcast bytes, checked to be a JSON object.
    func fetchAppcast() async throws -> Data {
        let data = try await fetchData(from: HelperEndpoints.appcast, maxBytes: Self.maxDataBytes)
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { throw HelperError.badFeed }
        return data
    }

    /// The release archive's URL, read from the appcast this helper fetched.
    func resolveUpdateArchiveURL() async throws -> URL {
        let data = try await fetchAppcast()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["downloadURL"] as? String,
              let url = URL(string: raw)
        else { throw HelperError.badFeed }
        guard HelperEndpoints.isUpdateArchive(url) else { throw HelperError.notAllowed(url.host ?? "that address") }
        return url
    }

    /// Streams `asset` into `handle`.
    func download(
        _ asset: HelperAsset,
        into handle: FileHandle,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws {
        let url: URL
        if let fixed = asset.fixedURL {
            url = fixed
        } else {
            url = try await resolveUpdateArchiveURL()
        }
        try await stream(from: url, into: handle, progress: progress)
    }

    // MARK: - Transfers

    func fetchData(from url: URL, maxBytes: Int) async throws -> Data {
        var buffer = Data()
        try await transfer(from: url, progress: { _, _ in }) { chunk in
            buffer.append(chunk)
            if buffer.count > maxBytes { throw HelperError.tooLarge }
        }
        return buffer
    }

    func stream(
        from url: URL,
        into handle: FileHandle,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws {
        try await transfer(from: url, progress: progress) { chunk in
            try handle.write(contentsOf: chunk)
        }
    }

    private func transfer(
        from url: URL,
        progress: @escaping (Int64, Int64) -> Void,
        sink: @escaping (Data) throws -> Void
    ) async throws {
        guard HelperAllowlist.allows(url) else { throw HelperError.notAllowed(url.host ?? "that address") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpBody = nil
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let transfer = Transfer(progress: progress, sink: sink)
        let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                transfer.start(task, continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// One request's delegate: enforces the redirect and status rules and feeds the
/// body to `sink`. `failure` (the first rule broken) wins over the generic
/// error a cancelled task reports.
private final class Transfer: NSObject, URLSessionDataDelegate {
    private let progress: (Int64, Int64) -> Void
    private let sink: (Data) throws -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var written: Int64 = 0
    private var expected: Int64 = 0

    init(progress: @escaping (Int64, Int64) -> Void, sink: @escaping (Data) throws -> Void) {
        self.progress = progress
        self.sink = sink
    }

    func start(_ task: URLSessionDataTask, _ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
        task.resume()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let target = request.url, HelperAllowlist.allows(target) else {
            failure = HelperError.redirectRejected(request.url?.host ?? "an unknown address")
            completionHandler(nil)
            task.cancel()
            return
        }
        // Follow with a fresh GET, never the redirect's own method or body.
        var next = URLRequest(url: target)
        next.httpMethod = "GET"
        next.httpShouldHandleCookies = false
        next.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        completionHandler(next)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            failure = HelperError.transport("The server's answer wasn't HTTP.")
            completionHandler(.cancel)
            return
        }
        guard http.statusCode == 200 else {
            failure = HelperError.badStatus(http.statusCode)
            completionHandler(.cancel)
            return
        }
        if let final = http.url, !HelperAllowlist.allows(final) {
            failure = HelperError.redirectRejected(final.host ?? "an unknown address")
            completionHandler(.cancel)
            return
        }
        expected = http.expectedContentLength
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try sink(data)
            written += Int64(data.count)
            progress(written, expected)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Error? = failure ?? error.map { HelperError.transport($0.localizedDescription) }
        if let result {
            continuation?.resume(throwing: result)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
