import Foundation

/// The single source of truth for where Aletheia keeps every kind of local
/// backup. No other type hard-codes a backup path — they all ask this one.
///
/// ```
/// <dataRoot>/
///   .backups/                     ← the ONE backup home (hidden dot-folder)
///     migrations/                 ← schema-migration pre-images  (MigrationBackup)
///     snapshots/                  ← rolling DB snapshots, newest 5 (DatabaseSnapshotManager)
///     archives/                   ← end-to-end-encrypted archives (LocalEncryptedBackupService)
/// ```
///
/// Each kind has its own sub-folder so its retention rule can only ever see its
/// own files: the rolling-5 snapshot prune cannot touch an archive or a
/// migration pre-image, because it never lists them.
///
/// The whole data root is what Time Machine sees (and what
/// `BackupExclusion`/`AppSettings` mark in or out); this layout deliberately
/// does not change that — `.backups/` is simply a subtree of it.
///
/// Legacy layout (older builds): `<dataRoot>/Backups/` (migrations),
/// `<dataRoot>/.snapshots/` (snapshots) and archives directly in
/// `<dataRoot>/.backups/`. `adoptLegacy(dataRoot:)` moves those into the layout
/// above; the components call it before they list or write, so an upgraded
/// install is folded in on first use.
enum BackupLayout {
    /// The single backup home, a dot-folder directly under the data root.
    static let rootName = ".backups"

    /// The kinds of backup, each with its own sub-folder of `.backups/`.
    enum Kind: String, CaseIterable {
        /// Pre-images taken before a schema migration (`MigrationBackup`).
        case migrations
        /// Rolling point-in-time DB snapshots (`DatabaseSnapshotManager`).
        case snapshots
        /// End-to-end-encrypted archives (`LocalEncryptedBackupService`).
        case archives

        var folderName: String { rawValue }
    }

    /// Old locations, relative to the data root, that `adoptLegacy` folds in.
    static let legacyMigrationsFolderName = "Backups"
    static let legacySnapshotsFolderName = ".snapshots"

    static func root(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent(rootName, isDirectory: true)
    }

    static func directory(_ kind: Kind, dataRoot: URL) -> URL {
        root(dataRoot: dataRoot).appendingPathComponent(kind.folderName, isDirectory: true)
    }

    // MARK: - Legacy adoption

    /// What one `adoptLegacy` run did. Paths are relative to the data root so the
    /// Doctor screen can show them as-is. `Equatable` for tests.
    struct LegacyAdoption: Equatable {
        /// Files moved into the new layout (old relative path).
        var moved: [String] = []
        /// Files left where they were because the destination name already
        /// exists (never overwritten).
        var skippedCollisions: [String] = []
        /// Files left where they were because the move (or creating its
        /// destination folder) failed.
        var failed: [String] = []
        /// Old directories removed because they were empty afterwards.
        var removedDirectories: [String] = []

        /// True when this run left nothing behind in an old location.
        var isClean: Bool { skippedCollisions.isEmpty && failed.isEmpty }
        /// True when this run changed anything on disk.
        var didWork: Bool { !moved.isEmpty || !removedDirectories.isEmpty }
    }

    /// Folds the legacy backup locations into `.backups/<kind>/`.
    ///
    /// - `Backups/*`         → `.backups/migrations/`
    /// - `.snapshots/*`      → `.backups/snapshots/`
    /// - `.backups/*.aletheiabackup` (archives written flat by earlier builds)
    ///                       → `.backups/archives/`
    ///
    /// Safety rules (this is user data):
    /// - each file moves with `FileManager.moveItem` — a rename on the same
    ///   volume, so it is atomic per file;
    /// - a name that already exists at the destination is skipped, never
    ///   overwritten;
    /// - nothing is deleted except an old directory that is empty afterwards
    ///   (a lone Finder `.DS_Store` doesn't count as content — `Backups/` was
    ///   visible in Finder — and goes with it);
    /// - never throws: every failure is recorded in the result and the file is
    ///   left where it was.
    ///
    /// Idempotent: a second run over an already-adopted (or fresh) root does
    /// nothing. Cheap when there is nothing to do (a few existence checks), so
    /// it is safe to call on every first access.
    @discardableResult
    static func adoptLegacy(dataRoot: URL, fileManager fm: FileManager = .default) -> LegacyAdoption {
        var result = LegacyAdoption()
        adopt(fromFolder: legacyMigrationsFolderName, into: .migrations, dataRoot: dataRoot, fm: fm,
              onlyExtension: nil, removeSourceWhenEmpty: true, result: &result)
        adopt(fromFolder: legacySnapshotsFolderName, into: .snapshots, dataRoot: dataRoot, fm: fm,
              onlyExtension: nil, removeSourceWhenEmpty: true, result: &result)
        // Flat archives directly under `.backups/`. That folder is the new root,
        // so it is never removed.
        adopt(fromFolder: rootName, into: .archives, dataRoot: dataRoot, fm: fm,
              onlyExtension: EncryptedBackupArchive.fileExtension, removeSourceWhenEmpty: false, result: &result)
        return result
    }

    private static func adopt(
        fromFolder folderName: String, into kind: Kind, dataRoot: URL, fm: FileManager,
        onlyExtension: String?, removeSourceWhenEmpty: Bool, result: inout LegacyAdoption
    ) {
        let source = dataRoot.appendingPathComponent(folderName, isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else { return }
        guard let entries = try? fm.contentsOfDirectory(atPath: source.path) else { return }

        let destination = directory(kind, dataRoot: dataRoot)
        var destinationReady = false

        for name in entries.sorted() where name != ".DS_Store" {
            if let onlyExtension, (name as NSString).pathExtension != onlyExtension { continue }
            let from = source.appendingPathComponent(name)
            let to = destination.appendingPathComponent(name)
            let relative = "\(folderName)/\(name)"

            if fm.fileExists(atPath: to.path) {
                result.skippedCollisions.append(relative)
                continue
            }
            if !destinationReady {
                do {
                    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                    destinationReady = true
                } catch {
                    result.failed.append(relative)
                    continue
                }
            }
            do {
                try fm.moveItem(at: from, to: to)
                result.moved.append(relative)
            } catch {
                result.failed.append(relative)
            }
        }

        guard removeSourceWhenEmpty else { return }
        // Remove the old directory only when nothing but Finder's `.DS_Store`
        // (metadata, not user data) remains; anything else stays where it is.
        guard let remaining = try? fm.contentsOfDirectory(atPath: source.path),
              remaining.allSatisfy({ $0 == ".DS_Store" }) else { return }
        for junk in remaining { try? fm.removeItem(at: source.appendingPathComponent(junk)) }
        // `removeItem` on a directory is recursive, so re-check that it is
        // truly empty before removing it.
        guard (try? fm.contentsOfDirectory(atPath: source.path))?.isEmpty == true else { return }
        if (try? fm.removeItem(at: source)) != nil {
            result.removedDirectories.append(folderName)
        }
    }
}
