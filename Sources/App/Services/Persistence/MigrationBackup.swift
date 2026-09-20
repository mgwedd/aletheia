import Foundation

/// Pre-migration safety: before a schema upgrade transforms a clinician's data,
/// the database is snapshotted to a retained, versioned pre-image so a bad
/// migration is always recoverable. This type is the pure policy — *where* a
/// snapshot goes and *which* old snapshots may be pruned — while the core takes
/// the actual snapshot via `VACUUM INTO`.
///
/// The rule (see docs/DATA-SAFETY.md): **never migrate without a pre-image, and
/// never prune a pre-image until the clinician has attested the migrated data is
/// correct.** So snapshots are created here and kept indefinitely; pruning is a
/// separate, attestation-gated step the UI drives later via `prunable(_:...)`.
///
/// Snapshots live in a `Backups/` sub-directory of the data folder, so #91's
/// system-backup exclusion (applied to the whole data root) already covers them,
/// and the same encryption protector that seals live payloads sealed theirs.
enum MigrationBackup {
    /// Sub-directory, beside the database, that holds pre-migration snapshots.
    static let directoryName = "Backups"
    static let fileExtension = "sqlite"
    /// Marker in a snapshot's file name, between the base name and the version.
    private static let marker = "-pre-v"

    /// The backups directory for a given database file.
    static func directory(for dbURL: URL) -> URL {
        dbURL.deletingLastPathComponent().appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Where to snapshot a database at `fromVersion` before upgrading it, or nil
    /// when there's nothing to protect: a brand-new or baseline database
    /// (`fromVersion <= 0`) holds no prior data a migration could corrupt, so no
    /// pre-image is taken.
    static func snapshotURL(forDatabaseAt dbURL: URL, fromVersion: Int, now: Date = Date()) -> URL? {
        guard fromVersion > 0 else { return nil }
        let base = dbURL.deletingPathExtension().lastPathComponent
        let name = "\(base)\(marker)\(fromVersion)-\(stamp(now)).\(fileExtension)"
        return directory(for: dbURL).appendingPathComponent(name)
    }

    /// Parses a snapshot file name back into the version it was taken *from* and
    /// when, or nil if the URL isn't a snapshot this type wrote. Robust to a base
    /// name that itself contains dashes (it anchors on the last `-pre-v`).
    static func metadata(of url: URL) -> (fromVersion: Int, createdAt: Date)? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let range = name.range(of: marker, options: .backwards) else { return nil }
        let suffix = name[range.upperBound...]                 // "<version>-<stamp>"
        guard let dash = suffix.firstIndex(of: "-") else { return nil }
        guard let version = Int(suffix[..<dash]) else { return nil }
        guard let date = parseStamp(String(suffix[suffix.index(after: dash)...])) else { return nil }
        return (version, date)
    }

    /// Of the given snapshot URLs, the ones safe to delete: keep the
    /// `keepMostRecent` newest (by capture time) and return the rest for the
    /// caller to delete. Pure — it deletes nothing. Files it can't parse as
    /// snapshots are never returned, so unrelated files are safe in the folder.
    static func prunable(_ urls: [URL], keepMostRecent keep: Int) -> [URL] {
        let dated = urls.compactMap { url -> (url: URL, at: Date)? in
            metadata(of: url).map { (url, $0.createdAt) }
        }
        guard dated.count > max(0, keep) else { return [] }
        return dated
            .sorted { $0.at > $1.at }          // newest first
            .dropFirst(max(0, keep))           // keep the newest `keep`
            .map(\.url)
    }

    // MARK: - Timestamp (filesystem-safe, sortable, UTC)

    static func stamp(_ date: Date) -> String { stampFormatter.string(from: date) }

    private static func parseStamp(_ s: String) -> Date? { stampFormatter.date(from: s) }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()
}
