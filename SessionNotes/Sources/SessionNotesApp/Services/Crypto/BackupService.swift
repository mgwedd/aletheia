import CryptoKit
import Foundation

/// Outcome of a backup or restore attempt.
enum BackupOutcome: Equatable {
    /// The archive that was written/uploaded, or the database that was restored.
    case success(URL)
    /// This destination isn't set up on this build (e.g. iCloud not provisioned).
    case notConfigured
    case failed(String)
}

/// A destination an end-to-end-encrypted backup archive can be written to and
/// restored from. Implementations only ever move the opaque
/// `EncryptedBackupArchive` blob around — plaintext PHI never leaves the Mac.
protocol BackupService {
    /// Whether this destination is usable on this build/configuration.
    var isConfigured: Bool { get }
    /// Seals `databaseURL` into an archive and stores it. `reason` tags the
    /// artifact (e.g. "manual", "pre-update-1.15.0").
    func backUp(databaseURL: URL, reason: String) async -> BackupOutcome
    /// Restores the most recent archive over `databaseURL`.
    /// PRECONDITION: no store may be open on `databaseURL`.
    func restoreLatest(to databaseURL: URL) async -> BackupOutcome
}

/// Keeps end-to-end-encrypted backups on this Mac, under `<dataRoot>/.backups/`.
/// This is always available (no external service), and Time Machine picks the
/// archives up like any other file — giving "encrypted, and local" without
/// relying on FileVault alone. Retention keeps the most recent `keep`.
struct LocalEncryptedBackupService: BackupService {
    let root: URL
    /// The user's key — the archive is sealed with it and nothing else can open
    /// it. Held in memory only; sourced from the same machinery as at-rest
    /// encryption (`EncryptionManager`).
    let key: SymmetricKey
    var keep: Int = 5
    private let fileManager = FileManager.default

    var directory: URL { root.appendingPathComponent(".backups", isDirectory: true) }
    var isConfigured: Bool { true }

    func backUp(databaseURL: URL, reason: String) async -> BackupOutcome {
        await backUp(databaseURL: databaseURL, reason: reason, at: Date())
    }

    /// Date-injectable variant for deterministic tests.
    func backUp(databaseURL: URL, reason: String, at date: Date) async -> BackupOutcome {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "\(Self.stamp(date))-\(Self.slug(reason)).\(EncryptedBackupArchive.fileExtension)"
            let destination = directory.appendingPathComponent(name)
            try EncryptedBackupArchive.create(from: databaseURL, to: destination, using: key)
            prune()
            return .success(destination)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func restoreLatest(to databaseURL: URL) async -> BackupOutcome {
        guard let latest = archives().first else { return .failed("No backup found on this Mac.") }
        do {
            try EncryptedBackupArchive.restore(from: latest, to: databaseURL, using: key)
            return .success(databaseURL)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Existing archives, newest first (names are UTC-timestamp-prefixed, so a
    /// descending name sort is a time sort).
    func archives() -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter { $0.pathExtension == EncryptedBackupArchive.fileExtension }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // MARK: - Helpers

    private func prune() {
        let all = archives()
        guard all.count > keep else { return }
        for url in all.dropFirst(keep) { try? fileManager.removeItem(at: url) }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private static func stamp(_ date: Date) -> String { stampFormatter.string(from: date) }

    private static func slug(_ text: String) -> String {
        let mapped = text.lowercased().map { ($0.isLetter || $0.isNumber) ? $0 : "-" }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "backup" : collapsed
    }
}

/// Opt-in **end-to-end-encrypted** iCloud backup.
///
/// Same archive as `LocalEncryptedBackupService` — sealed with the user's key on
/// this Mac — with only the opaque blob uploaded to the user's PRIVATE CloudKit
/// database. Apple stores ciphertext it cannot read: the standard "you hold the
/// key, the server sees only encrypted data" model.
///
/// TODO(Apple config — needs a signed build + the user's Apple Developer setup):
///   - Add the iCloud + CloudKit capability and a container id to
///     `project.yml` / `SessionNotes.entitlements`
///     (e.g. `iCloud.com.sessionnotes.aletheia`).
///   - Upload the archive as a `CKRecord` asset in the user's private database,
///     keyed by app version + timestamp; keep the last N.
///   - `restoreLatest`: fetch the newest record's asset, then hand it to
///     `EncryptedBackupArchive.restore(from:to:using:)`.
/// Until provisioned, `isConfigured` is false and calls return `.notConfigured`,
/// so the UI can offer the choice without pretending it works yet.
struct ICloudEncryptedBackupService: BackupService {
    let key: SymmetricKey

    var isConfigured: Bool { false }

    func backUp(databaseURL: URL, reason: String) async -> BackupOutcome { .notConfigured }
    func restoreLatest(to databaseURL: URL) async -> BackupOutcome { .notConfigured }
}
