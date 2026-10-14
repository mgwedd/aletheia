import Foundation
import SQLite3

/// The persistent full-text index behind `SessionSearch` (#286): SQLite FTS5
/// in its own file, `<dataRoot>/search.sqlite`.
///
/// Why a separate file and not a table in `Aletheia.sqlite`: the index is a
/// pure cache. It can be deleted, corrupted or version-bumped and is simply
/// rebuilt from the transcripts, so it must never share a schema version,
/// migration backup or snapshot with the records that can't be rebuilt.
///
/// Michael accepted that this holds a plaintext copy of the searchable text
/// (stemmed words, not the original lines; FileVault covers it at rest). The
/// file is excluded from Time Machine, zeroes freed pages, and its connection
/// is closed when the app or the data folder locks.
///
/// Layout:
///   doc      one row per indexed document: patient, session, kind, date, and a
///            fingerprint of its text. (session, kind, fp) is unique, so
///            unchanged text is never re-indexed and an edit is a new row.
///   session  per-session stamp (transcript mtime + size) for the launch sweep.
///   passage  FTS5, one row per transcript line or notes paragraph. Its rowid is
///            `doc << 24 | line`, which maps a hit to its document and line and
///            makes deleting a document one rowid range. `text` holds the
///            passage already tokenized and stemmed by `SessionSearch` (so the
///            old stemming, name and stopword behaviour is unchanged), with
///            stopwords as `qzstop` so phrase positions line up.
///   word     every distinct stored word, to expand fuzzy and sound-alike terms
///            (fts5vocab would have to walk every posting list to list them).
///            Words of deleted text stay; they just match nothing.
///
/// Thread-safe: every database use holds `lock`, and tokenizing happens outside
/// it, so a search can run while another thread is indexing.
final class SearchIndex {
    static let stopToken = "qzstop"
    private static let schemaVersion: Int32 = 2
    private static let lineBits: Int64 = 24
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    struct Passage {
        let line: Int
        let text: String
    }

    /// One document to look up or store.
    struct Item {
        let session: String   // "" when the caller gave no session (ad hoc)
        let patient: String?
        let kind: String
        let date: Double
        let fingerprint: String
        let text: String
    }

    /// Size of the searched documents, for ranking.
    struct Stats {
        let passages: Int
        let tokens: Int
    }

    /// One stored passage: its row id, and the text as UTF-8 words separated by single spaces.
    typealias Bytes = UnsafeBufferPointer<UInt8>

    /// nil file = in memory (tests, and before a data folder is chosen).
    let url: URL?
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var corrupt = false
    private var verified = false
    private let worker = DispatchQueue(label: "aletheia.search-index", qos: .utility)

    init(url: URL? = nil) { self.url = url }

    deinit { sqlite3_close(db) }

    /// Whether a connection is open, for tests.
    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return db != nil
    }

    /// Drops the connection (and with it SQLite's page cache, which holds
    /// indexed text). The next use reopens it. A no-op for an in-memory index,
    /// whose data would be lost.
    func close() {
        guard url != nil else { return }
        lock.lock()
        sqlite3_close(db)
        db = nil
        lock.unlock()
    }

    // MARK: - Pure helpers

    /// Stable key for a document's text. The length keeps texts that differ
    /// only in leading whitespace (which shifts line numbers) apart.
    /// Two 64-bit multiplicative hashes over the bytes, eight at a time (a
    /// cryptographic hash of every transcript on every search cost more than the
    /// query). It only has to tell edited text from unedited text.
    static func fingerprint(of text: String) -> String {
        var text = text
        let (a, b) = text.withUTF8 { bytes -> (UInt64, UInt64) in
            var h1: UInt64 = 0x9E37_79B9_7F4A_7C15, h2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
            var i = 0
            while i + 8 <= bytes.count {
                let w = UnsafeRawPointer(bytes.baseAddress! + i).loadUnaligned(as: UInt64.self)
                h1 = (h1 ^ w) &* 0x0000_0100_0000_01B3 &+ (h1 >> 29)
                h2 = ((h2 &+ w) &* 0xFF51_AFD7_ED55_8CCD) ^ (h2 >> 31)
                i += 8
            }
            while i < bytes.count {
                h1 = (h1 ^ UInt64(bytes[i])) &* 0x0000_0100_0000_01B3
                h2 = (h2 &+ UInt64(bytes[i])) &* 0xFF51_AFD7_ED55_8CCD
                i += 1
            }
            return (h1, h2)
        }
        return "\(text.utf8.count)-" + String(a, radix: 16) + String(b, radix: 16)
    }

    /// The FTS form of a stem: letters and digits only, so FTS5's tokenizer and
    /// ours always agree on word boundaries.
    static func ftsToken(_ stem: String) -> String {
        stem.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
    }

    static func rowid(doc: Int64, line: Int) -> Int64 { (doc << lineBits) | Int64(line) }

    /// A transcript line, or a paragraph of notes, per passage; empty ones skipped.
    static func passages(of text: String, kind: SessionSearch.Kind) -> [Passage] {
        let lines = LineTable(text)
        func indexed(_ raw: String) -> String? {
            let tokens = SessionSearch.tokenize(raw)
            let words = tokens.map { SessionSearch.stopwords.contains($0) ? stopToken : ftsToken(SessionSearch.stem($0)) }
            return words.contains { $0 != stopToken && !$0.isEmpty } ? words.filter { !$0.isEmpty }.joined(separator: " ") : nil
        }
        var result: [Passage] = []
        if kind == .transcript {
            for i in 0..<lines.count {
                if let t = indexed(TranscriptTimeline.spokenText(lines[i])) { result.append(Passage(line: i, text: t)) }
            }
        } else {
            var start: Int?
            for i in 0...lines.count {
                let blank = i == lines.count || lines[i].allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
                if !blank, start == nil { start = i }
                if blank, let s = start {
                    if let t = indexed((s..<i).map { lines[$0] }.joined(separator: " ")) { result.append(Passage(line: s, text: t)) }
                    start = nil
                }
            }
        }
        return result
    }

    // MARK: - Queries

    /// Which of `items` are not stored yet (by position), so the caller can
    /// tokenize just those, outside the lock.
    func missing(_ items: [Item]) -> Set<Int> {
        lock.lock()
        defer { lock.unlock() }
        guard let db = open() else { return Set(items.indices) }
        var result = Set<Int>()
        for (i, item) in items.enumerated() where docID(db, item) == nil { result.insert(i) }
        settle()
        return result
    }

    /// Makes sure every item is stored, drops older versions of the same
    /// (session, kind), then runs one MATCH over just these documents.
    /// `plan` turns the vocabulary into the MATCH string plus whatever the
    /// caller needs to read the rows (nil: nothing can match). `visit` sees every
    /// matching passage as raw bytes (nothing is copied or decoded, so a query
    /// that matches a quarter of all lines stays cheap); `top` then names the
    /// passages the caller wants again, and `again` gets just those. All three
    /// run inside the lock. Returns nil if the database failed and was reset;
    /// the caller may retry once.
    func query<Info>(
        items: [Item], passages: [Int: [Passage]],
        plan: (_ vocabulary: () -> [String]) -> (match: String, info: Info)?,
        visit: (Info, _ doc: Int64, _ line: Int, Bytes) -> Void,
        top: (Info, Stats, _ docs: [Int64: [Int]]) -> [Int64],
        again: (Info, _ rowid: Int64, Bytes) -> Void
    ) -> (docs: [Int64: [Int]], info: Info?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let db = open() else { return nil }
        exec(db, "BEGIN")
        var ids: [Int64] = []
        for (i, item) in items.enumerated() {
            guard let id = store(db, item, passages[i] ?? Self.passages(of: item.text, kind: kindOf(item))) else {
                exec(db, "ROLLBACK")
                settle()
                return nil
            }
            ids.append(id)
        }
        prune(db, items: items, ids: ids)
        exec(db, "COMMIT")
        var docs: [Int64: [Int]] = [:]
        for (i, id) in ids.enumerated() { docs[id, default: []].append(i) }

        let vocabulary = { () -> [String] in
            var words: [String] = []
            self.each(db, "SELECT term FROM word") { words.append(Self.text($0, 0)) }
            return words
        }
        guard let planned = plan(vocabulary) else { return settle() ? (docs, nil) : nil }

        exec(db, "CREATE TEMP TABLE IF NOT EXISTS want(id INTEGER PRIMARY KEY)")
        exec(db, "DELETE FROM want")
        if let insert = prepare(db, "INSERT OR IGNORE INTO want(id) VALUES(?)") {
            for id in docs.keys {
                sqlite3_bind_int64(insert, 1, id)
                sqlite3_step(insert)
                sqlite3_reset(insert)
            }
            sqlite3_finalize(insert)
        }
        var stats = Stats(passages: 0, tokens: 0)
        each(db, "SELECT sum(lines), sum(tokens) FROM doc WHERE id IN (SELECT id FROM want)") {
            stats = Stats(passages: Int(sqlite3_column_int64($0, 0)), tokens: Int(sqlite3_column_int64($0, 1)))
        }
        func bytes(_ stmt: OpaquePointer, _ column: Int32) -> Bytes {
            Bytes(start: sqlite3_column_text(stmt, column), count: Int(sqlite3_column_bytes(stmt, column)))
        }
        each(
            db,
            "SELECT rowid, text FROM passage WHERE passage MATCH ?1 AND (rowid >> \(Self.lineBits)) IN (SELECT id FROM want)",
            binds: [.text(planned.match)]
        ) { stmt in
            let rowid = sqlite3_column_int64(stmt, 0)
            visit(planned.info, rowid >> Self.lineBits, Int(rowid & ((1 << Self.lineBits) - 1)), bytes(stmt, 1))
        }
        let wanted = top(planned.info, stats, docs)
        if !wanted.isEmpty, let stmt = prepare(db, "SELECT text FROM passage WHERE rowid = ?1") {
            for rowid in wanted {
                sqlite3_bind_int64(stmt, 1, rowid)
                if sqlite3_step(stmt) == SQLITE_ROW { again(planned.info, rowid, bytes(stmt, 0)) }
                sqlite3_reset(stmt)
            }
            sqlite3_finalize(stmt)
        }
        return settle() ? (docs, planned.info) : nil
    }

    private func kindOf(_ item: Item) -> SessionSearch.Kind { SessionSearch.Kind(rawValue: item.kind) ?? .transcript }

    // MARK: - Maintenance

    /// Replaces what is stored for `session` under `kinds` with `items`
    /// (an empty list removes them), and records `stamp` (if given) for the
    /// launch sweep. Tokenizes before taking the lock.
    func replace(session: String, patient: String, kinds: [SessionSearch.Kind], items: [Item], stamp: String?) {
        let prepared = items.enumerated().reduce(into: [Int: [Passage]]()) { $0[$1.offset] = Self.passages(of: $1.element.text, kind: kindOf($1.element)) }
        lock.lock()
        defer { lock.unlock() }
        guard let db = open() else { return }
        exec(db, "BEGIN")
        var keep = Set<Int64>()
        for (i, item) in items.enumerated() {
            if let id = store(db, item, prepared[i] ?? []) { keep.insert(id) }
        }
        for kind in kinds {
            each(db, "SELECT id FROM doc WHERE session = ?1 AND kind = ?2", binds: [.text(session), .text(kind.rawValue)]) { stmt in
                let id = sqlite3_column_int64(stmt, 0)
                if !keep.contains(id) { self.pendingDelete.append(id) }
            }
        }
        removeDocs(db)
        if let stamp {
            run(db, "INSERT OR REPLACE INTO session(id, patient, stamp) VALUES(?1, ?2, ?3)",
                binds: [.text(session), .text(patient), .text(stamp)])
        }
        exec(db, "COMMIT")
        settle()
    }

    /// Runs `work` on the index's background queue (never the main thread).
    func async(_ work: @escaping () -> Void) { worker.async(execute: work) }

    /// Waits for work queued with `async` (tests).
    func flush() { worker.sync {} }

    func stamp(session: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let db = open() else { return nil }
        var result: String?
        each(db, "SELECT stamp FROM session WHERE id = ?1", binds: [.text(session)]) { result = Self.text($0, 0) }
        settle()
        return result
    }

    /// Removes everything stored for sessions not in `live`, and every ad hoc
    /// (session-less) document.
    func drop(sessionsNotIn live: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        guard let db = open() else { return }
        exec(db, "BEGIN")
        each(db, "SELECT id, session FROM doc") { stmt in
            let session = Self.text(stmt, 1)
            if session.isEmpty || !live.contains(session) { self.pendingDelete.append(sqlite3_column_int64(stmt, 0)) }
        }
        removeDocs(db)
        var stale: [String] = []
        each(db, "SELECT id FROM session") { stmt in
            let id = Self.text(stmt, 0)
            if !live.contains(id) { stale.append(id) }
        }
        for id in stale { run(db, "DELETE FROM session WHERE id = ?1", binds: [.text(id)]) }
        exec(db, "COMMIT")
        settle()
    }

    /// Counts, for tests and the benchmark.
    func counts() -> (docs: Int, passages: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let db = open() else { return (0, 0) }
        var d = 0, p = 0
        each(db, "SELECT (SELECT count(*) FROM doc), (SELECT count(*) FROM passage)") {
            d = Int(sqlite3_column_int64($0, 0)); p = Int(sqlite3_column_int64($0, 1))
        }
        settle()
        return (d, p)
    }

    // MARK: - SQLite plumbing (all callers hold `lock`)

    private enum Bind { case text(String), int(Int64), double(Double), null }
    private var pendingDelete: [Int64] = []

    /// Opens (creating, and rebuilding from scratch if the file is unusable).
    private func open() -> OpaquePointer? {
        if let db { return db }
        for attempt in 0..<2 {
            if let handle = openOnce() { db = handle; return handle }
            guard let url, attempt == 0 else { return nil }
            Self.removeFiles(url)
        }
        return nil
    }

    private func openOnce() -> OpaquePointer? {
        var handle: OpaquePointer?
        if let url { try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url?.path ?? ":memory:", &handle, flags, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            return nil
        }
        exec(db, "PRAGMA secure_delete = ON")
        exec(db, "PRAGMA synchronous = OFF")   // a cache: a crash is repaired by the rebuild below
        exec(db, "PRAGMA temp_store = MEMORY")
        exec(db, "PRAGMA mmap_size = 268435456")   // reads come straight from the file's pages, no copy
        exec(db, "PRAGMA cache_size = -65536")
        var version: Int32 = 0
        each(db, "PRAGMA user_version") { version = sqlite3_column_int($0, 0) }
        var ok = version == 0 || version == Self.schemaVersion
        ok = ok && exec(db, """
            CREATE TABLE IF NOT EXISTS doc(
                id INTEGER PRIMARY KEY, patient TEXT, session TEXT NOT NULL, kind TEXT NOT NULL,
                date REAL NOT NULL, fp TEXT NOT NULL, lines INTEGER NOT NULL, tokens INTEGER NOT NULL,
                UNIQUE(session, kind, fp));
            CREATE TABLE IF NOT EXISTS session(id TEXT PRIMARY KEY, patient TEXT, stamp TEXT);
            CREATE VIRTUAL TABLE IF NOT EXISTS passage USING fts5(
                line UNINDEXED, text, tokenize = 'unicode61 remove_diacritics 0');
            CREATE TABLE IF NOT EXISTS word(term TEXT PRIMARY KEY) WITHOUT ROWID;
            PRAGMA user_version = \(Self.schemaVersion);
            """)
        // Touch each table so a damaged file fails here, not mid-search.
        ok = ok && exec(db, "SELECT count(*) FROM doc; SELECT count(*) FROM session; SELECT 1 FROM word LIMIT 1; SELECT 1 FROM passage LIMIT 1;")
        // Walks the whole index (a few hundred ms for a large one), so once per launch, not on every reopen after a lock.
        if ok, !verified { ok = exec(db, "INSERT INTO passage(passage) VALUES('integrity-check')"); verified = ok }
        guard ok, !corrupt else {
            sqlite3_close(db)
            corrupt = false
            return nil
        }
        if let url {
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var target = url
            try? target.setResourceValues(excluded)
        }
        return db
    }

    /// After an operation: if SQLite reported corruption, throw the file away
    /// so the next use starts a fresh one (the launch sweep refills it).
    /// Returns whether the operation was clean.
    @discardableResult
    private func settle() -> Bool {
        guard corrupt else { return true }
        corrupt = false
        verified = false
        sqlite3_close(db)
        db = nil
        if let url { Self.removeFiles(url) }
        return false
    }

    private static func removeFiles(_ url: URL) {
        for suffix in ["", "-journal", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    private func note(_ code: Int32) {
        if code == SQLITE_CORRUPT || code == SQLITE_NOTADB { corrupt = true }
    }

    @discardableResult
    private func exec(_ db: OpaquePointer, _ sql: String) -> Bool {
        let code = sqlite3_exec(db, sql, nil, nil, nil)
        note(code)
        return code == SQLITE_OK
    }

    private func prepare(_ db: OpaquePointer, _ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        note(code)
        return code == SQLITE_OK ? stmt : nil
    }

    private func bind(_ stmt: OpaquePointer, _ binds: [Bind]) {
        for (i, value) in binds.enumerated() {
            let n = Int32(i + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(stmt, n, s, -1, Self.transient)
            case .int(let v): sqlite3_bind_int64(stmt, n, v)
            case .double(let v): sqlite3_bind_double(stmt, n, v)
            case .null: sqlite3_bind_null(stmt, n)
            }
        }
    }

    private func each(_ db: OpaquePointer, _ sql: String, binds: [Bind] = [], row: (OpaquePointer) -> Void) {
        guard let stmt = prepare(db, sql) else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, binds)
        var code = sqlite3_step(stmt)
        while code == SQLITE_ROW {
            row(stmt)
            code = sqlite3_step(stmt)
        }
        if code != SQLITE_DONE { note(code) }
    }

    @discardableResult
    private func run(_ db: OpaquePointer, _ sql: String, binds: [Bind]) -> Bool {
        guard let stmt = prepare(db, sql) else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, binds)
        let code = sqlite3_step(stmt)
        note(code)
        return code == SQLITE_DONE
    }

    private static func text(_ stmt: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }

    private func docID(_ db: OpaquePointer, _ item: Item) -> Int64? {
        var id: Int64?
        each(db, "SELECT id FROM doc WHERE session = ?1 AND kind = ?2 AND fp = ?3",
             binds: [.text(item.session), .text(item.kind), .text(item.fingerprint)]) { id = sqlite3_column_int64($0, 0) }
        return id
    }

    /// The document's id, inserting it and its passages if new. nil on failure.
    private func store(_ db: OpaquePointer, _ item: Item, _ passages: @autoclosure () -> [Passage]) -> Int64? {
        if let id = docID(db, item) { return id }
        let rows = passages()
        let tokens = rows.reduce(0) { sum, p in sum + p.text.utf8.reduce(1) { $0 + ($1 == 32 ? 1 : 0) } }
        guard run(db, "INSERT INTO doc(patient, session, kind, date, fp, lines, tokens) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                  binds: [item.patient.map { .text($0) } ?? .null, .text(item.session), .text(item.kind),
                          .double(item.date), .text(item.fingerprint), .int(Int64(rows.count)), .int(Int64(tokens))]) else { return nil }
        let id = sqlite3_last_insert_rowid(db)
        guard let insert = prepare(db, "INSERT INTO passage(rowid, line, text) VALUES(?1, ?2, ?3)") else { return nil }
        defer { sqlite3_finalize(insert) }
        var words = Set<Substring>()
        for p in rows {
            words.formUnion(p.text.split(separator: " "))
            sqlite3_bind_int64(insert, 1, Self.rowid(doc: id, line: p.line))
            sqlite3_bind_int64(insert, 2, Int64(p.line))
            sqlite3_bind_text(insert, 3, p.text, -1, Self.transient)
            note(sqlite3_step(insert))
            sqlite3_reset(insert)
        }
        if let addWord = prepare(db, "INSERT OR IGNORE INTO word(term) VALUES(?1)") {
            for word in words {
                sqlite3_bind_text(addWord, 1, String(word), -1, Self.transient)
                sqlite3_step(addWord)
                sqlite3_reset(addWord)
            }
            sqlite3_finalize(addWord)
        }
        return id
    }

    /// Deletes the documents queued in `pendingDelete` with their passages.
    private func removeDocs(_ db: OpaquePointer) {
        for id in pendingDelete {
            run(db, "DELETE FROM passage WHERE rowid BETWEEN ?1 AND ?2",
                binds: [.int(Self.rowid(doc: id, line: 0)), .int(Self.rowid(doc: id, line: (1 << Int(Self.lineBits)) - 1))])
            run(db, "DELETE FROM doc WHERE id = ?1", binds: [.int(id)])
        }
        pendingDelete.removeAll()
    }

    /// For each (session, kind) present among the session-tagged `items`,
    /// removes stored documents with a different fingerprint: older versions.
    private func prune(_ db: OpaquePointer, items: [Item], ids: [Int64]) {
        var keep: [String: Set<Int64>] = [:]
        var scopes: [String: (session: String, kind: String)] = [:]
        for (i, item) in items.enumerated() where !item.session.isEmpty {
            let key = item.session + "|" + item.kind
            keep[key, default: []].insert(ids[i])
            scopes[key] = (item.session, item.kind)
        }
        for (key, scope) in scopes {
            each(db, "SELECT id FROM doc WHERE session = ?1 AND kind = ?2", binds: [.text(scope.session), .text(scope.kind)]) { stmt in
                let id = sqlite3_column_int64(stmt, 0)
                if !(keep[key]?.contains(id) ?? false) { self.pendingDelete.append(id) }
            }
        }
        removeDocs(db)
    }
}

/// The lines of a text, found by scanning its bytes for newlines, so a long
/// transcript isn't split into thousands of strings to read a few lines of it.
final class LineTable {
    private let bytes: [UInt8]
    private let starts: [Int]

    init(_ text: String) {
        bytes = Array(text.utf8)
        var found = [0]
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count, let hit = memchr(base + offset, 10, buffer.count - offset) {
                offset = base.distance(to: hit.assumingMemoryBound(to: UInt8.self)) + 1
                found.append(offset)
            }
        }
        starts = found
    }

    var count: Int { starts.count }

    subscript(line: Int) -> String {
        let end = line + 1 < starts.count ? starts[line + 1] - 1 : bytes.count
        return String(decoding: bytes[starts[line]..<end], as: UTF8.self)
    }
}
