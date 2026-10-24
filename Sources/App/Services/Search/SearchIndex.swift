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
/// is closed when the app or the data folder locks. When per-folder encryption
/// locks or is turned off the file is deleted (it would be a plaintext copy of
/// an encrypted folder); the unlock sweep rebuilds it.
///
/// Layout:
///   doc      one row per indexed document: patient, session, kind, date, and a
///            fingerprint of its text. (session, kind, fp) is unique, so
///            unchanged text is never re-indexed and an edit is a new row.
///            `live` is 1 for the documents `replace` last stored for their
///            session and kind (the launch sweep and the save hooks), which is
///            what global search reads; a chat or tool search stores what it was
///            handed with `live` 0, so an older or not yet saved version never
///            shows up there.
///   session  per-session stamp (transcript mtime + size, or "none" for a
///            session without a transcript) for the launch sweep.
///   passage  FTS5, one row per transcript line or notes paragraph. Its rowid is
///            `doc << 24 | line`, which maps a hit to its document and line and
///            makes deleting a document one rowid range. `text` holds the
///            passage already tokenized and stemmed by `SessionSearch` (so the
///            old stemming and name behaviour is unchanged). Every word is
///            stored, common ones too, so any word can be searched for.
///   word     every distinct stored word, to expand fuzzy and sound-alike terms
///            (fts5vocab would have to walk every posting list to list them).
///            Words of deleted text stay; they just match nothing.
///
/// Thread-safe: every database use holds `lock`, and tokenizing happens outside
/// it, so a search can run while another thread is indexing.
final class SearchIndex {
    /// 4: every word stored (3 stored common words as a stand-in, so they couldn't be found).
    private static let schemaVersion: Int32 = 4
    private static let lineBits: Int64 = 24
    /// Rows `matchLive` reads between asking whether to go on.
    static let checkEvery = 1024
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
    /// Set by `close()` / `destroy()` (a lock engaged): nothing reopens the file until `reopen()` finds `mayOpen()` true.
    private var locked = false
    /// Asked on every open and on `reopen()`: false while the app lock or the folder's encryption lock is engaged.
    /// Derived rather than toggled, so unlocking one lock never opens the index behind the other.
    var mayOpen: () -> Bool = { true }
    /// Called after `reopen()` succeeds, to re-run the (incremental) sweep.
    var onReopen: (() -> Void)?
    /// Called when a damaged or outdated file was thrown away and the index
    /// started over empty, so the owner can re-run the sweep to refill it.
    var onReset: (() -> Void)?
    /// What the index is known to be missing right now (see `SearchIndexProgress`).
    let progress = SearchIndexProgress()
    private let worker = DispatchQueue(label: "aletheia.search-index", qos: .utility)

    init(url: URL? = nil) { self.url = url }

    deinit { sqlite3_close_v2(db) }

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
        locked = true
        sqlite3_close_v2(db)
        db = nil
        lock.unlock()
    }

    /// Closes the connection and deletes the file and its sidecars (the folder's
    /// encryption locked or was turned off, so the plaintext copy must go). A
    /// no-op for an in-memory index.
    func destroy() {
        guard let url else { return }
        lock.lock()
        locked = true
        sqlite3_close_v2(db)
        db = nil
        verified = false
        Self.removeFiles(url)
        lock.unlock()
        progress.invalidate()
    }

    /// Whether the index is closed, or a lock is engaged, so work on it would be dropped.
    var isBlocked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return locked || !mayOpen()
    }

    /// Lets the file open again if no lock is still engaged, and re-kicks the sweep.
    func reopen() {
        lock.lock()
        locked = !mayOpen()
        let open = !locked
        lock.unlock()
        if open { onReopen?() }
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
        func hex(_ v: UInt64) -> String { let h = String(v, radix: 16); return String(repeating: "0", count: 16 - h.count) + h }
        return "\(text.utf8.count)-" + hex(a) + hex(b)
    }

    /// The FTS form of a stem: letters and digits only, so FTS5's tokenizer and
    /// ours always agree on word boundaries.
    static func ftsToken(_ stem: String) -> String {
        stem.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
    }

    /// How the index stores a word from `SessionSearch.tokenize`: stemmed, except
    /// a common word, kept whole so it never meets a name or another word on a
    /// shared stem ("time" and "Tim" both stem to "tim", "does" and "Doe" to "doe").
    static func stored(_ token: String) -> String {
        ftsToken(SessionSearch.stopwords.contains(token) ? token : SessionSearch.stem(token))
    }

    static func rowid(doc: Int64, line: Int) -> Int64 { (doc << lineBits) | Int64(line) }

    /// The document and line a passage rowid stands for (the inverse of `rowid(doc:line:)`).
    static func split(rowid: Int64) -> (doc: Int64, line: Int) {
        (rowid >> lineBits, Int(rowid & ((1 << lineBits) - 1)))
    }

    /// A transcript line, or a paragraph of notes, per passage; empty ones skipped.
    static func passages(of text: String, kind: SessionSearch.Kind) -> [Passage] {
        let lines = LineTable(text)
        func indexed(_ raw: String) -> String? {
            let tokens = SessionSearch.tokenize(raw)
            let words = tokens.map { stored($0) }.filter { !$0.isEmpty }
            return words.isEmpty ? nil : words.joined(separator: " ")
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
        guard let db = open() else { return locked || !mayOpen() ? [] : Set(items.indices) }
        var result = Set<Int>()
        for (i, item) in items.enumerated() where docID(db, item) == nil { result.insert(i) }
        settle()
        return result
    }

    /// Makes sure every item is stored (never deleting other versions of a
    /// session, which only `replace` and the sweep do, so a search built from
    /// older text can't undo a newer save), then runs one MATCH over just these
    /// documents.
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
        guard exec(db, "BEGIN") else { settle(); return nil }
        var ids: [Int64] = []
        for (i, item) in items.enumerated() {
            guard let id = store(db, item, passages[i] ?? Self.passages(of: item.text, kind: kindOf(item))) else {
                exec(db, "ROLLBACK")
                settle()
                return nil
            }
            ids.append(id)
        }
        guard exec(db, "COMMIT") else {
            exec(db, "ROLLBACK")
            settle()
            return nil
        }
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
        guard exec(db, "BEGIN") else { settle(); return }
        var keep = Set<Int64>()
        for (i, item) in items.enumerated() {
            guard let id = store(db, item, prepared[i] ?? []) else {
                // All or nothing: no deletes, no stamp, so the sweep retries this session.
                pendingDelete.removeAll()
                exec(db, "ROLLBACK")
                settle()
                return
            }
            keep.insert(id)
            run(db, "UPDATE doc SET live = 1 WHERE id = ?1", binds: [.int(id)])
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
        if !exec(db, "COMMIT") { exec(db, "ROLLBACK") }
        settle()
    }

    /// Runs `work` on the index's background queue (never the main thread).
    func async(_ work: @escaping () -> Void) { worker.async(execute: work) }

    /// Runs `work` on the index's background queue and waits for it without
    /// blocking a thread. Saves (`async`) and the sweep go through this one
    /// serial queue, so a session's text is read and stored in the order the
    /// writes happened and the last write always wins.
    func perform<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            worker.async { continuation.resume(returning: work()) }
        }
    }

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

    /// Every session's stamp, by session id. nil when the index can't be read.
    func allStamps() -> [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        guard let db = open() else { return nil }
        var result: [String: String] = [:]
        each(db, "SELECT id, stamp FROM session") { result[Self.text($0, 0)] = Self.text($0, 1) }
        return settle() ? result : nil
    }

    // MARK: - Global search

    /// A document global search may show: one `replace` stored as current.
    struct LiveDocument: Equatable {
        let id: Int64
        let session: String
        let patient: String
        let kind: String
        let date: Double
        let fingerprint: String
    }

    /// A passage that matched one clause, with FTS5's BM25 turned positive (higher is better).
    struct MatchedPassage: Equatable {
        let doc: Int64
        let line: Int
        let score: Double
    }

    enum LiveMatch {
        /// Closed, locked, or damaged: the caller should read the files instead.
        case unavailable
        /// `shouldContinue` turned false part way.
        case cancelled
        /// Every live document, and per clause every passage of a live document it matched.
        case found(documents: [Int64: LiveDocument], passages: [[MatchedPassage]])
    }

    /// Runs each FTS5 MATCH `clauses[i]` over every live document (all
    /// patients), ranked by FTS5's own bm25(). One query per clause, so the
    /// caller can tell which terms a document matched. Only ids, line numbers
    /// and scores come back; the caller builds snippets from the original text.
    /// `shouldContinue` is asked before each clause and every `checkEvery`
    /// rows, so a search for a common word ("the") that typing has already
    /// replaced stops part way and frees the index for the next one.
    func matchLive(clauses: [String], shouldContinue: () -> Bool = { true }) -> LiveMatch {
        lock.lock()
        defer { lock.unlock() }
        guard let db = open() else { return .unavailable }
        var documents: [Int64: LiveDocument] = [:]
        each(db, "SELECT id, session, patient, kind, date, fp FROM doc WHERE live = 1") { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            documents[id] = LiveDocument(
                id: id, session: Self.text(stmt, 1), patient: Self.text(stmt, 2), kind: Self.text(stmt, 3),
                date: sqlite3_column_double(stmt, 4), fingerprint: Self.text(stmt, 5))
        }
        guard settle() else { return .unavailable }
        var passages: [[MatchedPassage]] = []
        for clause in clauses {
            guard shouldContinue() else { return .cancelled }
            guard let stmt = prepare(db, "SELECT rowid, bm25(passage) FROM passage WHERE passage MATCH ?1") else {
                settle()
                return .unavailable
            }
            bind(stmt, [.text(clause)])
            var rows: [MatchedPassage] = []
            var code = sqlite3_step(stmt)
            var read = 0
            while code == SQLITE_ROW {
                read += 1
                if read % Self.checkEvery == 0, !shouldContinue() {
                    sqlite3_finalize(stmt)
                    return .cancelled
                }
                let rowid = sqlite3_column_int64(stmt, 0)
                let doc = rowid >> Self.lineBits
                if documents[doc] != nil {
                    let line = Int(rowid & ((1 << Self.lineBits) - 1))
                    rows.append(MatchedPassage(doc: doc, line: line, score: -sqlite3_column_double(stmt, 1)))
                }
                code = sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            if code != SQLITE_DONE {
                note(code)
                settle()
                return .unavailable
            }
            passages.append(rows)
        }
        return .found(documents: documents, passages: passages)
    }

    /// Removes everything stored for sessions not in `live`, and every ad hoc
    /// (session-less) document.
    func drop(sessionsNotIn live: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        guard let db = open(), exec(db, "BEGIN") else { return }
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
        if !exec(db, "COMMIT") { exec(db, "ROLLBACK") }
        settle()
    }

    /// Removes all indexed documents, passages, and session stamps for a patient:
    /// those stored under its id, those stored under one of its `sessions`
    /// without a patient (a search that named only the session), and every ad
    /// hoc (session-less) document, which can't be traced to a patient and may
    /// be this one's text.
    func purgePatient(_ patient: String, sessions: [String] = []) {
        lock.lock()
        defer { lock.unlock() }
        guard let db = open(), exec(db, "BEGIN") else { return }
        var ids = Set<Int64>()
        each(db, "SELECT id FROM doc WHERE patient = ?1 OR session = ''", binds: [.text(patient)]) { stmt in
            ids.insert(sqlite3_column_int64(stmt, 0))
        }
        for session in sessions {
            each(db, "SELECT id FROM doc WHERE session = ?1", binds: [.text(session)]) { stmt in
                ids.insert(sqlite3_column_int64(stmt, 0))
            }
            run(db, "DELETE FROM session WHERE id = ?1", binds: [.text(session)])
        }
        pendingDelete.append(contentsOf: ids)
        removeDocs(db)
        run(db, "DELETE FROM session WHERE patient = ?1", binds: [.text(patient)])
        if !exec(db, "COMMIT") { exec(db, "ROLLBACK") }
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
        if locked || !mayOpen() { return nil }
        if let db { return db }
        for attempt in 0..<2 {
            if let handle = openOnce() { db = handle; return handle }
            guard let url, attempt == 0 else { return nil }
            Self.removeFiles(url)
            startedOver()
        }
        return nil
    }

    private func openOnce() -> OpaquePointer? {
        var handle: OpaquePointer?
        if let url { try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url?.path ?? ":memory:", &handle, flags, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close_v2(handle)
            return nil
        }
        exec(db, "PRAGMA secure_delete = ON")
        exec(db, "PRAGMA journal_mode = MEMORY")   // no -journal file to leave text behind or to exclude from backup
        exec(db, "PRAGMA synchronous = OFF")   // a cache: a crash is repaired by the rebuild below
        exec(db, "PRAGMA temp_store = MEMORY")
        exec(db, "PRAGMA cache_size = -65536")
        // Reads straight from the file's pages (a third faster on broad queries), but a mapped file that
        // disappears (unplugged drive, dropped network share) crashes the app, so only on the internal disk.
        if let url, let volume = try? url.deletingLastPathComponent().resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsInternalKey]),
           volume.volumeIsLocal == true, volume.volumeIsInternal == true {
            exec(db, "PRAGMA mmap_size = 268435456")
        }
        var version: Int32 = 0
        each(db, "PRAGMA user_version") { version = sqlite3_column_int($0, 0) }
        var ok = version == 0 || version == Self.schemaVersion
        ok = ok && exec(db, """
            CREATE TABLE IF NOT EXISTS doc(
                id INTEGER PRIMARY KEY, patient TEXT, session TEXT NOT NULL, kind TEXT NOT NULL,
                date REAL NOT NULL, fp TEXT NOT NULL, lines INTEGER NOT NULL, tokens INTEGER NOT NULL,
                live INTEGER NOT NULL DEFAULT 0, UNIQUE(session, kind, fp));
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
            sqlite3_close_v2(db)
            corrupt = false
            return nil
        }
        if let url {
            for suffix in ["", "-journal", "-wal", "-shm"] {
                BackupExclusion.markExcluded(URL(fileURLWithPath: url.path + suffix))   // fails harmlessly for a sidecar that doesn't exist
            }
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
        sqlite3_close_v2(db)
        db = nil
        if let url {
            Self.removeFiles(url)
            startedOver()
        }
        return false
    }

    /// Everything stored is gone: nothing about coverage is known until a sweep checks again.
    private func startedOver() {
        progress.invalidate()
        onReset?()
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
            let code = sqlite3_step(insert)
            note(code)
            sqlite3_reset(insert)
            if code != SQLITE_DONE { return nil }
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
