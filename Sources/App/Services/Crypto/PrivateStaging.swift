import Foundation

/// The app's scratch space for decrypted or patient-derived temporary files
/// (a decrypted recording, a plaintext database copy, a restore in progress).
///
/// It is a private folder inside the app container, not the shared
/// `temporaryDirectory`: the folder is `0700`, every file in it is `0600`, and
/// whatever a crash leaves behind is removed at the next launch. Callers remove
/// their own file as soon as they are done with it.
///
/// This is the only place allowed to name the shared temporary directory
/// (`PrivateStagingUsageTests` enforces that).
enum PrivateStaging {
    /// The scratch folder. Deliberately not under `Store.stagingDirectoryURL`:
    /// the crash-recovery sweep treats every folder there as a recording.
    /// Tests point it at a throwaway folder.
    nonisolated(unsafe) static var root: URL = defaultRoot()

    /// The default scratch folder. A process hosting unit tests runs in the same
    /// container as the real app, so it gets its own folder: a sweep run by a
    /// test can never remove a file the real app is using.
    static func defaultRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aletheia", isDirectory: true)
            .appendingPathComponent(TestHost.isHostingTests(environment: environment) ? "ScratchTests" : "Scratch", isDirectory: true)
    }

    /// When this process first used the scratch space. The launch sweep only
    /// removes older files, so it can never take one that is in use now.
    private static let startedAt = Date()

    /// The shared temporary folder older builds used for decrypted copies. Only
    /// the launch sweep looks here, to clear what those builds left behind.
    static var legacyTemporaryDirectory: URL { FileManager.default.temporaryDirectory }

    /// Creates `url` (and missing parents) as a `0700` folder and re-applies the
    /// mode in case it already existed looser.
    static func ensurePrivateDirectory(_ url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// `ensurePrivateDirectory` for a root that holds plaintext patient data:
    /// the folder is also kept out of Time Machine and other backups.
    static func ensureBackupExcludedRoot(_ url: URL) throws {
        try ensurePrivateDirectory(url)
        BackupExclusion.markExcluded(url)
    }

    /// A fresh, empty `0600` file in the scratch folder. The caller writes to it
    /// and removes it with `remove(_:)`.
    static func scratchFile(prefix: String, ext: String) throws -> URL {
        _ = startedAt
        try ensureBackupExcludedRoot(root)
        let url = root.appendingPathComponent("\(prefix)-\(UUID().uuidString).\(ext)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    /// Removes a scratch file. Safe to call for a file that is already gone.
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Launch sweep: removes everything in the scratch folder that predates this
    /// process, then the `aletheia-*.caf` copies older builds left in the shared
    /// temporary folder. Returns how many items were removed.
    @discardableResult
    static func sweep(
        root: URL = PrivateStaging.root,
        legacyTemporaryDirectory: URL = PrivateStaging.legacyTemporaryDirectory,
        olderThan cutoff: Date? = nil
    ) -> Int {
        let fm = FileManager.default
        let limit = cutoff ?? startedAt
        var removed = 0
        let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey])) ?? []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let touched = [values?.creationDate, values?.contentModificationDate].compactMap { $0 }.max()
            if let touched, touched >= limit { continue }
            if (try? fm.removeItem(at: entry)) != nil { removed += 1 }
        }
        for file in (try? fm.contentsOfDirectory(at: legacyTemporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent.hasPrefix("aletheia-") && file.pathExtension == "caf" {
            if (try? fm.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }
}
