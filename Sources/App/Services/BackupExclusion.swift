import Foundation

/// Marks a folder as excluded from system backups via the
/// `isExcludedFromBackup` resource value — which keeps it out of Time Machine
/// and out of iCloud's device backup.
///
/// By default the data folder is **kept out** of system backups: Aletheia keeps
/// its own encrypted backup archives, and the folder can hold plaintext PHI when
/// at-rest encryption is off. A clinician who prefers Time Machine to include the
/// folder can turn the exclusion off (and should use an **encrypted disk**).
enum BackupExclusion {
    /// The `UserDefaults` key holding the user's explicit choice.
    static let defaultsKey = "keepDataOutOfSystemBackups"

    /// The switch's label in Settings > Backups, also quoted by the Doctor.
    static let settingTitle = "Keep my data out of Time Machine & iCloud backups"

    /// What applies when the user has never chosen: exclude the data folder.
    static let defaultExcluded = true

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
    ///
    /// Writes the attribute behind `isExcludedFromBackup` (Time Machine's sticky
    /// exclusion) directly, so the change is on disk when this returns. Going
    /// through `setResourceValues` instead applies it late on some volumes and
    /// not at all inside the App Sandbox container, so a quick off-then-on could
    /// read back the old value or be undone by the earlier write landing late.
    static func setExcluded(_ excluded: Bool, at url: URL) throws {
        let written: Bool = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            guard excluded else { return removexattr(path, markerName, 0) == 0 || errno == ENOATTR }
            guard let value = try? PropertyListSerialization.data(
                fromPropertyList: "com.apple.backupd", format: .binary, options: 0) else { return false }
            return value.withUnsafeBytes { setxattr(path, markerName, $0.baseAddress, value.count, 0, 0) } == 0
        }
        guard written else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
    }

    private static let markerName = "com.apple.metadata:com_apple_backup_excludeItem"

    /// Marks `url` excluded from backups, ignoring failure. For folders the app
    /// creates itself and can still use if the flag can't be written.
    static func markExcluded(_ url: URL) {
        try? setExcluded(true, at: url)
    }

    /// Whether `url` is currently marked excluded from backups: whether it
    /// carries the sticky-exclusion attribute. `false` when it can't be read.
    static func isExcluded(at url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            path.map { getxattr($0, markerName, nil, 0, 0, 0) >= 0 } ?? false
        }
    }
}
