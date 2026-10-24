import Foundation

/// What callers need from the network: the update feed, the license revocation
/// list, and pinned downloads.
/// Everything goes through the bundled helper; the app itself has no network
/// access. Callers and tests use this protocol, so a fake can stand in.
protocol NetworkHelping: Sendable {
    /// The update feed's bytes.
    func fetchAppcast() async throws -> Data

    /// The signed license revocation list's bytes (unverified; see `RevocationVerifier`).
    /// Which address it comes from is the helper's business; the app can't name one.
    func fetchRevocations() async throws -> Data

    /// Downloads `asset` to `destination`, reporting `0...1` progress, and
    /// keeps it only if its SHA-256 equals `expectedSHA256`.
    func download(
        _ asset: AssetID,
        expectedSHA256: String,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws
}

/// The raw conversation with the helper (one XPC call per command). The real
/// one is `XPCNetworkHelperConnection`; tests substitute a fake.
protocol NetworkHelperConnection: Sendable {
    func checkForUpdates() async throws -> Data
    func fetchRevocations() async throws -> Data
    func download(
        asset: AssetID,
        into file: FileHandle,
        progress: @escaping @Sendable (_ bytesWritten: Int64, _ bytesExpected: Int64) -> Void
    ) async throws
}

/// The app side of the helper: creates the destination file in the app's own
/// container, hands the helper a write-only handle to it, and then — in the app,
/// not the helper — verifies the pinned digest, deleting the file on a mismatch.
struct NetworkHelperClient: NetworkHelping {
    /// The shared client, wired to the bundled XPC service.
    static let shared = NetworkHelperClient(connection: XPCNetworkHelperConnection())

    private let connection: NetworkHelperConnection

    init(connection: NetworkHelperConnection) {
        self.connection = connection
    }

    func fetchAppcast() async throws -> Data {
        try await connection.checkForUpdates()
    }

    func fetchRevocations() async throws -> Data {
        try await connection.fetchRevocations()
    }

    func download(
        _ asset: AssetID,
        expectedSHA256: String,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        // An empty file the helper streams into. It is opened write-only here,
        // so the helper can neither read it back nor reach any other file.
        let staging = destination.appendingPathExtension("download")
        try? fm.removeItem(at: staging)
        guard fm.createFile(atPath: staging.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ModelDownloadError.noDestination
        }
        do {
            let handle = try FileHandle(forWritingTo: staging)
            defer { try? handle.close() }
            try await connection.download(asset: asset, into: handle) { written, expected in
                guard expected > 0 else { return }
                onProgress(min(max(Double(written) / Double(expected), 0), 1))
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        onProgress(1)
        // Verifies, then swaps in; on a mismatch the file is deleted.
        try ModelFileInstaller.installVerified(from: staging, to: destination, expectedSHA256: expectedSHA256)
    }
}

/// Errors from the helper arrive as NSErrors in its domain.
enum NetworkHelperClientError {
    static func map(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == NetworkHelperConstants.errorDomain {
            return ModelDownloadError.downloadFailed(ns.localizedDescription)
        }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSXPCConnectionInterrupted || ns.code == NSXPCConnectionInvalid {
            return ModelDownloadError.downloadFailed("The network helper stopped unexpectedly. Try again.")
        }
        return error
    }
}
