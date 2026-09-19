import Foundation

/// Marks a folder as excluded from system backups via the
/// `isExcludedFromBackup` resource value — which keeps it out of Time Machine
/// and out of iCloud's device backup.
///
/// Aletheia's data folder can hold **plaintext** PHI when at-rest encryption is
/// off (and audio/transcripts as files regardless), so by default it's kept out
/// of system backups: the only off-device copy is the app's own opt-in,
/// end-to-end-encrypted snapshot. A clinician who runs an encrypted Time Machine
/// target and wants system-backup coverage can turn the exclusion off.
enum BackupExclusion {
    /// Sets (or clears) the backup-exclusion flag on `url`. Applied to a folder,
    /// it covers the whole subtree. Throws if the flag can't be written (e.g.
    /// the URL isn't currently accessible).
    static func setExcluded(_ excluded: Bool, at url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try url.setResourceValues(values)
    }

    /// Whether `url` is currently marked excluded from backups. `false` when the
    /// value can't be read.
    static func isExcluded(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup ?? false
    }
}
