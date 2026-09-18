import Foundation
import SQLite3

/// One margin comment the therapist anchored to a piece of a transcript
/// (Google-Docs style). `quotedText` is the passage it's attached to; `body` is
/// what the therapist wrote.
struct SessionComment: Identifiable, Equatable {
    let id: String
    var quotedText: String
    var body: String
    let createdAt: Date
    var updatedAt: Date
}

/// Local database for the therapist's own annotations — inline transcript
/// comments and freeform per-session notes. These are PHI, and the user asked
/// for a real local database, so this is SQLite living *inside the chosen data
/// folder* (`<dataRoot>/SessionNotes.sqlite`) — it backs up with everything
/// else and never leaves the Mac. Built on the OS's own `SQLite3` (a system
/// library, no third-party dependency).
///
/// Keyed by `<patientSlug>/<sessionFolder>`, which is unique per session and
/// stable across reloads, so annotations follow the session even though
/// `SessionRecord`s are rebuilt from disk each listing.
final class CommentStore {
    private var db: OpaquePointer?
    /// Seals the PHI text columns (comment quote/body, note body) before they're
    /// bound, and opens them on read. No SQLCipher: the DB file, schema, keys and
    /// timestamps stay a normal SQLite file — only the free-text values are
    /// sealed. `.passthrough` (the default) stores plain text, unchanged.
    private let protector: FileProtector

    // SQLite wants to know whether a bound string outlives the call; TRANSIENT
    // tells it to copy, which is always safe here.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(root: URL, protector: FileProtector = .passthrough) {
        self.protector = protector
        let url = root.appendingPathComponent("SessionNotes.sqlite")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            return nil
        }
        guard createSchema() else {
            sqlite3_close(db)
            return nil
        }
    }

    deinit { sqlite3_close(db) }

    static func sessionKey(patientSlug: String, sessionFolder: String) -> String {
        "\(patientSlug)/\(sessionFolder)"
    }

    // MARK: - Schema

    private func createSchema() -> Bool {
        let sql = """
        CREATE TABLE IF NOT EXISTS comments (
            id TEXT PRIMARY KEY,
            session_key TEXT NOT NULL,
            quoted_text TEXT NOT NULL,
            body TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_comments_session ON comments(session_key);
        CREATE TABLE IF NOT EXISTS notes (
            session_key TEXT PRIMARY KEY,
            body TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        """
        return exec(sql)
    }

    // MARK: - Comments

    func comments(patientSlug: String, sessionFolder: String) -> [SessionComment] {
        let key = Self.sessionKey(patientSlug: patientSlug, sessionFolder: sessionFolder)
        var result: [SessionComment] = []
        let sql = "SELECT id, quoted_text, body, created_at, updated_at FROM comments WHERE session_key = ? ORDER BY created_at ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(
                SessionComment(
                    id: columnText(stmt, 0),
                    quotedText: decodeField(columnText(stmt, 1)),
                    body: decodeField(columnText(stmt, 2)),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                )
            )
        }
        return result
    }

    @discardableResult
    func addComment(patientSlug: String, sessionFolder: String, quotedText: String, body: String, now: Date = Date()) -> SessionComment? {
        let comment = SessionComment(id: UUID().uuidString, quotedText: quotedText, body: body, createdAt: now, updatedAt: now)
        let key = Self.sessionKey(patientSlug: patientSlug, sessionFolder: sessionFolder)
        let sql = "INSERT INTO comments (id, session_key, quoted_text, body, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, comment.id)
        bindText(stmt, 2, key)
        bindText(stmt, 3, encodeField(quotedText))
        bindText(stmt, 4, encodeField(body))
        sqlite3_bind_double(stmt, 5, now.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 6, now.timeIntervalSince1970)
        return sqlite3_step(stmt) == SQLITE_DONE ? comment : nil
    }

    @discardableResult
    func updateComment(id: String, body: String, now: Date = Date()) -> Bool {
        let sql = "UPDATE comments SET body = ?, updated_at = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, encodeField(body))
        sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
        bindText(stmt, 3, id)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    @discardableResult
    func deleteComment(id: String) -> Bool {
        let sql = "DELETE FROM comments WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    // MARK: - Notes

    func note(patientSlug: String, sessionFolder: String) -> String {
        let key = Self.sessionKey(patientSlug: patientSlug, sessionFolder: sessionFolder)
        let sql = "SELECT body FROM notes WHERE session_key = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return "" }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        return sqlite3_step(stmt) == SQLITE_ROW ? decodeField(columnText(stmt, 0)) : ""
    }

    @discardableResult
    func saveNote(patientSlug: String, sessionFolder: String, text: String, now: Date = Date()) -> Bool {
        let key = Self.sessionKey(patientSlug: patientSlug, sessionFolder: sessionFolder)
        let sql = """
        INSERT INTO notes (session_key, body, updated_at) VALUES (?, ?, ?)
        ON CONFLICT(session_key) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        bindText(stmt, 2, encodeField(text))
        sqlite3_bind_double(stmt, 3, now.timeIntervalSince1970)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    // MARK: - Field encryption

    /// Seals a text value for storage when encryption is on, as base64 of the
    /// envelope. With encryption off (passthrough) the value is stored as plain
    /// text, exactly as before — so existing databases are unchanged.
    private func encodeField(_ text: String) -> String {
        guard protector.isEncrypting, let sealed = try? protector.seal(Data(text.utf8)) else { return text }
        return sealed.base64EncodedString()
    }

    /// Reverses `encodeField`. A stored value is decrypted only when it base64-
    /// decodes to one of our envelopes; anything else (legacy plain text, or a
    /// value written while encryption was off) is returned as-is, so a folder
    /// migrates lazily. A present-but-undecryptable envelope means the DB is
    /// open while locked; that's a misconfiguration the stores gate against.
    private func decodeField(_ stored: String) -> String {
        guard
            let data = Data(base64Encoded: stored),
            DataCipher.isEnvelope(data),
            let opened = try? protector.open(data)
        else { return stored }
        return String(decoding: opened, as: UTF8.self)
    }

    // MARK: - SQLite helpers

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, Self.transient)
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }
}
