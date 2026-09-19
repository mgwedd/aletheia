import Foundation

/// Keeps a rolling set of point-in-time SQLite snapshots inside the data folder,
/// for safe schema migrations, encryption conversions, and update rollback.
///
/// Each snapshot is written with `CommentStore.snapshot(to:)` (SQLite's
/// `VACUUM INTO`), so it's internally consistent even when taken while the app
/// is running, and compacted. Snapshots inherit the live database's at-rest
/// form: when encryption is on, the field values in a snapshot are sealed too.
///
/// Location: `<dataRoot>/.snapshots/` — a dot-directory so it stays clear of the
/// user's transcripts and notes. Retention keeps the most recent `keep` files.
struct DatabaseSnapshotManager {
    let root: URL
    /// How many snapshots to retain; older ones are pruned after each new one.
    var keep: Int = 5
    private let fileManager = FileManager.default

    var directory: URL { root.appendingPathComponent(".snapshots", isDirectory: true) }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// Writes `<.snapshots>/<UTC-stamp>-<reason>.sqlite`, prunes older snapshots
    /// to `keep`, and returns the new file (nil on failure). `reason` is slugged
    /// into the name for provenance, e.g. "pre-encryption-change" or
    /// "pre-update-1.14.0".
    @discardableResult
    func makeSnapshot(of store: CommentStore, reason: String, at date: Date = Date()) -> URL? {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let name = "\(Self.stampFormatter.string(from: date))-\(Self.slug(reason)).sqlite"
        let destination = directory.appendingPathComponent(name)
        // VACUUM INTO refuses to overwrite; clear any same-second collision.
        try? fileManager.removeItem(at: destination)
        guard store.snapshot(to: destination) else { return nil }
        prune()
        return destination
    }

    /// Existing snapshot files, newest first. Names are prefixed with a UTC
    /// timestamp, so a descending filename sort is a time sort — and doesn't
    /// depend on filesystem modification-time granularity.
    func snapshots() -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter { $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Restores a snapshot over the live database file.
    ///
    /// PRECONDITION: no `CommentStore` may be open on `liveURL` — call this
    /// during an update/rollback, before the stores are (re)built. The live file
    /// is replaced atomically; the snapshot itself is left intact. Returns false
    /// on any error.
    @discardableResult
    func restore(_ snapshot: URL, to liveURL: URL) -> Bool {
        guard fileManager.fileExists(atPath: snapshot.path) else { return false }
        do {
            // Give `replaceItemAt` a throwaway copy so the snapshot survives.
            let replacement = fileManager.temporaryDirectory
                .appendingPathComponent("restore-\(UUID().uuidString).sqlite")
            try fileManager.copyItem(at: snapshot, to: replacement)
            if fileManager.fileExists(atPath: liveURL.path) {
                _ = try fileManager.replaceItemAt(liveURL, withItemAt: replacement)
            } else {
                try fileManager.moveItem(at: replacement, to: liveURL)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Helpers

    private func prune() {
        let all = snapshots()
        guard all.count > keep else { return }
        for url in all.dropFirst(keep) { try? fileManager.removeItem(at: url) }
    }

    private static func slug(_ text: String) -> String {
        let mapped = text.lowercased().map { ($0.isLetter || $0.isNumber) ? $0 : "-" }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "snapshot" : collapsed
    }
}
