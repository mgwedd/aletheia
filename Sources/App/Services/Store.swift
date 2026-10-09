import Foundation

enum StoreError: LocalizedError {
    case noDataRoot
    case patientNotFound
    case sessionNotFound
    /// A session folder's `session.json` is present but couldn't be read or
    /// decoded. The file is **never** rewritten and no replacement identity is
    /// minted: the session's comments, notes and chat are keyed by the id inside
    /// it, so inventing a new one would silently orphan them. `folder` is the
    /// session folder; `underlying` is the read/decode error (kept for
    /// diagnostics only, and deliberately not part of the user-facing message).
    case sessionMetadataUnreadable(folder: URL, underlying: Error)
    /// A session folder has no `session.json` and one couldn't be saved (for
    /// example a read-only folder), so the session can't be given a stable id.
    case sessionMetadataUnwritable(folder: URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .noDataRoot: return "No data folder has been chosen yet. Open Settings to pick one."
        case .patientNotFound: return "That patient couldn't be found on disk."
        case .sessionNotFound: return "That session couldn't be found on disk."
        // No patient names, note text or paths here: the folder is available
        // as a structured value on the case for callers that want to show it.
        case .sessionMetadataUnreadable:
            return "Aletheia couldn't read this session's identity file (session.json). "
                + "The original file was left untouched."
        case .sessionMetadataUnwritable:
            return "Aletheia couldn't save an identity file (session.json) for this session folder. "
                + "The folder was left as it was."
        }
    }
}

/// All disk I/O lives here. Layout, on purpose, is plain and Finder-browsable:
///
///   <dataRoot>/Patients/<Patient-Slug>/patient.json
///   <dataRoot>/Patients/<Patient-Slug>/YYYY-MM-DD_Session/
///       session.json       (the session's stable id + date)
///       mic.caf            (therapist's microphone)
///       call.caf            (the other side of the call, captured system audio)
///       transcript.txt
///       summary.txt        (the most recently generated note, any format)
///       note.<format>.txt  (one progress note per format, e.g. note.soap.txt)
///
/// Identity is a persisted `UUID`, never the path. A patient's id lives in
/// `patient.json`, a session's in `session.json` — both assigned once at
/// creation. The folder names (`<Patient-Slug>/`, `YYYY-MM-DD_Session/`) are a
/// human-friendly *organization* detail, freely renamable: the SQLite store
/// (`CommentStore`) keys comments/notes/chats on those ids, so annotations
/// follow a session or patient across a rename or move. A folder that turns up
/// without a `session.json` (created before this scheme, or dropped in by hand)
/// is minted an id on first listing and stays stable from then on. A
/// `session.json` that *is* present but unreadable is different: that is
/// corruption, so it's reported (`UnreadableEntry`) and never overwritten, and
/// an undecodable `patient.json` is likewise reported rather than skipped
/// silently. See `Store.unreadableEntries`.
///
/// Conversations (per-patient chat threads and each session's assistant chat)
/// used to live in JSON files here (`ChatThreads/`, the legacy single-thread
/// `patient_chat.json`, and per-session `chat.json`); they're now rows in the
/// SQLite store (`CommentStore`), reached through the same `loadChatThreads` /
/// `loadSessionChat` API. Any leftover files are imported into the DB on first
/// access and then removed (see `migrateLegacyChatThreads` /
/// `migrateLegacySessionChat`). Transcripts, summaries, and audio stay as files.
///
/// `gatherPatientContext` is the one place cross-transcript context gets
/// assembled for the chat feature. It's intentionally naive (concatenate
/// everything) so it's the single spot to swap in real retrieval later.

/// A session's persisted identity, stored as `session.json` inside the session
/// folder. `id` is assigned once at creation and is the key everything in the
/// database references; `date` is persisted too so the session keeps its date
/// even once the folder name is no longer the source of truth (it's renamable).
private struct SessionMetadata: Codable {
    let id: UUID
    let date: Date
}

final class Store {
    private let root: URL
    private let fileManager = FileManager.default
    /// Transparently seals/opens every PHI file this store reads or writes.
    /// `.passthrough` (the default) is a byte-for-byte no-op, so the store
    /// behaves exactly as before when encryption is off.
    private let protector: FileProtector
    /// SQLite-backed store for the therapist's annotations. Chat threads now live
    /// here too; this store owns the file→DB migration but the DB is the same one
    /// `AppModel` exposes for comments/notes. Built from the same root/protector
    /// when not injected, so direct `Store(root:)` construction (tests) still
    /// gets a working thread store.
    private let commentStore: CommentStore?
    /// Patient/session records found on disk but unreadable, as of the most
    /// recent listing of each. Guarded by a lock because listings can run from
    /// App Intents and background work as well as the UI.
    private let unreadableLock = NSLock()
    private var recordedUnreadable: [UnreadableEntry] = []
    private let dateFolderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Result of reconciling this data folder's schema stamp with the version
    /// this build understands, computed once when the store opens.
    let schemaCompatibility: SchemaCompatibility

    /// - Parameter openDatabaseIfMissing: when `commentStore` is nil, whether to
    ///   try opening the database here. `AppModel` passes `false` because it has
    ///   already tried (and recorded *why* it failed); a second attempt here could
    ///   disagree with the state it published.
    init(root: URL, protector: FileProtector = .passthrough, commentStore: CommentStore? = nil, openDatabaseIfMissing: Bool = true) {
        self.root = root
        self.protector = protector
        self.commentStore = commentStore ?? (openDatabaseIfMissing ? CommentStore(root: root, protector: protector) : nil)
        self.schemaCompatibility = Store.reconcileSchema(at: root)
    }

    // MARK: - Schema

    private static func reconcileSchema(at root: URL) -> SchemaCompatibility {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let metaURL = root.appendingPathComponent(DataSchema.metadataFileName)
        let current = DataSchema.currentVersion
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

        if let data = try? Data(contentsOf: metaURL),
           let meta = try? JSONDecoder().decode(StoreMetadata.self, from: data) {
            if meta.schemaVersion > current {
                return .needsNewerApp(dataVersion: meta.schemaVersion, appVersion: current)
            }
            if meta.schemaVersion < current {
                // (Migrations from meta.schemaVersion → current would run here.)
                writeMetadata(StoreMetadata(schemaVersion: current, lastWrittenBy: appVersion), to: metaURL)
                return .upgraded(fromVersion: meta.schemaVersion)
            }
            return .ok
        }

        // No stamp yet (fresh folder, or one from before versioning existed):
        // claim it at the current version.
        writeMetadata(StoreMetadata(schemaVersion: current, lastWrittenBy: appVersion), to: metaURL)
        return .ok
    }

    private static func writeMetadata(_ meta: StoreMetadata, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(meta) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private var patientsDir: URL { root.appendingPathComponent("Patients", isDirectory: true) }

    // MARK: - Patients

    /// Healthy patients only, alphabetically. A patient whose `patient.json`
    /// can't be read is left out of this list but is **not** silently dropped:
    /// it's recorded in `unreadableEntries` (use `patientListing()` to get the
    /// list and the damaged records together).
    func listPatients() throws -> [Patient] {
        try patientListing().patients
    }

    /// Patients that read cleanly plus the records that didn't. Never deletes or
    /// rewrites an unreadable `patient.json`. A file sealed while the folder is
    /// locked isn't damage (the app's lock screen covers that), so it's skipped
    /// without being reported.
    func patientListing() throws -> PatientListing {
        try fileManager.createDirectory(at: patientsDir, withIntermediateDirectories: true)
        let entries = try fileManager.contentsOfDirectory(at: patientsDir, includingPropertiesForKeys: nil)
        var patients: [Patient] = []
        var unreadable: [UnreadableEntry] = []
        for dir in entries {
            let file = dir.appendingPathComponent("patient.json")
            let data: Data
            do {
                guard let present = try protector.dataIfPresent(at: file) else { continue }
                data = present
            } catch FileProtector.ProtectorError.locked {
                continue
            } catch {
                unreadable.append(UnreadableEntry(kind: .patientRecord, reason: .notReadable, folder: dir))
                continue
            }
            do {
                patients.append(try JSONDecoder.aletheia.decode(Patient.self, from: data))
            } catch {
                unreadable.append(UnreadableEntry(kind: .patientRecord, reason: .undecodable, folder: dir))
            }
        }
        recordUnreadable(unreadable) { $0.kind == .patientRecord }
        return PatientListing(
            patients: patients.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            unreadable: unreadable.sorted { $0.id < $1.id }
        )
    }

    // MARK: - Unreadable records

    /// Records found unreadable by the most recent listings (patients, plus each
    /// patient's sessions as they've been listed). A plain snapshot for the UI
    /// and the Doctor health check; contains no patient names or note text.
    var unreadableEntries: [UnreadableEntry] {
        unreadableLock.lock()
        defer { unreadableLock.unlock() }
        return recordedUnreadable.sorted { $0.id < $1.id }
    }

    /// Lists every patient and every patient's sessions, and returns everything
    /// that couldn't be read. Unlike `unreadableEntries` (which only knows what's
    /// been listed so far) this is a complete pass, for a health check. Like any
    /// listing it gives a legacy session folder without a `session.json` its
    /// identity file; it never touches an unreadable one. The session folders of
    /// a patient whose own `patient.json` is unreadable can't be scanned.
    @discardableResult
    func scanForUnreadableEntries() -> [UnreadableEntry] {
        recordUnreadable([]) { $0.kind == .sessionRecord }
        if let listing = try? patientListing() {
            for patient in listing.patients {
                _ = try? sessionListing(for: patient)
            }
        }
        return unreadableEntries
    }

    /// Replaces the recorded entries matching `scope` with `entries`.
    private func recordUnreadable(_ entries: [UnreadableEntry], replacing scope: (UnreadableEntry) -> Bool) {
        unreadableLock.lock()
        defer { unreadableLock.unlock() }
        recordedUnreadable.removeAll(where: scope)
        recordedUnreadable.append(contentsOf: entries)
    }

    func createPatient(name: String) throws -> Patient {
        try fileManager.createDirectory(at: patientsDir, withIntermediateDirectories: true)
        let slug = try uniqueSlug(for: name)
        let patient = Patient(name: name, slug: slug)
        try fileManager.createDirectory(at: patientDir(for: patient), withIntermediateDirectories: true)
        try save(patient)
        return patient
    }

    func save(_ patient: Patient) throws {
        let data = try JSONEncoder.aletheia.encode(patient)
        try fileManager.createDirectory(at: patientDir(for: patient), withIntermediateDirectories: true)
        try protector.write(data, to: patientDir(for: patient).appendingPathComponent("patient.json"))
    }

    func patientDir(for patient: Patient) -> URL {
        patientsDir.appendingPathComponent(patient.slug, isDirectory: true)
    }

    private func uniqueSlug(for name: String) throws -> String {
        let base = slugify(name)
        var candidate = base
        var suffix = 2
        let existing = Set(try fileManager.contentsOfDirectory(at: patientsDir, includingPropertiesForKeys: nil).map { $0.lastPathComponent })
        while existing.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func slugify(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = trimmed.map { char -> Character in
            char.isLetter || char.isNumber ? char : "-"
        }
        let collapsed = String(allowed).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "Patient" : collapsed
    }

    // MARK: - Sessions

    /// Healthy sessions only, newest first. A session whose `session.json` is
    /// present but unreadable is left out of this list but recorded in
    /// `unreadableEntries` (use `sessionListing(for:)` to get both together).
    func listSessions(for patient: Patient) throws -> [SessionRecord] {
        try sessionListing(for: patient).sessions
    }

    /// Sessions that read cleanly plus the folders whose identity file didn't.
    /// A damaged one is never given a new id and its file is never rewritten.
    func sessionListing(for patient: Patient) throws -> SessionListing {
        let dir = patientDir(for: patient)
        let ownsEntry: (UnreadableEntry) -> Bool = { $0.kind == .sessionRecord && $0.patientId == patient.id }
        guard fileManager.fileExists(atPath: dir.path) else {
            recordUnreadable([], replacing: ownsEntry)
            return SessionListing(sessions: [], unreadable: [])
        }
        let entries = try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])
        var sessions: [SessionRecord] = []
        var unreadable: [UnreadableEntry] = []
        for folder in entries {
            guard let isDir = try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDir else { continue }
            // A session folder is one carrying a `session.json` identity record,
            // or (legacy / manually created) one named "…_Session". The latter
            // is minted an id on sight so it becomes stable from here on.
            let hasMetadata = fileManager.fileExists(atPath: sessionMetadataURL(for: folder).path)
            guard hasMetadata || folder.lastPathComponent.hasSuffix("_Session") else { continue }
            let record: SessionRecord
            do {
                record = try makeSessionRecord(for: patient, folder: folder)
            } catch StoreError.sessionMetadataUnwritable {
                unreadable.append(UnreadableEntry(
                    kind: .sessionRecord, reason: .couldNotSaveIdentity, folder: folder, patientId: patient.id))
                continue
            } catch StoreError.sessionMetadataUnreadable(_, let underlying) {
                unreadable.append(UnreadableEntry(
                    kind: .sessionRecord,
                    reason: underlying is DecodingError ? .undecodable : .notReadable,
                    folder: folder,
                    patientId: patient.id))
                continue
            } catch {
                unreadable.append(UnreadableEntry(
                    kind: .sessionRecord, reason: .notReadable, folder: folder, patientId: patient.id))
                continue
            }
            sessions.append(record)
        }
        recordUnreadable(unreadable, replacing: ownsEntry)
        return SessionListing(
            sessions: sessions.sorted { $0.date > $1.date },
            unreadable: unreadable.sorted { $0.id < $1.id }
        )
    }

    /// One session by folder name. Throws `StoreError.sessionNotFound` when the
    /// folder isn't there and `StoreError.sessionMetadataUnreadable` when its
    /// `session.json` is present but damaged (the file is left as it was).
    func loadSession(for patient: Patient, folderName: String) throws -> SessionRecord {
        let folder = patientDir(for: patient).appendingPathComponent(folderName, isDirectory: true)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw StoreError.sessionNotFound
        }
        return try makeSessionRecord(for: patient, folder: folder)
    }

    private func makeSessionRecord(for patient: Patient, folder: URL) throws -> SessionRecord {
        let meta = try sessionMetadata(for: folder)
        return SessionRecord(
            id: meta.id,
            patientId: patient.id,
            date: meta.date,
            folderName: folder.lastPathComponent,
            hasRecording: fileManager.fileExists(atPath: folder.appendingPathComponent("call.caf").path)
                || fileManager.fileExists(atPath: folder.appendingPathComponent("mic.caf").path),
            hasTranscript: fileManager.fileExists(atPath: folder.appendingPathComponent("transcript.txt").path),
            hasSummary: fileManager.fileExists(atPath: folder.appendingPathComponent("summary.txt").path)
        )
    }

    func createSession(for patient: Patient, on date: Date = Date()) throws -> SessionRecord {
        let dir = patientDir(for: patient)
        let dayString = dateFolderFormatter.string(from: date)
        var folderName = "\(dayString)_Session"
        var suffix = 2
        while fileManager.fileExists(atPath: dir.appendingPathComponent(folderName).path) {
            folderName = "\(dayString)_Session-\(suffix)"
            suffix += 1
        }
        let sessionDir = dir.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        // Assign the session's stable identity at creation and persist it.
        let meta = SessionMetadata(id: UUID(), date: date)
        try writeSessionMetadata(meta, to: sessionMetadataURL(for: sessionDir))
        return SessionRecord(id: meta.id, patientId: patient.id, date: date, folderName: folderName)
    }

    // MARK: - Session identity

    /// The `session.json` identity file for a session folder.
    private func sessionMetadataURL(for sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("session.json")
    }

    /// Reads a session folder's persisted identity.
    ///
    /// * `session.json` **missing** — a folder from before this scheme (#64), or
    ///   one a therapist created by hand in Finder. It's minted an id and that is
    ///   persisted, so it's stable from then on. The date falls back to the folder
    ///   name's leading `YYYY-MM-DD`.
    /// * `session.json` **present but unreadable/undecodable** — corruption. Throws
    ///   `StoreError.sessionMetadataUnreadable` and touches nothing: minting a new
    ///   id here would orphan the session's comments, notes and chat (keyed by the
    ///   old id in SQLite), and rewriting the file would destroy the evidence a
    ///   repair or backup restore needs.
    ///
    /// Written as **plaintext**, not through the `protector`: it carries no name
    /// or note text — only a UUID and the session date, and that date is already
    /// visible in the cleartext folder name. Keeping it plaintext also keeps
    /// identity independent of the encryption toggle (`DataMigrator` doesn't
    /// rewrite this file), so turning encryption on/off can never orphan a
    /// session by leaving its id file unreadable.
    private func sessionMetadata(for sessionDir: URL) throws -> SessionMetadata {
        let url = sessionMetadataURL(for: sessionDir)
        if fileManager.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                return try JSONDecoder.aletheia.decode(SessionMetadata.self, from: data)
            } catch {
                throw StoreError.sessionMetadataUnreadable(folder: sessionDir, underlying: error)
            }
        }
        let dateString = String(sessionDir.lastPathComponent.prefix(10))
        let date = dateFolderFormatter.date(from: dateString) ?? Date.distantPast
        let meta = SessionMetadata(id: UUID(), date: date)
        do {
            try writeSessionMetadata(meta, to: url)
        } catch {
            // An id that isn't persisted would change on every listing and
            // orphan whatever gets attached to it, so don't hand it out.
            throw StoreError.sessionMetadataUnwritable(folder: sessionDir, underlying: error)
        }
        return meta
    }

    private func writeSessionMetadata(_ meta: SessionMetadata, to url: URL) throws {
        let data = try JSONEncoder.aletheia.encode(meta)
        try data.write(to: url, options: .atomic)
    }

    func sessionDir(for patient: Patient, session: SessionRecord) -> URL {
        patientDir(for: patient).appendingPathComponent(session.folderName, isDirectory: true)
    }

    func micRecordingURL(for patient: Patient, session: SessionRecord) -> URL {
        sessionDir(for: patient, session: session).appendingPathComponent("mic.caf")
    }

    func callRecordingURL(for patient: Patient, session: SessionRecord) -> URL {
        sessionDir(for: patient, session: session).appendingPathComponent("call.caf")
    }

    /// Removes a session's raw audio (`mic.caf` / `call.caf`) from disk. Called
    /// after transcription when `AudioRetentionPolicy` says the audio should not
    /// be kept (the transcript-only default), so the recording — the most
    /// sensitive artifact a session produces — doesn't linger. Best-effort: an
    /// absent file is a no-op, and a removal failure is swallowed rather than
    /// surfaced, since the transcript is already saved and is the document of
    /// record.
    func deleteRecordings(for patient: Patient, session: SessionRecord) {
        try? FileManager.default.removeItem(at: micRecordingURL(for: patient, session: session))
        try? FileManager.default.removeItem(at: callRecordingURL(for: patient, session: session))
    }

    func transcript(for patient: Patient, session: SessionRecord) -> String? {
        (try? readTranscript(for: patient, session: session)) ?? nil
    }

    /// Like `transcript(for:session:)`, but a transcript that exists and can't be
    /// read (locked, tampered, I/O error) throws instead of reading as "no
    /// transcript". nil still means there is no transcript file.
    func readTranscript(for patient: Patient, session: SessionRecord) throws -> String? {
        let url = sessionDir(for: patient, session: session).appendingPathComponent("transcript.txt")
        return try protector.stringIfPresent(at: url)
    }

    func saveTranscript(_ text: String, for patient: Patient, session: SessionRecord) throws {
        let url = sessionDir(for: patient, session: session).appendingPathComponent("transcript.txt")
        try protector.write(text, to: url)
    }

    func summary(for patient: Patient, session: SessionRecord) -> String? {
        let url = sessionDir(for: patient, session: session).appendingPathComponent("summary.txt")
        return (try? protector.stringIfPresent(at: url)) ?? nil
    }

    func saveSummary(_ text: String, for patient: Patient, session: SessionRecord) throws {
        let url = sessionDir(for: patient, session: session).appendingPathComponent("summary.txt")
        try protector.write(text, to: url)
    }

    // MARK: - Per-format progress notes

    /// The file holding a session's note in `format`. Each format keeps its own
    /// note, so switching SOAP → BIRP doesn't overwrite or hide the SOAP one.
    static func noteFileName(for format: ProgressNoteFormat) -> String {
        "note.\(format.rawValue).txt"
    }

    /// Whether `name` is a per-format note file (`note.<format>.txt`). Matched by
    /// shape rather than from `ProgressNoteFormat.allCases` so a file written for
    /// a since-removed format is still recognised (and migrated/sealed with the
    /// rest of the session) instead of being orphaned.
    static func isNoteFileName(_ name: String) -> Bool {
        name.hasPrefix("note.") && name.hasSuffix(".txt") && name.count > "note..txt".count
    }

    /// The session's saved note in `format`, or nil if that format has none yet.
    ///
    /// Legacy adoption: before per-format notes a session had one `summary.txt`
    /// and no way to tell which format produced it. If the session has no
    /// `note.*.txt` at all but does have a `summary.txt`, that text is adopted as
    /// the note for whichever `format` is asked for first (the one the user has
    /// selected) and persisted as that format's file. After that the per-format
    /// files exist, so the other formats correctly read as "no note yet".
    func note(for patient: Patient, session: SessionRecord, format: ProgressNoteFormat) -> String? {
        let dir = sessionDir(for: patient, session: session)
        let url = dir.appendingPathComponent(Store.noteFileName(for: format))
        if let text = (try? protector.stringIfPresent(at: url)) ?? nil { return text }

        let hasAnyFormatNote = ProgressNoteFormat.allCases.contains {
            fileManager.fileExists(atPath: dir.appendingPathComponent(Store.noteFileName(for: $0)).path)
        }
        guard !hasAnyFormatNote, let legacy = summary(for: patient, session: session) else { return nil }
        try? protector.write(legacy, to: url)
        return legacy
    }

    /// Saves `text` as the session's note in `format`, and mirrors it to
    /// `summary.txt` so "the latest note" (export, search, chat context, the
    /// session-list badge) keeps working off that one file.
    func saveNote(_ text: String, for patient: Patient, session: SessionRecord, format: ProgressNoteFormat) throws {
        let url = sessionDir(for: patient, session: session).appendingPathComponent(Store.noteFileName(for: format))
        try protector.write(text, to: url)
        try saveSummary(text, for: patient, session: session)
    }

    // MARK: - Chat

    /// A session's assistant conversation, read from the DB. Any leftover
    /// `chat.json` (from a build before this offload) is imported into the DB and
    /// removed the first time this runs.
    func loadSessionChat(for patient: Patient, session: SessionRecord) -> [ChatMessage] {
        migrateLegacySessionChat(for: patient, session: session)
        return commentStore?.sessionChat(sessionID: session.id) ?? []
    }

    /// Throws `DatabaseWriteError` when the chat could not be written (database
    /// unavailable, or the write was rejected) instead of dropping it silently.
    func saveSessionChat(_ messages: [ChatMessage], for patient: Patient, session: SessionRecord) throws {
        guard let commentStore else { throw DatabaseWriteError.databaseUnavailable }
        guard commentStore.saveSessionChat(messages, sessionID: session.id) else { throw DatabaseWriteError.writeFailed }
    }

    /// One-time move of a session's file-based chat into SQLite, then removes the
    /// file. Idempotent: once `chat.json` is gone there's nothing to import. The
    /// file is deleted only after its content is safely written to the DB, so an
    /// interrupted run re-imports rather than losing anything (the upsert is keyed
    /// by session key). An empty `chat.json` is just retired.
    private func migrateLegacySessionChat(for patient: Patient, session: SessionRecord) {
        guard let commentStore else { return }
        let legacyFile = sessionDir(for: patient, session: session).appendingPathComponent("chat.json")
        guard fileManager.fileExists(atPath: legacyFile.path) else { return }
        let legacy = loadChat(at: legacyFile)
        if legacy.isEmpty {
            try? fileManager.removeItem(at: legacyFile)
            return
        }
        guard commentStore.saveSessionChat(legacy, sessionID: session.id) else { return }
        try? fileManager.removeItem(at: legacyFile)
    }

    func loadPatientChat(for patient: Patient) -> [ChatMessage] {
        loadChat(at: patientDir(for: patient).appendingPathComponent("patient_chat.json"))
    }

    func savePatientChat(_ messages: [ChatMessage], for patient: Patient) throws {
        try saveChat(messages, at: patientDir(for: patient).appendingPathComponent("patient_chat.json"))
    }

    private func loadChat(at url: URL) -> [ChatMessage] {
        guard let data = (try? protector.dataIfPresent(at: url)) ?? nil else { return [] }
        return (try? JSONDecoder.aletheia.decode([ChatMessage].self, from: data)) ?? []
    }

    // MARK: - Chat threads (per-patient, multi-thread)

    /// Legacy location: a patient's chat threads used to live one-JSON-per-file
    /// here. Kept so the one-time migration can find and retire them.
    func chatThreadsDir(for patient: Patient) -> URL {
        patientDir(for: patient).appendingPathComponent("ChatThreads", isDirectory: true)
    }

    /// A patient's chat threads, most-recently-active first, read from the DB.
    /// Any threads still on disk (from a build before this offload) are imported
    /// into the DB and their files removed the first time this runs.
    func loadChatThreads(for patient: Patient) -> [ChatThread] {
        migrateLegacyChatThreads(for: patient)
        return commentStore?.chatThreads(patientID: patient.id) ?? []
    }

    /// Throws `DatabaseWriteError` when the thread could not be written.
    func saveChatThread(_ thread: ChatThread, for patient: Patient) throws {
        guard let commentStore else { throw DatabaseWriteError.databaseUnavailable }
        guard commentStore.saveChatThread(thread, patientID: patient.id) else { throw DatabaseWriteError.writeFailed }
    }

    /// Throws `DatabaseWriteError` when the thread could not be deleted.
    func deleteChatThread(id: UUID, for patient: Patient) throws {
        guard let commentStore else { throw DatabaseWriteError.databaseUnavailable }
        guard commentStore.deleteChatThread(id: id, patientID: patient.id) else { throw DatabaseWriteError.writeFailed }
    }

    /// One-time move of a patient's file-based chat into SQLite, then removes the
    /// files so the data folder de-clutters. Idempotent: once the files are gone
    /// there's nothing left to import. Source files are deleted only after their
    /// content is safely written to the DB, so an interrupted run re-imports
    /// rather than losing anything (the DB upsert is keyed by thread id).
    private func migrateLegacyChatThreads(for patient: Patient) {
        guard let commentStore else { return }
        let threadsDir = chatThreadsDir(for: patient)
        let legacyChatFile = patientDir(for: patient).appendingPathComponent("patient_chat.json")
        let hasThreadFiles = fileManager.fileExists(atPath: threadsDir.path)
        let hasLegacyChat = fileManager.fileExists(atPath: legacyChatFile.path)
        guard hasThreadFiles || hasLegacyChat else { return }

        if hasThreadFiles {
            // Multi-thread era: import each thread file verbatim.
            let entries = (try? fileManager.contentsOfDirectory(at: threadsDir, includingPropertiesForKeys: nil)) ?? []
            var allImported = true
            for url in entries where url.pathExtension == "json" {
                guard
                    let data = (try? protector.dataIfPresent(at: url)) ?? nil,
                    let thread = try? JSONDecoder.aletheia.decode(ChatThread.self, from: data),
                    commentStore.saveChatThread(thread, patientID: patient.id)
                else { allImported = false; continue }
            }
            if allImported { try? fileManager.removeItem(at: threadsDir) }
        } else if hasLegacyChat {
            // Pre-thread era: the single conversation becomes one thread. Only
            // when there were no thread files, matching the original import rule.
            let legacy = loadPatientChat(for: patient)
            if !legacy.isEmpty {
                let thread = ChatThread(
                    title: "",
                    createdAt: legacy.first?.date ?? Date(),
                    updatedAt: legacy.last?.date ?? Date(),
                    messages: legacy
                )
                guard commentStore.saveChatThread(thread, patientID: patient.id) else { return }
            }
        }
        // Retire the legacy single-thread file once its content is in the DB (or
        // it was already superseded by thread files).
        if hasLegacyChat { try? fileManager.removeItem(at: legacyChatFile) }
    }

    private func saveChat(_ messages: [ChatMessage], at url: URL) throws {
        let data = try JSONEncoder.aletheia.encode(messages)
        try protector.write(data, to: url)
    }

    // MARK: - Search

    /// Sessions for one patient whose transcript or summary matches the
    /// query, newest first. Transcript matches take precedence over summary
    /// matches for the same session (the transcript is the authoritative
    /// record, so that's the excerpt worth showing).
    func searchSessions(for patient: Patient, query: String) -> [SessionSearchResult] {
        guard !TextSearch.queryTerms(query).isEmpty else { return [] }
        let sessions = (try? listSessions(for: patient)) ?? []
        var results: [SessionSearchResult] = []
        for session in sessions {
            if let transcript = transcript(for: patient, session: session), TextSearch.matches(transcript, query: query) {
                results.append(SessionSearchResult(
                    id: session.id,
                    session: session,
                    matchedIn: .transcript,
                    snippet: TextSearch.snippet(from: transcript, query: query) ?? ""
                ))
            } else if let summary = summary(for: patient, session: session), TextSearch.matches(summary, query: query) {
                results.append(SessionSearchResult(
                    id: session.id,
                    session: session,
                    matchedIn: .summary,
                    snippet: TextSearch.snippet(from: summary, query: query) ?? ""
                ))
            }
        }
        return results
    }

    /// The earliest session whose transcript mentions the query — answers
    /// "when did they first bring this up?". Returns nil when nothing matches.
    func firstMention(of query: String, for patient: Patient) -> SessionRecord? {
        guard !TextSearch.queryTerms(query).isEmpty else { return nil }
        // listSessions is newest-first; walk oldest-first to find the first.
        let sessions = ((try? listSessions(for: patient)) ?? []).sorted { $0.date < $1.date }
        return sessions.first { session in
            guard let transcript = transcript(for: patient, session: session) else { return false }
            return TextSearch.matches(transcript, query: query)
        }
    }

    /// Every patient with a name match or at least one matching session,
    /// in the same alphabetical order as `listPatients`.
    func searchAllPatients(query: String) -> [PatientSearchResult] {
        guard !TextSearch.queryTerms(query).isEmpty else { return [] }
        let patients = (try? listPatients()) ?? []
        var results: [PatientSearchResult] = []
        for patient in patients {
            let nameMatched = TextSearch.matches(patient.name, query: query)
            let sessionResults = searchSessions(for: patient, query: query)
            if nameMatched || !sessionResults.isEmpty {
                results.append(PatientSearchResult(
                    id: patient.id,
                    patient: patient,
                    nameMatched: nameMatched,
                    sessionResults: sessionResults
                ))
            }
        }
        return results
    }

    // MARK: - Export

    func exportSessionMarkdown(patient: Patient, session: SessionRecord) -> String {
        MarkdownExporter.session(
            date: session.date,
            patientName: patient.name,
            transcript: transcript(for: patient, session: session),
            summary: summary(for: patient, session: session)
        )
    }

    func exportPatientHistoryMarkdown(patient: Patient) -> String {
        let sessions = (try? listSessions(for: patient)) ?? []
        let exports = sessions.map { session in
            SessionExport(
                date: session.date,
                transcript: transcript(for: patient, session: session) ?? "",
                summary: summary(for: patient, session: session) ?? ""
            )
        }
        return MarkdownExporter.patientHistory(patientName: patient.name, notes: patient.notes, sessions: exports)
    }

    // MARK: - Cross-session context (the RAG swap-point)

    /// Concatenates every transcript for a patient, newest first, with dated
    /// headers so the model can cite when something happened. This is the
    /// naive "stuff everything in the prompt" approach; if transcript volume
    /// ever outgrows the model's context window, this is the only function
    /// that needs to change (e.g. to embedding-based retrieval).
    func gatherPatientContext(for patient: Patient) throws -> String {
        let sessions = try listSessions(for: patient)
        var chunks: [String] = []
        let displayFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .long
            return f
        }()
        for session in sessions {
            guard let transcript = transcript(for: patient, session: session), !transcript.isEmpty else { continue }
            let header = "===== Session \(displayFormatter.string(from: session.date)) ====="
            chunks.append("\(header)\n\(transcript)")
        }
        return chunks.joined(separator: "\n\n")
    }

    /// Relevance-aware variant of `gatherPatientContext`: for a small history
    /// it returns everything (same as above); once the transcripts outgrow
    /// the prompt budget it hands back only the passages most relevant to
    /// `question`. This is the actual retrieval upgrade the naive method was
    /// designed to be swapped for.
    func gatherPatientContext(for patient: Patient, relevantTo question: String) -> String {
        let sessions = (try? listSessions(for: patient)) ?? []
        let documents = sessions.compactMap { session -> TranscriptDocument? in
            guard let transcript = transcript(for: patient, session: session), !transcript.isEmpty else { return nil }
            return TranscriptDocument(date: session.date, text: transcript)
        }
        return PatientContextRetriever.context(for: documents, question: question)
    }

    /// Cap, in characters, on the material added under one session's header besides
    /// its transcript excerpt: the therapist's notes and comments and the
    /// generated notes, combined. These bypass the retriever's ranking, so the
    /// cap keeps one long note from crowding out the transcripts.
    static let patientChatSessionExtrasLimit = 3_000

    /// Shown under a session's header when its transcript exists but couldn't be
    /// read, so the model doesn't take the gap for "never discussed".
    static let unreadableTranscriptMarker = "[transcript could not be read]"

    /// Like `gatherPatientContext(for:relevantTo:)`, but also assigns each
    /// session a short citation tag (`S1` newest first) embedded in its header,
    /// and returns the tag→session mapping. This is what lets the chat show
    /// which sessions an answer drew from (see `Citations`).
    ///
    /// Under each header go the retriever's transcript excerpt (if the ranker
    /// kept one), then that session's generated notes, the therapist's own
    /// notes and her transcript comments. `sources` lists only the sessions
    /// that appear in the text.
    func gatherCitedPatientContext(for patient: Patient, relevantTo question: String) -> PatientContext {
        let sessions = ((try? listSessions(for: patient)) ?? []).sorted { $0.date > $1.date }
        // Same-day sessions share a date key (the retriever groups by date too),
        // so they share one tag and cite as one source.
        var labels: [Date: String] = [:]
        var dates: [Date] = []
        var firstFolder: [Date: String] = [:]
        var extras: [Date: [String]] = [:]
        var documents: [TranscriptDocument] = []
        var unreadable = 0
        var index = 1
        for session in sessions {
            var material = sessionMaterial(for: patient, session: session)
            var transcript: String?
            do {
                transcript = try readTranscript(for: patient, session: session)
            } catch {
                unreadable += 1
                material.insert(Store.unreadableTranscriptMarker, at: 0)
            }
            let transcriptText = transcript ?? ""
            guard !transcriptText.isEmpty || !material.isEmpty else { continue }

            if labels[session.date] == nil {
                labels[session.date] = "S\(index)"
                index += 1
                dates.append(session.date)
                firstFolder[session.date] = session.folderName
            }
            if !transcriptText.isEmpty {
                documents.append(TranscriptDocument(date: session.date, text: transcriptText))
            }
            extras[session.date, default: []].append(contentsOf: material)
        }

        let excerpts = PatientContextRetriever.excerpts(for: documents, question: question, labels: labels)
        let excerptsByDate = Dictionary(grouping: excerpts, by: { $0.date })
        var blocks: [String] = []
        var sources: [CitationSource] = []
        for date in dates {
            let parts = (excerptsByDate[date] ?? []).map { $0.text } + (extras[date] ?? [])
            // Nothing from this session made it into the context: don't cite it.
            guard !parts.isEmpty, let tag = labels[date], let folderName = firstFolder[date] else { continue }
            let header = PatientContextRetriever.header(date, labels: labels)
            blocks.append("\(header)\n\(parts.joined(separator: "\n\n"))")
            sources.append(CitationSource(tag: tag, date: date, folderName: folderName))
        }
        let sessionsText = blocks.joined(separator: "\n\n")
        // Always prepend the patient's background (clinical history + meds) so the
        // assistant can draw on it whenever it's relevant, without it having to be
        // requested. Empty when nothing has been entered.
        let background = patient.aiBackgroundBlock
        let text = [background, sessionsText]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        let transcriptDates = Set(documents.map { $0.date })
        let coverage = TranscriptCoverage(
            sessions: transcriptDates.count,
            sessionsWithoutPassages: transcriptDates.subtracting(excerptsByDate.keys).count,
            totalCharacters: documents.reduce(0) { $0 + $1.text.count },
            includedCharacters: excerpts.reduce(0) { $0 + $1.text.count }
        )
        return PatientContext(text: text, sources: sources, unreadableSessions: unreadable, coverage: coverage)
    }

    /// The blocks the patient-wide chat adds under a session's header besides the
    /// transcript, capped to `patientChatSessionExtrasLimit` in total. Order is
    /// the therapist's own words first (her notes, then her comments, as the
    /// single-session chat renders them), then generated notes, so a long
    /// generated note is what gets cut. Unreadable notes are skipped.
    private func sessionMaterial(for patient: Patient, session: SessionRecord) -> [String] {
        var blocks: [String] = []

        let notes = commentStore?.note(sessionID: session.id) ?? ""
        let comments = AssistantService.formatComments(commentStore?.comments(sessionID: session.id) ?? [])
        let therapistSections = [
            Prompts.therapistMaterial(notes: notes, comments: []),
            Prompts.therapistMaterial(notes: "", comments: comments),
        ]
        for section in therapistSections {
            let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { blocks.append(trimmed) }
        }

        for (label, text) in generatedNotes(for: patient, session: session) {
            blocks.append("Generated progress note (\(label)):\n\(text)")
        }
        return Store.capped(blocks, limit: Store.patientChatSessionExtrasLimit)
    }

    /// A session's generated notes, one per format that has been generated, as
    /// (format label, text). Falls back to the legacy `summary.txt` when no
    /// per-format file exists. Reads files directly rather than through
    /// `note(for:session:format:)`, which adopts a legacy summary by writing.
    private func generatedNotes(for patient: Patient, session: SessionRecord) -> [(String, String)] {
        let dir = sessionDir(for: patient, session: session)
        let names = ((try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { Store.isNoteFileName($0) }
            .sorted()
        var result: [(String, String)] = []
        for name in names {
            let url = dir.appendingPathComponent(name)
            let text = ((try? protector.stringIfPresent(at: url)) ?? nil) ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // "note.soap.txt" -> "soap"
            let raw = String(name.dropFirst("note.".count).dropLast(".txt".count))
            let label = ProgressNoteFormat(rawValue: raw)?.shortName ?? raw
            result.append((label, trimmed))
        }
        if names.isEmpty, let legacy = summary(for: patient, session: session) {
            let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(("earlier format", trimmed)) }
        }
        return result
    }

    /// Keeps as many of `blocks` as fit in `limit` characters, cutting the block
    /// that crosses the limit with a marker and noting if later ones were left out.
    static func capped(_ blocks: [String], limit: Int) -> [String] {
        var remaining = limit
        var kept: [String] = []
        for block in blocks {
            if remaining <= 0 {
                kept.append("[further notes omitted]")
                break
            }
            if block.count > remaining {
                kept.append(String(block.prefix(remaining)) + "… [truncated]")
            } else {
                kept.append(block)
            }
            remaining -= block.count
        }
        return kept
    }
}

/// Plain `.iso8601` only has whole-second resolution, which would silently
/// truncate timestamps on every save/reload round trip (harmless for
/// display today, but a needless precision loss). Fractional seconds keep
/// it lossless.
private let aletheiaDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

extension JSONEncoder {
    static let aletheia: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(aletheiaDateFormatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let aletheia: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = aletheiaDateFormatter.date(from: string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(string)")
            }
            return date
        }
        return decoder
    }()
}
