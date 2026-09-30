import Foundation

/// Marks a folder as excluded from system backups via the
/// `isExcludedFromBackup` resource value — which keeps it out of Time Machine
/// and out of iCloud's device backup.
///
/// Aletheia writes no backup of its own unless the clinician opts in, so by
/// default the data folder is **left in** system backups: Time Machine is the
/// baseline copy, and excluding the folder would leave exactly one copy of
/// everything. The folder can hold plaintext PHI when at-rest encryption is off,
/// so Time Machine backups should be on an **encrypted disk**. A clinician who
/// wants the folder kept out of system backups (and relies on the app's own
/// encrypted snapshot instead) can turn the exclusion on.
enum BackupExclusion {
    /// The `UserDefaults` key holding the user's explicit choice.
    static let defaultsKey = "keepDataOutOfSystemBackups"

    /// What applies when the user has never chosen: do **not** exclude, so Time
    /// Machine includes the data folder.
    static let defaultExcluded = false

    /// The exclusion policy to apply: the user's stored choice if they made one,
    /// otherwise `defaultExcluded`. An absent key means "never chosen" — the app
    /// only writes this key when the user flips the Settings toggle, so an unset
    /// key is distinguishable from an explicit `false` / `true`.
    static func resolvedExclusion(in defaults: UserDefaults) -> Bool {
        guard hasExplicitChoice(in: defaults) else { return defaultExcluded }
        return defaults.bool(forKey: defaultsKey)
    }

    /// Whether the user has ever explicitly chosen (the key is present, `true` or
    /// `false`). `false` means the default is in effect.
    static func hasExplicitChoice(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: defaultsKey) != nil
    }

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
    ///
    /// `URL` caches resource values it has read, and that cache is **not**
    /// updated by a `setResourceValues` write to the same path through another
    /// `URL` value. Reading a stale cache is how the round-trip
    /// (set-excluded → read-back) can report the old value right after a change —
    /// both in a test and in the app's own backup-toggle state. Clear the cache
    /// first so this always reflects what's on disk now.
    static func isExcluded(at url: URL) -> Bool {
        var url = url
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup ?? false
    }
}
