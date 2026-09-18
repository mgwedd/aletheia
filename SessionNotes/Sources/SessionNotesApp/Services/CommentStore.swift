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
    /// Seconds into the session that this comment's passage falls at, derived
    /// from the transcript's time codes when the comment is created. nil when the
    /// passage couldn't be located (e.g. no quote, or a hand-typed passage).
    var anchorSeconds: Double?

    init(
        id: String,
        quotedText: String,
        body: String,
        createdAt: Date,
        updatedAt: Date,
        anchorSeconds: Double? = nil
    ) {
        self.id = id
        self.quotedText = quotedText
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.anchorSeconds = anchorSeconds
    }
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

    /// The database file for a given data folder — the single SQLite store all
    /// annotations, notes, and chat threads live in.
    static func databaseURL(root: URL) -> URL {
        root.appendingPathComponent("SessionNotes.sqlite")
    }

    init?(root: URL, protector: FileProtector = .passthrough) {
        self.protector = protector
        let url = Self.databaseURL(root: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            return nil
        }
        // PHI hygiene: zero freed pages and cells so plaintext that's deleted or
        // re-sealed (a removed comment, a thread re-encrypted on an encryption
        // toggle) can't survive in the file's free space and be recovered.
        _ = exec("PRAGMA secure_delete = ON;")
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
            updated_at REAL NOT NULL,
            anchor_seconds REAL
        );
        CREATE INDEX IF NOT EXISTS idx_comments_session ON comments(session_key);
        CREATE TABLE IF NOT EXISTS notes (
            session_key TEXT PRIMARY KEY,
            body TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS chat_threads (
            id TEXT PRIMARY KEY,
            patient_slug TEXT NOT NULL,
            title TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            messages TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_chat_threads_patient ON chat_threads(patient_slug);
        """
        guard exec(sql) else { return false }
        // A database created before time anchors won't have the column; add it.
        // (It's nullable, so existing comments simply have no anchor.)
        ensureColumn("anchor_seconds", type: "REAL", on: "comments")
        return true
    }

    /// Adds a column to a table if it isn't already there, so older databases
    /// upgrade in place. Ignores the "duplicate column" case by checking first.
    private func ensureColumn(_ column: String, type: String, on table: String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else { return }
        var present = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if columnText(stmt, 1) == column { present = true }
        }
        sqlite3_finalize(stmt)
        if !present { _ = exec("ALTER TABLE \(table) ADD COLUMN \(column) \(type);") }
    }

    // MARK: - Comments

    func comments(patientSlug: String, sessionFolder: String) -> [SessionComment] {
        let key = Self.sessionKey(patientSlug: patientSlug, sessionFolder: sessionFolder)
        var result: [SessionComment] = []
        let sql = "SELECT id, quoted_text, body, created_at, updated_at, anchor_seconds FROM comments WHERE session_key = ? ORDER BY created_at ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let anchor = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 5)
            result.append(
                SessionComment(
                    id: columnText(stmt, 0),
                    quotedText: decodeField(columnText(stmt, 1)),
                    body: decodeField(columnText(stmt, 2)),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                    anchorSeconds: anchor
                )
            )
        }
        return result
    }

    @discardableResult
    func addComment(patientSlug: String, sessionFolder: String, quotedText: String, body: String, anchorSeconds: Double? = nil, now: Date = Date()) -> SessionComment? {
        let comment = SessionComment(id: UUID().uuidString, quotedText: quotedText, body: body, createdAt: now, updatedAt: now, anchorSeconds: anchorSeconds)
        let key = Self.sessionKey(patientSlug: patientSlug, sessionFolder: sessionFolder)
        let sql = "INSERT INTO comments (id, session_key, quoted_text, body, created_at, updated_at, anchor_seconds) VALUES (?, ?, ?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, comment.id)
        bindText(stmt, 2, key)
        bindText(stmt, 3, encodeField(quotedText))
        bindText(stmt, 4, encodeField(body))
        sqlite3_bind_double(stmt, 5, now.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 6, now.timeIntervalSince1970)
        if let anchorSeconds { sqlite3_bind_double(stmt, 7, anchorSeconds) } else { sqlite3_bind_null(stmt, 7) }
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

    // MARK: - Chat threads

    /// A patient's chat threads, most-recently-active first. Titles and the
    /// message payload are sealed per-field like every other PHI column.
    func chatThreads(patientSlug: String) -> [ChatThread] {
        var result: [ChatThread] = []
        let sql = "SELECT id, title, created_at, updated_at, messages FROM chat_threads WHERE patient_slug = ? ORDER BY updated_at DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, patientSlug)
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = UUID(uuidString: columnText(stmt, 0)) else { continue }
            result.append(
                ChatThread(
                    id: id,
                    title: decodeField(columnText(stmt, 1)),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                    messages: decodeMessages(columnText(stmt, 4))
                )
            )
        }
        return result
    }

    /// Inserts a thread or updates it in place (by id). `created_at` and the
    /// owning patient are fixed at insert; edits carry title/messages/updated_at.
    @discardableResult
    func saveChatThread(_ thread: ChatThread, patientSlug: String) -> Bool {
        let sql = """
        INSERT INTO chat_threads (id, patient_slug, title, created_at, updated_at, messages)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            updated_at = excluded.updated_at,
            messages = excluded.messages;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, thread.id.uuidString)
        bindText(stmt, 2, patientSlug)
        bindText(stmt, 3, encodeField(thread.title))
        sqlite3_bind_double(stmt, 4, thread.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 5, thread.updatedAt.timeIntervalSince1970)
        bindText(stmt, 6, encodeMessages(thread.messages))
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    @discardableResult
    func deleteChatThread(id: UUID, patientSlug: String) -> Bool {
        let sql = "DELETE FROM chat_threads WHERE id = ? AND patient_slug = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id.uuidString)
        bindText(stmt, 2, patientSlug)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    // MARK: - Snapshot

    /// Writes a consistent, compact copy of the database to `destination` using
    /// SQLite's `VACUUM INTO`. Safe to call while the store is open — the copy is
    /// internally consistent even mid-session, so it's never a half-written file.
    /// `destination` must not already exist (a `VACUUM INTO` requirement) and its
    /// parent directory must exist. Returns false on any SQLite error.
    @discardableResult
    func snapshot(to destination: URL) -> Bool {
        // VACUUM INTO takes a string literal, not a bound parameter, so the path
        // is embedded directly; double any single quotes to keep it a safe,
        // single-quoted literal.
        let escaped = destination.path.replacingOccurrences(of: "'", with: "''")
        return exec("VACUUM INTO '\(escaped)';")
    }

    // MARK: - Field encryption

    private func encodeField(_ text: String) -> String { FieldCipher.encode(text, using: protector) }
    private func decodeField(_ stored: String) -> String { FieldCipher.decode(stored, using: protector) }

    /// A thread's messages are stored as one sealed JSON blob — the whole
    /// conversation is opaque at rest, and the array shape stays out of the
    /// schema so it can evolve without a migration.
    private func encodeMessages(_ messages: [ChatMessage]) -> String {
        guard
            let data = try? JSONEncoder.sessionNotes.encode(messages),
            let json = String(data: data, encoding: .utf8)
        else { return encodeField("[]") }
        return encodeField(json)
    }

    private func decodeMessages(_ stored: String) -> [ChatMessage] {
        let json = decodeField(stored)
        guard
            let data = json.data(using: .utf8),
            let messages = try? JSONDecoder.sessionNotes.decode([ChatMessage].self, from: data)
        else { return [] }
        return messages
    }

    // MARK: - Migration

    /// Re-encodes every free-text column from this store's protector to
    /// `newProtector` (decode with the current one, encode with the new one), so
    /// turning encryption on or off converts the database in place. Values are
    /// collected before updating to avoid mutating rows mid-scan. Returns false
    /// on any SQLite error.
    @discardableResult
    func reencrypt(to newProtector: FileProtector) -> Bool {
        func recode(_ value: String) -> String {
            FieldCipher.encode(FieldCipher.decode(value, using: protector), using: newProtector)
        }

        // Comments: gather (id, quoted_text, body), then update each.
        var comments: [(id: String, quoted: String, body: String)] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, quoted_text, body FROM comments;", -1, &stmt, nil) == SQLITE_OK else { return false }
        while sqlite3_step(stmt) == SQLITE_ROW {
            comments.append((columnText(stmt, 0), columnText(stmt, 1), columnText(stmt, 2)))
        }
        sqlite3_finalize(stmt)
        for row in comments {
            var up: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE comments SET quoted_text = ?, body = ? WHERE id = ?;", -1, &up, nil) == SQLITE_OK else { return false }
            bindText(up, 1, recode(row.quoted))
            bindText(up, 2, recode(row.body))
            bindText(up, 3, row.id)
            let ok = sqlite3_step(up) == SQLITE_DONE
            sqlite3_finalize(up)
            guard ok else { return false }
        }

        // Notes: gather (session_key, body), then update each.
        var notes: [(key: String, body: String)] = []
        guard sqlite3_prepare_v2(db, "SELECT session_key, body FROM notes;", -1, &stmt, nil) == SQLITE_OK else { return false }
        while sqlite3_step(stmt) == SQLITE_ROW {
            notes.append((columnText(stmt, 0), columnText(stmt, 1)))
        }
        sqlite3_finalize(stmt)
        for row in notes {
            var up: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE notes SET body = ? WHERE session_key = ?;", -1, &up, nil) == SQLITE_OK else { return false }
            bindText(up, 1, recode(row.body))
            bindText(up, 2, row.key)
            let ok = sqlite3_step(up) == SQLITE_DONE
            sqlite3_finalize(up)
            guard ok else { return false }
        }

        // Chat threads: gather (id, title, messages), then update each.
        var threads: [(id: String, title: String, messages: String)] = []
        guard sqlite3_prepare_v2(db, "SELECT id, title, messages FROM chat_threads;", -1, &stmt, nil) == SQLITE_OK else { return false }
        while sqlite3_step(stmt) == SQLITE_ROW {
            threads.append((columnText(stmt, 0), columnText(stmt, 1), columnText(stmt, 2)))
        }
        sqlite3_finalize(stmt)
        for row in threads {
            var up: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE chat_threads SET title = ?, messages = ? WHERE id = ?;", -1, &up, nil) == SQLITE_OK else { return false }
            bindText(up, 1, recode(row.title))
            bindText(up, 2, recode(row.messages))
            bindText(up, 3, row.id)
            let ok = sqlite3_step(up) == SQLITE_DONE
            sqlite3_finalize(up)
            guard ok else { return false }
        }
        return true
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
