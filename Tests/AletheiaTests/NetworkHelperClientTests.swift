import CryptoKit
import XCTest
@testable import Aletheia

/// Stands in for the XPC connection: writes canned bytes into the handle the
/// client opened, and reports canned progress.
private final class FakeConnection: NetworkHelperConnection, @unchecked Sendable {
    var payload = Data()
    var failure: Error?
    var feed = Data()
    private(set) var requested: [AssetID] = []

    var revocations = Data()

    func checkForUpdates() async throws -> Data { feed }
    func fetchRevocations() async throws -> Data { revocations }

    func download(
        asset: AssetID,
        into file: FileHandle,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        requested.append(asset)
        progress(0, Int64(payload.count))
        try file.write(contentsOf: payload.prefix(payload.count / 2))
        progress(Int64(payload.count / 2), Int64(payload.count))
        if let failure { throw failure }
        try file.write(contentsOf: payload.suffix(from: payload.count / 2))
        progress(Int64(payload.count), Int64(payload.count))
    }
}

final class NetworkHelperClientTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("client-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func leftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    func testMatchingDigestInstallsTheFileAndLeavesNothingElse() async throws {
        let fake = FakeConnection()
        fake.payload = Data((0..<4096).map { UInt8($0 % 251) })
        let destination = dir.appendingPathComponent("model.bin")
        try await NetworkHelperClient(connection: fake)
            .download(.whisperBaseEn, expectedSHA256: sha(fake.payload), to: destination) { _ in }
        XCTAssertEqual(try Data(contentsOf: destination), fake.payload)
        XCTAssertEqual(leftovers(), ["model.bin"])
        XCTAssertEqual(fake.requested, [.whisperBaseEn])
    }

    func testDigestMismatchIsRejectedAndNothingIsLeftBehind() async throws {
        let fake = FakeConnection()
        fake.payload = Data("tampered bytes".utf8)
        let destination = dir.appendingPathComponent("model.bin")
        do {
            try await NetworkHelperClient(connection: fake)
                .download(.llama31_8b, expectedSHA256: sha(Data("the real bytes".utf8)), to: destination) { _ in }
            XCTFail("a wrong digest must be rejected")
        } catch let error as ModelDownloadError {
            guard case .integrityCheckFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(leftovers(), [], "the downloaded file is deleted")
    }

    func testMismatchKeepsAnExistingGoodFile() async throws {
        let destination = dir.appendingPathComponent("model.bin")
        try Data("good".utf8).write(to: destination)
        let fake = FakeConnection()
        fake.payload = Data("bad".utf8)
        do {
            try await NetworkHelperClient(connection: fake)
                .download(.whisperBaseEn, expectedSHA256: sha(Data("other".utf8)), to: destination) { _ in }
            XCTFail("expected rejection")
        } catch is ModelDownloadError {}
        XCTAssertEqual(try Data(contentsOf: destination), Data("good".utf8))
        XCTAssertEqual(leftovers(), ["model.bin"])
    }

    func testProgressIsForwardedAsAFractionEndingAtOne() async throws {
        let fake = FakeConnection()
        fake.payload = Data(repeating: 1, count: 1000)
        let seen = Box()
        try await NetworkHelperClient(connection: fake)
            .download(.whisperSmallEn, expectedSHA256: sha(fake.payload), to: dir.appendingPathComponent("m.bin")) { seen.add($0) }
        let values = seen.values
        XCTAssertTrue(values.contains(0.5), "\(values)")
        XCTAssertEqual(values.last, 1)
        XCTAssertEqual(values, values.sorted())
    }

    func testConnectionFailureDeletesThePartialFile() async throws {
        let fake = FakeConnection()
        fake.payload = Data(repeating: 2, count: 100)
        fake.failure = ModelDownloadError.downloadFailed("boom")
        do {
            try await NetworkHelperClient(connection: fake)
                .download(.gemma4_e2b, expectedSHA256: sha(fake.payload), to: dir.appendingPathComponent("m.bin")) { _ in }
            XCTFail("expected failure")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error, .downloadFailed("boom"))
        }
        XCTAssertEqual(leftovers(), [])
    }

    func testAppcastPassesThrough() async throws {
        let fake = FakeConnection()
        fake.feed = Data(#"{"version":"9"}"#.utf8)
        let data = try await NetworkHelperClient(connection: fake).fetchAppcast()
        XCTAssertEqual(data, fake.feed)
    }

    func testRevocationsPassThrough() async throws {
        let fake = FakeConnection()
        fake.revocations = Data("signed-list".utf8)
        let data = try await NetworkHelperClient(connection: fake).fetchRevocations()
        XCTAssertEqual(data, fake.revocations)
    }

    func testHelperErrorsAreMappedToDownloadFailures() {
        let helperError = NSError(domain: NetworkHelperConstants.errorDomain, code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "The helper won't connect to example.com."])
        XCTAssertEqual(
            NetworkHelperClientError.map(helperError) as? ModelDownloadError,
            .downloadFailed("The helper won't connect to example.com."))
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func add(_ value: Double) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return stored }

    /// A helper that can't be reached is reported as a failure, never as a
    /// silent cancellation.
    func testMissingServiceIsAFailureNotACancellation() async {
        let connection = XPCNetworkHelperConnection(serviceName: "com.aletheia.no-such-service-\(UUID().uuidString)")
        do {
            _ = try await connection.checkForUpdates()
            XCTFail("expected a failure")
        } catch {
            XCTAssertFalse(error is CancellationError, "got \(error)")
            XCTAssertTrue(error is ModelDownloadError, "got \(error)")
        }
    }
}
