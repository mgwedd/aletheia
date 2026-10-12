import Foundation
import SQLite3

/// The SQLite-backed `PersistenceCore`: the real generic store that domain
/// repositories persist against, the production counterpart to
/// `InMemoryPersistenceCore`. Everything lives in one table of opaque
/// `PersistedRecord`s — a `payload` blob identified by `(kind, id)` and scoped by
/// `ownerID`/`itemID` — so the store knows nothing clinical. The *domain adapter*
/// above it decides what a `kind` means and how to encode/decode `payload`
/// (including any at-rest field encryption); the core just moves bytes.
///
/// The file lives inside the chosen data folder so it backs up with everything
/// else and never leaves the Mac, and is built on the OS's own `SQLite3` (a
/// system library, no third-party dependency).
///
/// Not internally synchronised: like `InMemoryPersistenceCore`, callers serialise
/// access (the app's core becomes actor-isolated in Arch v2 (5)). `FULLMUTEX`
/// keeps concurrent handle use from corrupting the file, but ordering is the
/// caller's job.
final class SQLitePersistenceCore: PersistenceCore {
    private var db: OpaquePointer?
    /// The database file, retained so a pre-migration snapshot can be written
    /// beside it before a schema upgrade transforms the data.
    private let url: URL

    // SQLite needs to know whether a bound value outlives the call; TRANSIENT
    // tells it to copy, which is always safe here.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Non-throwing convenience kept for existing callers and tests: `nil` on any
    /// failure. Use `init(opening:)` to learn *why* the database couldn't open.
    convenience init?(url: URL) {
        do {
            try self.init(opening: url)
        } catch {
            return nil
        }
    }

    /// Opens (creating and migrating if needed) the database at `url`, or throws a
    /// `DatabaseOpenFailure` saying why it couldn't: a newer schema, a refused or
    /// failed migration, a corrupt file, or a locked/full/unreadable one.
    init(opening url: URL) throws {
        self.url = url
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let openCode = sqlite3_open_v2(url.path, &handle,
                                       SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                                       nil)
        guard openCode == SQLITE_OK else {
            // SQLite may hand back a handle even when the open fails; it must
            // still be closed.
            if let handle { sqlite3_close(handle) }
            throw DatabaseOpenFailure(sqliteCode: openCode)
        }
        db = handle
        // PHI hygiene: zero freed pages so payload bytes from a removed or
        // replaced record can't survive in the file's free space. The bytes are
        // adapter-sealed when encryption is on, but a defence in depth for the
        // plaintext (`.passthrough`) case costs nothing here.
        _ = exec("PRAGMA secure_delete = ON;")
        if let failure = migrateSchema() {
            sqlite3_close(db)
            db = nil
            throw failure
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: - Schema

    /// The database's current schema version (`PRAGMA user_version`); 0 for a
    /// brand-new file or one written before migrations existed.
    var schemaVersion: Int { userVersion() }

    /// Bring the database up to `SchemaMigrator.latestVersion`, or refuse to open
    /// a file a newer build wrote. Returns nil on success, or the
    /// `DatabaseOpenFailure` that makes `init(opening:)` throw (and the legacy
    /// `init?(url:)` return nil). A newer database is left untouched.
    private func migrateSchema() -> DatabaseOpenFailure? {
        // A file that isn't a database (or is damaged) fails on this first read,
        // which is how corruption is told apart from an ordinary empty database.
        let read = readUserVersion()
        guard let current = read.version else {
            return failure(code: read.code, fallback: .cannotOpen)
        }
        switch SchemaMigrator.plan(current: current) {
        case .upToDate:
            return nil
        case .needsNewerApp(let dataVersion, let appVersion):
            // Written by a newer app; an older schema must not silently rewrite
            // it. The file-level `SchemaCompatibility` guard surfaces the
            // "please update" message; here we just decline to open.
            return DatabaseOpenFailure(
                kind: .schemaNewerThanApp,
                reason: "Database format v\(dataVersion); this version of Aletheia understands up to v\(appVersion).",
                dataVersion: dataVersion,
                appVersion: appVersion
            )
        case .migrate(let steps, let target):
            // Never transform existing data without a recoverable pre-image.
            // For a database that already holds data (current > 0), snapshot it
            // first; if that snapshot can't be written, refuse to migrate and
            // leave the data untouched at its old version, rather than upgrade
            // with no way back (docs/DATA-SAFETY.md). A fresh/baseline database
            // (current 0) has nothing to protect, so no snapshot is taken.
            if let backupURL = MigrationBackup.snapshotURL(forDatabaseAt: url, fromVersion: current),
               let problem = takePreMigrationImage(to: backupURL) {
                let code = sqlite3_extended_errcode(db)
                let detail = code == SQLITE_OK ? "" : " (\(DatabaseOpenFailure.describe(sqliteCode: code)))"
                let what: String
                switch problem {
                case .database: what = "the database"
                case .files: what = "the patient and session files"
                }
                return DatabaseOpenFailure(
                    kind: .migrationRefused,
                    reason: "Couldn't write the safety copy of \(what) needed before upgrading the database from v\(current) to v\(target)\(detail).",
                    sqliteCode: code == SQLITE_OK ? nil : code,
                    dataVersion: current,
                    appVersion: target
                )
            }
            // One transaction: either the schema reaches `target` or nothing
            // changes. DDL is transactional in SQLite, and every step is
            // idempotent, so re-running after an interrupted upgrade is safe.
            guard exec("BEGIN;") else { return currentFailure(fallback: .migrationFailed) }
            for step in steps {
                guard exec(step.sql) else {
                    let failure = currentFailure(fallback: .migrationFailed)
                    _ = exec("ROLLBACK;")
                    return failure
                }
            }
            guard exec("PRAGMA user_version = \(target);") else {
                let failure = currentFailure(fallback: .migrationFailed)
                _ = exec("ROLLBACK;")
                return failure
            }
            guard exec("COMMIT;") else { return currentFailure(fallback: .migrationFailed) }
            return nil
        }
    }

    /// The failure for whatever SQLite last reported on this connection. A code
    /// that maps to a specific kind (corrupt, locked/full, unreadable) keeps it;
    /// anything else takes `fallback`.
    private func currentFailure(fallback: DatabaseOpenFailure.Kind) -> DatabaseOpenFailure {
        failure(code: sqlite3_extended_errcode(db), fallback: fallback)
    }

    private func failure(code: Int32, fallback: DatabaseOpenFailure.Kind) -> DatabaseOpenFailure {
        let classified = DatabaseOpenFailure(sqliteCode: code)
        guard classified.kind == .unknown else { return classified }
        return DatabaseOpenFailure(kind: fallback, reason: classified.reason, sqliteCode: code)
    }

    /// Reads `PRAGMA user_version` (0 if it can't be read).
    private func userVersion() -> Int { readUserVersion().version ?? 0 }

    /// Reads `PRAGMA user_version`. `version` is nil when SQLite can't read the
    /// database at all (e.g. the file isn't a database, or is damaged), in which
    /// case `code` is the SQLite result code, captured before the statement is
    /// finalized.
    private func readUserVersion() -> (version: Int?, code: Int32) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else {
            return (nil, sqlite3_extended_errcode(db))
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return (Int(sqlite3_column_int(stmt, 0)), SQLITE_OK)
        }
        return (nil, sqlite3_extended_errcode(db))
    }

    /// Takes the pre-migration image: a consistent copy of the database
    /// (`VACUUM INTO`) plus a copy of the data folder's `patient.json` and
    /// `session.json` files, so a restore returns both to one point. Creates the
    /// `.backups/migrations/` directory (folding in any legacy `Backups/` first,
    /// best-effort) and never overwrites an existing pre-image. Returns nil on
    /// success; any failure aborts the migration, and a half-written image is
    /// removed so every listed pre-image is complete.
    func takePreMigrationImage(to destination: URL) -> PreImageFailure? {
        // Best-effort: a legacy-folder problem must never block (or fake) a pre-image.
        let dataRoot = url.deletingLastPathComponent()
        BackupLayout.adoptLegacy(dataRoot: dataRoot)
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return .database }
        guard snapshot(to: destination) else { return .database }
        // The small structured JSON a migration could also rewrite goes into the
        // same pre-image, so a restore returns database and files to one point.
        do {
            try MigrationBackup.copyStructuredJSON(
                fromDataRoot: dataRoot, to: MigrationBackup.filesBundleURL(forSnapshot: destination))
        } catch {
            // Never leave a pre-image that is only half there.
            try? FileManager.default.removeItem(at: destination)
            return .files(error.localizedDescription)
        }
        return nil
    }

    enum PreImageFailure: Equatable {
        case database
        case files(String)
    }

    // MARK: - PersistenceCore

    func record(kind: String, id: String) -> PersistedRecord? {
        let sql = "SELECT kind, id, owner_id, item_id, payload, created_at, updated_at FROM records WHERE kind = ? AND id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, kind)
        bindText(stmt, 2, id)
        return sqlite3_step(stmt) == SQLITE_ROW ? row(stmt) : nil
    }

    func records(kind: String, itemID: UUID) -> [PersistedRecord] {
        query("SELECT kind, id, owner_id, item_id, payload, created_at, updated_at FROM records WHERE kind = ? AND item_id = ? ORDER BY created_at ASC;",
              kind: kind, scope: itemID.uuidString)
    }

    func records(kind: String, ownerID: UUID) -> [PersistedRecord] {
        query("SELECT kind, id, owner_id, item_id, payload, created_at, updated_at FROM records WHERE kind = ? AND owner_id = ? ORDER BY created_at ASC;",
              kind: kind, scope: ownerID.uuidString)
    }

    func allRecords(kind: String) -> [PersistedRecord] {
        let sql = "SELECT kind, id, owner_id, item_id, payload, created_at, updated_at FROM records WHERE kind = ? ORDER BY created_at ASC;"
        var result: [PersistedRecord] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, kind)
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(row(stmt))
        }
        return result
    }

    @discardableResult
    func put(_ record: PersistedRecord) -> Bool {
        // INSERT OR REPLACE swaps the whole row by (kind, id), matching the
        // in-memory core's "replace by identity" semantics; the caller's
        // created_at/updated_at are stored verbatim.
        let sql = "INSERT OR REPLACE INTO records (kind, id, owner_id, item_id, payload, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, record.kind)
        bindText(stmt, 2, record.id)
        bindOptionalText(stmt, 3, record.ownerID?.uuidString)
        bindOptionalText(stmt, 4, record.itemID?.uuidString)
        bindBlob(stmt, 5, record.payload)
        sqlite3_bind_double(stmt, 6, record.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 7, record.updatedAt.timeIntervalSince1970)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    @discardableResult
    func remove(kind: String, id: String) -> Bool {
        let sql = "DELETE FROM records WHERE kind = ? AND id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, kind)
        bindText(stmt, 2, id)
        // DELETE of an absent row still reports DONE, so "already gone" is a
        // success — the same contract the in-memory core honours.
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    // MARK: - Snapshot

    /// Writes a consistent, compact copy of the store to `destination` using
    /// SQLite's `VACUUM INTO` — safe to call while open, and never a half-written
    /// file. `destination` must not already exist and its parent must. Returns
    /// false on any SQLite error.
    @discardableResult
    func snapshot(to destination: URL) -> Bool {
        // VACUUM INTO takes a string literal, not a bound parameter; escape any
        // single quotes so the path stays a safe single-quoted literal.
        let escaped = destination.path.replacingOccurrences(of: "'", with: "''")
        return exec("VACUUM INTO '\(escaped)';")
    }

    // MARK: - Row / query helpers

    private func query(_ sql: String, kind: String, scope: String) -> [PersistedRecord] {
        var result: [PersistedRecord] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, kind)
        bindText(stmt, 2, scope)
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(row(stmt))
        }
        return result
    }

    /// Builds a `PersistedRecord` from the 7-column projection used by every read.
    private func row(_ stmt: OpaquePointer?) -> PersistedRecord {
        PersistedRecord(
            id: columnText(stmt, 1),
            kind: columnText(stmt, 0),
            ownerID: columnUUID(stmt, 2),
            itemID: columnUUID(stmt, 3),
            payload: columnBlob(stmt, 4),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
        )
    }

    // MARK: - SQLite helpers

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, Self.transient)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value { bindText(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
    }

    private func bindBlob(_ stmt: OpaquePointer?, _ index: Int32, _ data: Data) {
        // An empty Data has no stable base address, and a NULL blob pointer would
        // bind SQL NULL — which the NOT NULL payload column rejects. Bind an
        // explicit zero-length BLOB so an empty payload stays a value, not NULL.
        if data.isEmpty {
            sqlite3_bind_zeroblob(stmt, index, 0)
        } else {
            data.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(raw.count), Self.transient)
            }
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }

    private func columnUUID(_ stmt: OpaquePointer?, _ index: Int32) -> UUID? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return UUID(uuidString: columnText(stmt, index))
    }

    private func columnBlob(_ stmt: OpaquePointer?, _ index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(stmt, index) else { return Data() }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return Data(bytes: bytes, count: count)
    }
}
