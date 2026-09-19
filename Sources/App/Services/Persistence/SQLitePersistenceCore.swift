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

    // SQLite needs to know whether a bound value outlives the call; TRANSIENT
    // tells it to copy, which is always safe here.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK else {
            return nil
        }
        // PHI hygiene: zero freed pages so payload bytes from a removed or
        // replaced record can't survive in the file's free space. The bytes are
        // adapter-sealed when encryption is on, but a defence in depth for the
        // plaintext (`.passthrough`) case costs nothing here.
        _ = exec("PRAGMA secure_delete = ON;")
        guard createSchema() else {
            sqlite3_close(db)
            return nil
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: - Schema

    private func createSchema() -> Bool {
        exec("""
        CREATE TABLE IF NOT EXISTS records (
            kind TEXT NOT NULL,
            id TEXT NOT NULL,
            owner_id TEXT,
            item_id TEXT,
            payload BLOB NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY (kind, id)
        );
        CREATE INDEX IF NOT EXISTS idx_records_kind_item ON records(kind, item_id);
        CREATE INDEX IF NOT EXISTS idx_records_kind_owner ON records(kind, owner_id);
        """)
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
