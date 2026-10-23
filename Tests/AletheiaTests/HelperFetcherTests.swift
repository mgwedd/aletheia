import XCTest
@testable import Aletheia

/// A URLProtocol that answers from a closure and records every request it sees.
private final class StubProtocol: URLProtocol {
    typealias Responder = (URLRequest) -> Reply
    enum Reply {
        case ok(Data)
        case status(Int)
        case redirect(to: String)
        /// Sends `count` chunks of `size` bytes, a few ms apart, until the task is cancelled.
        case chunks(count: Int, size: Int)
    }

    nonisolated(unsafe) static var responder: Responder = { _ in .ok(Data()) }
    nonisolated(unsafe) static var seen: [URLRequest] = []
    nonisolated(unsafe) static var chunksSent = 0
    private let stopped = NSLock()
    nonisolated(unsafe) private var isStopped = false
    private static let lock = NSLock()

    static func reset(_ responder: @escaping Responder) {
        lock.lock(); defer { lock.unlock() }
        seen = []
        chunksSent = 0
        self.responder = responder
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.seen.append(request)
        let reply = Self.responder(request)
        Self.lock.unlock()
        let url = request.url!
        switch reply {
        case .ok(let data):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Length": "\(data.count)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .status(let code):
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil,
                                           headerFields: ["Location": target])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: response)
        case .chunks(let count, let size):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            DispatchQueue.global().async {
                for _ in 0..<count {
                    self.stopped.lock(); let done = self.isStopped; self.stopped.unlock()
                    if done { return }
                    Self.lock.lock(); Self.chunksSent += 1; Self.lock.unlock()
                    self.client?.urlProtocol(self, didLoad: Data(repeating: 0x20, count: size))
                    usleep(5_000)
                }
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {
        stopped.lock(); isStopped = true; stopped.unlock()
    }
}

final class HelperFetcherTests: XCTestCase {
    private func makeFetcher() -> HelperFetcher {
        let config = HelperFetcher.makeConfiguration()
        config.protocolClasses = [StubProtocol.self]
        return HelperFetcher(configuration: config)
    }

    private func tempHandle() throws -> (FileHandle, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("helper-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return (try FileHandle(forWritingTo: url), url)
    }

    func testConfigurationKeepsNoCookiesCacheOrCredentials() {
        let config = HelperFetcher.makeConfiguration()
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertNil(config.urlCache)
        XCTAssertNil(config.urlCredentialStorage)
        XCTAssertEqual(config.httpCookieAcceptPolicy, .never)
        XCTAssertFalse(config.httpShouldSetCookies)
    }

    func testRequestIsAPlainGETWithNoBodyOrCookies() async throws {
        StubProtocol.reset { _ in .ok(Data("hello".utf8)) }
        let (handle, file) = try tempHandle()
        defer { try? FileManager.default.removeItem(at: file) }
        try await makeFetcher().stream(from: URL(string: "https://huggingface.co/a/b")!, into: handle) { _, _ in }
        try handle.close()

        let request = try XCTUnwrap(StubProtocol.seen.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.httpBodyStream)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(try Data(contentsOf: file), Data("hello".utf8))
    }

    func testProgressIsReported() async throws {
        StubProtocol.reset { _ in .ok(Data(repeating: 7, count: 1000)) }
        let (handle, file) = try tempHandle()
        defer { try? FileManager.default.removeItem(at: file) }
        let last = LockedBox<(Int64, Int64)>((0, 0))
        try await makeFetcher().stream(from: URL(string: "https://huggingface.co/a")!, into: handle) { written, expected in
            last.value = (written, expected)
        }
        XCTAssertEqual(last.value.0, 1000)
        XCTAssertEqual(last.value.1, 1000)
    }

    func testOffAllowlistInitialURLIsNeverRequested() async throws {
        StubProtocol.reset { _ in .ok(Data()) }
        let (handle, file) = try tempHandle()
        defer { try? FileManager.default.removeItem(at: file) }
        for raw in ["https://example.com/x", "http://huggingface.co/x"] {
            do {
                try await makeFetcher().stream(from: URL(string: raw)!, into: handle) { _, _ in }
                XCTFail("\(raw) should be refused")
            } catch let error as HelperError {
                guard case .notAllowed = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertTrue(StubProtocol.seen.isEmpty)
    }

    func testRedirectWithinTheAllowlistIsFollowed() async throws {
        StubProtocol.reset { request in
            request.url?.host == "huggingface.co"
                ? .redirect(to: "https://cdn-lfs.hf.co/file")
                : .ok(Data("data".utf8))
        }
        let (handle, file) = try tempHandle()
        defer { try? FileManager.default.removeItem(at: file) }
        try await makeFetcher().stream(from: URL(string: "https://huggingface.co/a")!, into: handle) { _, _ in }
        try handle.close()
        XCTAssertEqual(StubProtocol.seen.map { $0.url?.host }, ["huggingface.co", "cdn-lfs.hf.co"])
        XCTAssertEqual(try Data(contentsOf: file), Data("data".utf8))
    }

    func testRedirectOffTheAllowlistIsRejectedAndNeverRequested() async throws {
        StubProtocol.reset { _ in .redirect(to: "https://evil.example.com/steal") }
        let (handle, file) = try tempHandle()
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try await makeFetcher().stream(from: URL(string: "https://huggingface.co/a")!, into: handle) { _, _ in }
            XCTFail("redirect off the allowlist must fail")
        } catch let error as HelperError {
            guard case .redirectRejected(let host) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(host, "evil.example.com")
        }
        XCTAssertFalse(StubProtocol.seen.contains { $0.url?.host == "evil.example.com" })
    }

    func testRedirectDowngradeToHTTPIsRejected() async throws {
        StubProtocol.reset { _ in .redirect(to: "http://huggingface.co/plain") }
        let (handle, file) = try tempHandle()
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try await makeFetcher().stream(from: URL(string: "https://huggingface.co/a")!, into: handle) { _, _ in }
            XCTFail("an http redirect must fail")
        } catch is HelperError {}
    }

    func testNon200IsAFailure() async throws {
        StubProtocol.reset { _ in .status(404) }
        let (handle, file) = try tempHandle()
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try await makeFetcher().stream(from: URL(string: "https://huggingface.co/a")!, into: handle) { _, _ in }
            XCTFail("404 must fail")
        } catch let error as HelperError {
            XCTAssertEqual(error, .badStatus(404))
        }
    }

    func testAppcastMustBeAJSONObject() async throws {
        StubProtocol.reset { _ in .ok(Data("<html>nope</html>".utf8)) }
        do {
            _ = try await makeFetcher().fetchAppcast()
            XCTFail("a non-JSON feed must fail")
        } catch let error as HelperError {
            XCTAssertEqual(error, .badFeed)
        }
    }

    func testUpdateArchiveURLComesFromTheAppcastAndMustBeThisRepo() async throws {
        let good = #"{"downloadURL":"https://github.com/mgwedd/aletheia/releases/download/v9/Aletheia.dmg"}"#
        StubProtocol.reset { _ in .ok(Data(good.utf8)) }
        let url = try await makeFetcher().resolveUpdateArchiveURL()
        XCTAssertEqual(url.absoluteString, "https://github.com/mgwedd/aletheia/releases/download/v9/Aletheia.dmg")
        XCTAssertEqual(StubProtocol.seen.first?.url, HelperEndpoints.appcast)

        let bad = #"{"downloadURL":"https://github.com/someone/else/releases/download/v9/x.dmg"}"#
        StubProtocol.reset { _ in .ok(Data(bad.utf8)) }
        do {
            _ = try await makeFetcher().resolveUpdateArchiveURL()
            XCTFail("a foreign archive URL must be refused")
        } catch let error as HelperError {
            guard case .notAllowed = error else { return XCTFail("\(error)") }
        }
    }

    func testRevocationsWithNoEndpointFailsNotConfiguredAndMakesNoRequest() async throws {
        StubProtocol.reset { _ in .ok(Data("x".utf8)) }
        XCTAssertNil(HelperEndpoints.revocations, "the shipped endpoint is unset until the domain is decided")
        do {
            _ = try await makeFetcher().fetchRevocations()
            XCTFail("must not succeed without an endpoint")
        } catch let error as HelperError {
            XCTAssertEqual(error, .notConfigured)
            XCTAssertFalse(error.message.isEmpty)
        }
        XCTAssertTrue(StubProtocol.seen.isEmpty)
    }

    func testRevocationsFetchIsAPlainGETAndReturnsTheBytes() async throws {
        StubProtocol.reset { _ in .ok(Data("list".utf8)) }
        let data = try await makeFetcher().fetchRevocations(from: URL(string: "https://github.com/r/revocations.json")!)
        XCTAssertEqual(data, Data("list".utf8))
        let request = try XCTUnwrap(StubProtocol.seen.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.url?.query)
    }

    func testRevocationsOverTheCapAreRejected() async throws {
        StubProtocol.reset { _ in .ok(Data(repeating: 0x20, count: HelperFetcher.maxDataBytes + 1)) }
        do {
            _ = try await makeFetcher().fetchRevocations(from: URL(string: "https://github.com/r/revocations.json")!)
            XCTFail("over 256 KB must fail")
        } catch let error as HelperError {
            XCTAssertEqual(error, .tooLarge)
        }
    }

    /// The cap holds while bytes arrive: the transfer is cancelled soon after
    /// the cap, not read to the end and then checked.
    func testRevocationsOverTheCapStopTheTransferPartway() async throws {
        let size = 16 * 1024, count = 128  // 2 MB offered, cap is 256 KB
        StubProtocol.reset { _ in .chunks(count: count, size: size) }
        do {
            _ = try await makeFetcher().fetchRevocations(from: URL(string: "https://github.com/r/revocations.json")!)
            XCTFail("over 256 KB must fail")
        } catch let error as HelperError {
            XCTAssertEqual(error, .tooLarge)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertLessThan(StubProtocol.chunksSent, count / 2, "the transfer kept going after the cap")
    }

    func testRevocationsAtExactlyTheCapAreAccepted() async throws {
        StubProtocol.reset { _ in .ok(Data(repeating: 0x20, count: HelperFetcher.maxDataBytes)) }
        let data = try await makeFetcher().fetchRevocations(from: URL(string: "https://github.com/r/revocations.json")!)
        XCTAssertEqual(data.count, 256 * 1024)
    }

    func testRevocationsRefuseHttpAndOffAllowlistEndpoints() async throws {
        StubProtocol.reset { _ in .ok(Data()) }
        for raw in ["http://github.com/r", "https://example.com/r"] {
            do {
                _ = try await makeFetcher().fetchRevocations(from: URL(string: raw)!)
                XCTFail("\(raw) should be refused")
            } catch let error as HelperError {
                guard case .notAllowed = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertTrue(StubProtocol.seen.isEmpty)
    }

    func testRevocationsRedirectOffTheAllowlistIsRejected() async throws {
        StubProtocol.reset { _ in .redirect(to: "https://evil.example.com/x") }
        do {
            _ = try await makeFetcher().fetchRevocations(from: URL(string: "https://github.com/r")!)
            XCTFail("redirect off the allowlist must fail")
        } catch let error as HelperError {
            guard case .redirectRejected = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(StubProtocol.seen.count, 1)
    }

    func testOversizeDataIsRejected() async throws {
        StubProtocol.reset { _ in .ok(Data(repeating: 0x20, count: 1024)) }
        do {
            _ = try await makeFetcher().fetchData(from: URL(string: "https://github.com/x")!, maxBytes: 100)
            XCTFail("over the cap must fail")
        } catch let error as HelperError {
            XCTAssertEqual(error, .tooLarge)
        }
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
