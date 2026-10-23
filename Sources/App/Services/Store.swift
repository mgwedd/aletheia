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
///       note.<format>.meta.json  (fingerprint of the transcript that note was generated from)
///       digest.json        (section + session digests of the transcript, see `SessionDigest`)
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
    /// The persistent search index kept in step with transcripts (see
    /// `SearchIndex`). nil for stores that don't maintain one (tests, App Intents).
    private let searchIndex: SearchIndex?
    /// Patient/session records found on disk but unreadable, as of the most
    /// recent listing of each. Guarded by a lock because listings can run from
    /// App Intents and background work as well as the UI.
    private let unreadableLock = NSLock()
    private var recordedUnreadable: [UnreadableEntry] = []
    /// Sessions whose notes and comments are queued for the index (see
    /// `refreshSearchMaterial`), so a burst of saves queues one refresh.
    private let refreshLock = NSLock()
    private var queuedRefreshes = Set<UUID>()
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
    init(root: URL, protector: FileProtector = .passthrough, commentStore: CommentStore? = nil, openDatabaseIfMissing: Bool = true, searchIndex: SearchIndex? = nil) {
        self.root = root
        self.searchIndex = searchIndex
        self.protector = protector
        self.commentStore = commentStore ?? (openDatabaseIfMissing ? CommentStore(root: root, protector: protector) : nil)
        self.schemaCompatibility = Store.reconcileSchema(at: root)
        // Comments and the therapist's own notes are saved straight to the
        // database by the views; this keeps the index in step with them.
        if searchIndex != nil {
            self.commentStore?.onSessionAnnotationsChanged = { [weak self] sessionID in
                self?.refreshSearchMaterial(sessionID: sessionID)
            }
        }
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

    /// Deletes a patient and all associated clinical data:
    /// 1. Takes a safety snapshot of the SQLite database (`pre-delete-patient`) in `.backups/snapshots/`
    /// 2. Purges all associated SQLite database rows (chat threads, comments, notes, session chats)
    /// 3. Purges all search index entries for this patient
    /// 4. Removes the patient directory and all of its session folders/files from disk
    /// 5. Cleans up any recorded unreadable entries for this patient
    func deletePatient(_ patient: Patient) throws {
        var dir = patientDir(for: patient)
        if !fileManager.fileExists(atPath: dir.path) {
            if let entries = try? fileManager.contentsOfDirectory(at: patientsDir, includingPropertiesForKeys: nil) {
                for candidate in entries {
                    let file = candidate.appendingPathComponent("patient.json")
                    if let data = try? protector.dataIfPresent(at: file),
                       let decoded = try? JSONDecoder.aletheia.decode(Patient.self, from: data),
                       decoded.id == patient.id {
                        dir = candidate
                        break
                    }
                }
            }
        }
        guard fileManager.fileExists(atPath: dir.path) else {
            throw StoreError.patientNotFound
        }

        let sessions = (try? listSessions(for: patient)) ?? []
        let sessionIDs = sessions.map(\.id)

        // Pre-delete safety snapshot of database
        if let commentStore {
            DatabaseSnapshotManager(root: root).makeSnapshot(of: commentStore, reason: "pre-delete-patient")
        }

        // Purge database records
        commentStore?.purgePatientRecords(patientID: patient.id, sessionIDs: sessionIDs)

        // Purge search index documents and session entries, now and again after
        // any save of this patient's text still queued for the index.
        if let index = searchIndex {
            let patientKey = patient.id.uuidString
            let sessionKeys = sessionIDs.map(\.uuidString)
            index.purgePatient(patientKey, sessions: sessionKeys)
            index.async { index.purgePatient(patientKey, sessions: sessionKeys) }
            index.progress.forget(sessions: sessionKeys)
        }

        // Remove patient directory and all session files from disk
        try fileManager.removeItem(at: dir)

        // Remove unreadable records cache entries matching this patient or its folder
        recordUnreadable([], replacing: { $0.patientId == patient.id || $0.folder.path.hasPrefix(dir.path) })
    }

    // MARK: - Sessions

    struct PatientSessionMeta: Equatable {
        var count: Int
        var newestDate: Date?
    }

    /// Fast scan of the patient's directory for session folders without opening
    /// or decoding files. Used by the patient list sidebar row to display session
    /// count and most recent session date without per-row disk reads.
    func fastSessionMeta(for patient: Patient) -> PatientSessionMeta {
        let dir = patientDir(for: patient)
        guard let entries = try? fileManager.contentsOfDirectory(atPath: dir.path) else {
            return PatientSessionMeta(count: 0, newestDate: nil)
        }
        var count = 0
        var newestDate: Date?
        for name in entries {
            guard name.hasSuffix("_Session") || name.contains("_Session-") else { continue }
            count += 1
            let prefix = String(name.prefix(10))
            if let date = dateFolderFormatter.date(from: prefix) {
                if newestDate == nil || date > newestDate! {
                    newestDate = date
                }
            }
        }
        return PatientSessionMeta(count: count, newestDate: newestDate)
    }

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
        // Index in the background; the save itself never waits on it.
        if let index = searchIndex {
            let item = Store.indexItem(SessionSearch.Document(
                date: session.date, tag: "", kind: .transcript, text: text, session: session.id, patient: patient.id))
            let stamp = Store.stamp(of: url)
            let key = session.id.uuidString
            index.progress.beginWrite(session: key)
            index.async {
                index.replace(
                    session: key, patient: patient.id.uuidString, kinds: [.transcript],
                    items: [item], stamp: stamp)
                index.progress.endWrite(session: key)
            }
        }
    }

    // MARK: - Search index

    /// Modification time and size of a file: enough to tell whether a transcript
    /// changed. `SearchIndexStaleness.noTranscript` when there is no file.
    private static func stamp(of url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return SearchIndexStaleness.stamp(
            exists: FileManager.default.fileExists(atPath: url.path),
            modified: values?.contentModificationDate, size: values?.fileSize)
    }

    private static func indexItem(_ d: SessionSearch.Document) -> SearchIndex.Item {
        SearchIndex.Item(
            session: d.session?.uuidString ?? "", patient: d.patient?.uuidString, kind: d.kind.rawValue,
            date: d.date.timeIntervalSinceReferenceDate, fingerprint: SearchIndex.fingerprint(of: d.text), text: d.text)
    }

    /// One session for the sweep to bring up to date.
    struct SearchIndexTarget {
        let patient: Patient
        let session: SessionRecord
        /// Whether the transcript must be read: it changed, was never indexed, or can't be stamped.
        let transcriptStale: Bool
    }

    /// What the sweep has to do, from one listing of the data folder.
    struct SearchIndexPlan {
        /// Every listed session, in the order to index them (`SearchIndexStaleness.order`).
        let targets: [SearchIndexTarget]
        /// Every listed session's id: what `drop(sessionsNotIn:)` keeps.
        let live: Set<String>
        /// Whether every patient and session listed cleanly, so a session missing
        /// from the listing really is gone (otherwise nothing is dropped).
        let complete: Bool

        /// Sessions whose transcript is not in the index as it is now.
        var staleSessions: Set<String> {
            Set(targets.filter { $0.transcriptStale }.map { $0.session.id.uuidString })
        }
    }

    /// Lists every patient and session and compares each transcript's stamp
    /// with the one the index recorded. nil when there is no index, it can't be
    /// read, or the folder can't be listed.
    func searchIndexPlan() -> SearchIndexPlan? {
        guard let index = searchIndex, let stored = index.allStamps(), let listing = try? patientListing() else { return nil }
        var complete = true
        // A patient record sealed while locked is skipped silently by the listing, so count folders too.
        let folders = ((try? fileManager.contentsOfDirectory(at: patientsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { fileManager.fileExists(atPath: $0.appendingPathComponent("patient.json").path) }
        if folders.count != listing.patients.count || !listing.unreadable.isEmpty { complete = false }
        var targets: [SearchIndexTarget] = []
        var live = Set<String>()
        for patient in listing.patients {
            guard let sessions = try? sessionListing(for: patient) else { complete = false; continue }
            if !sessions.unreadable.isEmpty { complete = false }
            for session in sessions.sessions {
                let id = session.id.uuidString
                live.insert(id)
                let url = sessionDir(for: patient, session: session).appendingPathComponent("transcript.txt")
                let stale = SearchIndexStaleness.needsIndexing(current: Store.stamp(of: url), stored: stored[id])
                targets.append(SearchIndexTarget(patient: patient, session: session, transcriptStale: stale))
            }
        }
        return SearchIndexPlan(targets: SearchIndexStaleness.order(targets), live: live, complete: complete)
    }

    /// Stores one session's current text: its notes and comments always (they
    /// are small), its transcript when `transcriptStale`. Returns false, leaving
    /// what is indexed as it was, when the transcript can't be read (locked).
    @discardableResult
    func indexSearchTarget(_ target: SearchIndexTarget) -> Bool {
        guard let index = searchIndex else { return false }
        let patient = target.patient
        let session = target.session
        var kinds: [SessionSearch.Kind] = [.sessionNotes, .comment, .note]
        var documents: [SessionSearch.Document] = []
        var stamp: String?
        if target.transcriptStale {
            kinds.append(.transcript)
            let url = sessionDir(for: patient, session: session).appendingPathComponent("transcript.txt")
            stamp = Store.stamp(of: url)   // taken before reading, so a save in between reads as a change next time
            do {
                if let text = try readTranscript(for: patient, session: session) {
                    documents.append(.init(
                        date: session.date, tag: "", kind: .transcript, text: text, session: session.id, patient: patient.id))
                }
            } catch {
                return false
            }
        }
        documents += searchMaterial(for: patient, session: session)
        index.replace(
            session: session.id.uuidString, patient: patient.id.uuidString, kinds: kinds,
            items: documents.map(Store.indexItem), stamp: stamp)
        return true
    }

    /// Brings the search index in line with the data folder, synchronously:
    /// indexes sessions whose transcript changed since last time (by
    /// modification time and size), refreshes every session's notes and
    /// comments, and drops sessions that no longer exist. The app runs the same
    /// steps in the background with `SearchIndexSweep`. A transcript that can't
    /// be read (folder locked) is left as it was, and nothing is dropped unless
    /// every patient and session listed and read cleanly.
    func syncSearchIndex(shouldContinue: () -> Bool = { true }) {
        guard let index = searchIndex else { return }
        index.progress.beginChecking()
        guard let plan = searchIndexPlan() else { return }
        index.progress.checked(stale: plan.staleSessions)
        var everyTargetRead = true
        for target in plan.targets {
            guard shouldContinue() else { return }
            if !indexSearchTarget(target) { everyTargetRead = false }
            index.progress.indexed(session: target.session.id.uuidString)
        }
        if plan.complete, everyTargetRead, shouldContinue() { index.drop(sessionsNotIn: plan.live) }
    }

    /// A session's notes and comments as the index stores them: what the patient
    /// chat searches (`sessionMaterialParts`, so the chat finds them already
    /// stored), plus resolved comments, which the chat leaves out but global
    /// search finds.
    private func searchMaterial(for patient: Patient, session: SessionRecord) -> [SessionSearch.Document] {
        var parts = sessionMaterialParts(for: patient, session: session)
        if let resolved = Store.resolvedCommentsText(commentStore?.comments(sessionID: session.id) ?? []) {
            parts.append((kind: .comment, text: resolved))
        }
        return parts.map { part in
            SessionSearch.Document(
                date: session.date, tag: "", kind: part.kind, text: part.text, session: session.id, patient: patient.id)
        }
    }

    /// Resolved comments as one document, written like the chat's comment
    /// lines; nil when there are none.
    static func resolvedCommentsText(_ comments: [SessionComment]) -> String? {
        var lines: [String] = []
        for comment in comments where comment.resolved {
            let quote = comment.quotedText.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(quote.isEmpty ? "- \(comment.body)" : "- On \u{201C}\(quote)\u{201D}: \(comment.body)")
        }
        return lines.isEmpty ? nil : "Resolved margin comments:\n" + lines.joined(separator: "\n")
    }

    /// Re-indexes a session's notes and comments after a save, in the background.
    /// Saves that come faster than the index keeps up with share one refresh,
    /// which reads the text when it runs, so the last save always wins.
    func refreshSearchMaterial(patient: Patient, session: SessionRecord) {
        scheduleMaterialRefresh(sessionID: session.id) { (patient: patient, session: session) }
    }

    /// The same, for a save that only knows the session (comments, the
    /// therapist's notes); the session is looked up when the refresh runs.
    func refreshSearchMaterial(sessionID: UUID) {
        scheduleMaterialRefresh(sessionID: sessionID) { [weak self] in self?.locateSession(id: sessionID) }
    }

    private func scheduleMaterialRefresh(
        sessionID: UUID, locate: @escaping () -> (patient: Patient, session: SessionRecord)?
    ) {
        guard let index = searchIndex else { return }
        refreshLock.lock()
        let isNew = queuedRefreshes.insert(sessionID).inserted
        refreshLock.unlock()
        guard isNew else { return }
        let key = sessionID.uuidString
        index.progress.beginWrite(session: key)
        index.async { [weak self] in
            defer { index.progress.endWrite(session: key) }
            guard let self else { return }
            self.refreshLock.lock()
            self.queuedRefreshes.remove(sessionID)
            self.refreshLock.unlock()
            guard let found = locate() else { return }
            let documents = self.searchMaterial(for: found.patient, session: found.session)
            index.replace(
                session: key, patient: found.patient.id.uuidString, kinds: [.sessionNotes, .comment, .note],
                items: documents.map(Store.indexItem), stamp: nil)
        }
    }

    /// The patient and session with this id, by listing the data folder.
    func locateSession(id: UUID) -> (patient: Patient, session: SessionRecord)? {
        for patient in (try? listPatients()) ?? [] {
            if let session = ((try? listSessions(for: patient)) ?? []).first(where: { $0.id == id }) {
                return (patient: patient, session: session)
            }
        }
        return nil
    }

    func summary(for patient: Patient, session: SessionRecord) -> String? {
        let url = sessionDir(for: patient, session: session).appendingPathComponent("summary.txt")
        return (try? protector.stringIfPresent(at: url)) ?? nil
    }

    func saveSummary(_ text: String, for patient: Patient, session: SessionRecord) throws {
        let url = sessionDir(for: patient, session: session).appendingPathComponent("summary.txt")
        try protector.write(text, to: url)
        refreshSearchMaterial(patient: patient, session: session)
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
            && !isNoteSidecarFileName(name)
    }

    /// Companion files kept beside a note, one per format.
    enum NoteSidecar: String, CaseIterable {
        /// What the assistant last generated; edits are detected against it.
        case generated
        /// The user's edited text, kept when a regenerate replaced it.
        case previous
        /// What a long session's note was written from, when not the whole transcript.
        case coverage
    }

    /// The companion file for `format`, e.g. `note.soap.generated.txt`.
    static func noteSidecarFileName(for format: ProgressNoteFormat, _ kind: NoteSidecar) -> String {
        "note.\(format.rawValue).\(kind.rawValue).txt"
    }

    /// Whether `name` is a note companion file. These match the `note.*.txt`
    /// shape but are not notes: `isNoteFileName` excludes them (so patient chat
    /// context doesn't read them as extra notes), while `DataMigrator` includes
    /// them so they are sealed and unsealed with the rest of the session.
    static func isNoteSidecarFileName(_ name: String) -> Bool {
        guard name.hasPrefix("note."), name.hasSuffix(".txt") else { return false }
        let stem = name.dropFirst("note.".count).dropLast(".txt".count)
        guard let dot = stem.lastIndex(of: "."), dot != stem.startIndex else { return false }
        return NoteSidecar(rawValue: String(stem[stem.index(after: dot)...])) != nil
    }

    /// The sidecar recording which transcript a generated note came from
    /// (`note.<format>.meta.json`). See `NoteFreshness`.
    static func noteMetaFileName(for format: ProgressNoteFormat) -> String {
        "note.\(format.rawValue).meta.json"
    }

    /// Whether `name` is a note sidecar. Matched by shape, like `isNoteFileName`.
    static func isNoteMetaFileName(_ name: String) -> Bool {
        name.hasPrefix("note.") && name.hasSuffix(".meta.json") && name.count > "note..meta.json".count
    }

    /// Fingerprint of the transcript the session's `format` note was generated
    /// from, or nil if none was recorded (or it can't be read).
    func noteTranscriptFingerprint(for patient: Patient, session: SessionRecord, format: ProgressNoteFormat) -> String? {
        let url = sessionDir(for: patient, session: session).appendingPathComponent(Store.noteMetaFileName(for: format))
        guard let data = (try? protector.dataIfPresent(at: url)) ?? nil else { return nil }
        return NoteFreshness.decodeFingerprint(from: data)
    }

    /// The session's saved note in `format`, or nil if that format has none yet.
    ///
    /// Read-only: never writes, so opening a session leaves its folder untouched.
    func note(for patient: Patient, session: SessionRecord, format: ProgressNoteFormat) -> String? {
        let url = sessionDir(for: patient, session: session).appendingPathComponent(Store.noteFileName(for: format))
        return (try? protector.stringIfPresent(at: url)) ?? nil
    }

    /// Saves `text` as the session's note in `format`, and mirrors it to
    /// `summary.txt` so "the latest note" (export, search, chat context, the
    /// session-list badge) keeps working off that one file.
    ///
    /// Pass `generatedFromTranscript` when the note was generated from that
    /// transcript text; its fingerprint is recorded beside the note so a later
    /// edit to the transcript can be detected. Omit it for any other save (the
    /// recorded fingerprint, if any, is left as it was).
    func saveNote(
        _ text: String,
        for patient: Patient,
        session: SessionRecord,
        format: ProgressNoteFormat,
        generatedFromTranscript transcript: String? = nil
    ) throws {
        let dir = sessionDir(for: patient, session: session)
        try protector.write(text, to: dir.appendingPathComponent(Store.noteFileName(for: format)))
        try saveSummary(text, for: patient, session: session)
        if let transcript {
            let record = try NoteFreshness.encode(fingerprint: NoteFreshness.fingerprint(of: transcript))
            try protector.write(record, to: dir.appendingPathComponent(Store.noteMetaFileName(for: format)))
        }
    }

    // MARK: - Session digests

    static let digestFileName = "digest.json"

    private func digestURL(for patient: Patient, session: SessionRecord) -> URL {
        sessionDir(for: patient, session: session).appendingPathComponent(Store.digestFileName)
    }

    /// Section summaries written by a digest build that hasn't finished (see
    /// `SectionDigestCache`), so it can carry on after a pause or a failure.
    static let digestSectionsFileName = "digest-sections.json"

    private func digestSectionsURL(for patient: Patient, session: SessionRecord) -> URL {
        sessionDir(for: patient, session: session).appendingPathComponent(Store.digestSectionsFileName)
    }

    /// The cached section summaries of `session`, by `DigestSchedulePolicy.sectionKey`; empty when none or unreadable.
    func sectionDigestCache(for patient: Patient, session: SessionRecord) -> [String: String] {
        guard let data = (try? protector.dataIfPresent(at: digestSectionsURL(for: patient, session: session))) ?? nil,
              let entries = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return entries
    }

    func saveSectionDigestCache(_ entries: [String: String], for patient: Patient, session: SessionRecord) throws {
        try protector.write(try JSONEncoder().encode(entries), to: digestSectionsURL(for: patient, session: session))
    }

    func saveDigest(_ digest: SessionDigest, for patient: Patient, session: SessionRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try protector.write(try encoder.encode(digest), to: digestURL(for: patient, session: session))
    }

    /// The session's digest if one is stored and still matches the current
    /// transcript, `model` and prompts; nil when missing, unreadable or stale.
    func digest(for patient: Patient, session: SessionRecord, model: String) -> SessionDigest? {
        anyCurrentDigest(for: patient, session: session, model: model)
    }

    /// Reads the stored digest if its version, prompt version, and transcript
    /// fingerprint match the current transcript (and `model`, when specified).
    func anyCurrentDigest(
        for patient: Patient,
        session: SessionRecord,
        transcript: String? = nil,
        model: String? = nil
    ) -> SessionDigest? {
        guard let data = (try? protector.dataIfPresent(at: digestURL(for: patient, session: session))) ?? nil,
              let actualTranscript = transcript ?? self.transcript(for: patient, session: session) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let digest = try? decoder.decode(SessionDigest.self, from: data),
              digest.version == SessionDigest.currentVersion,
              digest.promptVersion == Prompts.digestVersion,
              digest.transcriptFingerprint == NoteFreshness.fingerprint(of: actualTranscript) else { return nil }
        if let model, digest.model != model { return nil }
        return digest
    }

    // MARK: - Editing generated notes

    private func noteSidecarURL(_ kind: NoteSidecar, patient: Patient, session: SessionRecord, format: ProgressNoteFormat) -> URL {
        sessionDir(for: patient, session: session)
            .appendingPathComponent(Store.noteSidecarFileName(for: format, kind))
    }

    /// The text the assistant last generated for `format`, nil if none was recorded.
    func generatedNoteBaseline(for patient: Patient, session: SessionRecord, format: ProgressNoteFormat) -> String? {
        let url = noteSidecarURL(.generated, patient: patient, session: session, format: format)
        return (try? protector.stringIfPresent(at: url)) ?? nil
    }

    /// The edited text a regenerate replaced for `format`, nil if there is none.
    func previousNote(for patient: Patient, session: SessionRecord, format: ProgressNoteFormat) -> String? {
        let url = noteSidecarURL(.previous, patient: patient, session: session, format: format)
        return (try? protector.stringIfPresent(at: url)) ?? nil
    }

    /// Whether the saved `format` note is untouched generated text, the user's
    /// edit, or absent. Read-only (unlike `note(for:...)`).
    func noteEditState(for patient: Patient, session: SessionRecord, format: ProgressNoteFormat) -> NoteEditState {
        let url = sessionDir(for: patient, session: session).appendingPathComponent(Store.noteFileName(for: format))
        let current = (try? protector.stringIfPresent(at: url)) ?? nil
        return NoteEditing.state(
            current: current,
            baseline: generatedNoteBaseline(for: patient, session: session, format: format)
        )
    }

    /// Saves a note the assistant just generated. If the note it replaces was
    /// edited by hand, that text is first kept as the previous version; should
    /// that fail, this throws *before* touching the note, so an edit is never
    /// lost to a regenerate. The new text also becomes the baseline that later
    /// edits are measured against.
    func saveGeneratedNote(
        _ text: String,
        for patient: Patient,
        session: SessionRecord,
        format: ProgressNoteFormat,
        generatedFromTranscript transcript: String? = nil,
        coverage: String? = nil
    ) throws {
        let url = sessionDir(for: patient, session: session).appendingPathComponent(Store.noteFileName(for: format))
        if NoteEditing.shouldArchiveBeforeReplacing(noteEditState(for: patient, session: session, format: format)),
           let edited = (try? protector.stringIfPresent(at: url)) ?? nil {
            try protector.write(edited, to: noteSidecarURL(.previous, patient: patient, session: session, format: format))
        }
        try saveNote(text, for: patient, session: session, format: format, generatedFromTranscript: transcript)
        try protector.write(text, to: noteSidecarURL(.generated, patient: patient, session: session, format: format))
        // A note written from the whole transcript has no coverage line; drop any old one.
        let coverageURL = noteSidecarURL(.coverage, patient: patient, session: session, format: format)
        if let coverage, !coverage.isEmpty {
            try protector.write(coverage, to: coverageURL)
        } else {
            try? FileManager.default.removeItem(at: coverageURL)
        }
    }

    /// What the saved `format` note was written from, if it was not the whole transcript.
    func noteCoverage(for patient: Patient, session: SessionRecord, format: ProgressNoteFormat) -> String? {
        let url = noteSidecarURL(.coverage, patient: patient, session: session, format: format)
        return (try? protector.stringIfPresent(at: url)) ?? nil
    }

    /// Saves the user's hand-edited note. The generated baseline is left as it
    /// was, so the note now reads as edited.
    func saveEditedNote(_ text: String, for patient: Patient, session: SessionRecord, format: ProgressNoteFormat) throws {
        try saveNote(text, for: patient, session: session, format: format)
    }

    /// Swaps the saved note with its previous version, so restoring is itself
    /// reversible. Returns the restored text, or nil when there is no previous
    /// version.
    @discardableResult
    func restorePreviousNote(for patient: Patient, session: SessionRecord, format: ProgressNoteFormat) throws -> String? {
        guard let previous = previousNote(for: patient, session: session, format: format),
              !NoteEditing.normalized(previous).isEmpty else { return nil }
        let url = sessionDir(for: patient, session: session).appendingPathComponent(Store.noteFileName(for: format))
        let current = (try? protector.stringIfPresent(at: url)) ?? nil
        if let current {
            try protector.write(current, to: noteSidecarURL(.previous, patient: patient, session: session, format: format))
        }
        try saveNote(previous, for: patient, session: session, format: format)
        return previous
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

    /// Global search: patients by name, sessions by date, and every note,
    /// comment and transcript, answered from the search index
    /// (`GlobalSearchEngine`). Reads original text only for what it shows, so it
    /// costs about the same for 10 sessions as for 1,000. Falls back to reading
    /// every file (`searchHits`) when there is no index or it can't be read.
    /// Off the main thread; stops early when `shouldContinue` turns false.
    func globalSearch(
        query text: String,
        limits: GlobalSearchLimits = GlobalSearchLimits(),
        calendar: Calendar = .current,
        shouldContinue: () -> Bool = { true }
    ) -> GlobalSearchResults {
        let query = GlobalSearchQuery(text)
        guard !query.isEmpty else { return .empty }
        let catalog = searchCatalog()
        guard shouldContinue() else { return .empty }
        if let index = searchIndex,
           let found = GlobalSearchEngine.search(
               query, catalog: catalog, index: index, reader: searchReader, limits: limits,
               calendar: calendar, shouldContinue: shouldContinue) {
            return found
        }
        let scanned = searchHits(query: text, shouldContinue: shouldContinue)
        return GlobalSearchEngine.scannedResults(query, catalog: catalog, scanned: scanned, limits: limits, calendar: calendar)
    }

    /// Every patient and their sessions, for global search to point results at.
    func searchCatalog() -> GlobalSearchCatalog {
        let patients = (try? listPatients()) ?? []
        return GlobalSearchCatalog(entries: patients.map { patient in
            GlobalSearchCatalog.Entry(patient: patient, sessions: (try? listSessions(for: patient)) ?? [])
        })
    }

    /// How global search reads the original text of the places it shows.
    var searchReader: GlobalSearchReader {
        GlobalSearchReader(
            transcript: { [weak self] patient, session in self?.transcript(for: patient, session: session) },
            notes: { [weak self] patient, session in
                guard let self else { return [] }
                return self.generatedNoteEntries(for: patient, session: session).map { entry -> GlobalSearchNote in
                    // A note from before per-format notes opens as the Summary.
                    var format: ProgressNoteFormat? = entry.format
                    if entry.isLegacy { format = .narrative }
                    return GlobalSearchNote(
                        format: format, label: format?.shortName ?? entry.raw, text: entry.text,
                        key: entry.isLegacy ? "summary" : entry.raw)
                }
            },
            sessionNotes: { [weak self] id in self?.commentStore?.note(sessionID: id) ?? "" },
            comments: { [weak self] id in self?.commentStore?.comments(sessionID: id) ?? [] }
        )
    }

    /// The file-by-file search behind global search when the index can't be
    /// read: every place `query` matches, across all patients. Patients come
    /// alphabetically (as `listPatients`), their sessions newest first. Per
    /// patient: a name match, then for each session its transcript, generated
    /// progress notes, session notes, and comments.
    ///
    /// Everything is read through the same accessors the rest of the app uses
    /// (`transcript`, `note(for:session:format:)`, the comment store), so content
    /// that can't be opened right now (locked, unreadable) simply doesn't match.
    ///
    /// Reads and decrypts every transcript and note, so it belongs off the main
    /// thread. It stops (returning what it has so far) as soon as
    /// `shouldContinue` is false, checked before each patient and session, so a
    /// superseded query doesn't keep scanning a long history.
    func searchHits(query: String, snippetRadius: Int = 40, shouldContinue: () -> Bool = { true }) -> [SearchHit] {
        guard !TextSearch.queryTerms(query).isEmpty else { return [] }
        let patients = (try? listPatients()) ?? []
        var hits: [SearchHit] = []

        func snippet(_ text: String) -> String {
            TextSearch.snippet(from: text, query: query, radius: snippetRadius) ?? ""
        }

        for patient in patients {
            guard shouldContinue() else { return hits }
            if TextSearch.matches(patient.name, query: query) {
                let sessionCount = ((try? listSessions(for: patient)) ?? []).count
                hits.append(SearchHit(
                    id: "patient-\(patient.id.uuidString)",
                    kind: .patient,
                    patient: patient,
                    session: nil,
                    noteLabel: nil,
                    commentSeconds: nil,
                    snippet: sessionCount == 1 ? "1 session" : "\(sessionCount) sessions"
                ))
            }

            for session in (try? listSessions(for: patient)) ?? [] {
                guard shouldContinue() else { return hits }
                func hit(
                    _ kind: SearchKind,
                    _ idSuffix: String,
                    text: String,
                    noteLabel: String? = nil,
                    noteFormat: ProgressNoteFormat? = nil,
                    commentID: String? = nil,
                    seconds: Double? = nil
                ) -> SearchHit {
                    SearchHit(
                        id: "\(kind.rawValue)-\(session.id.uuidString)\(idSuffix)",
                        kind: kind,
                        patient: patient,
                        session: session,
                        noteLabel: noteLabel,
                        noteFormat: noteFormat,
                        commentID: commentID,
                        commentSeconds: seconds,
                        snippet: snippet(text)
                    )
                }

                if let transcript = transcript(for: patient, session: session),
                   TextSearch.matches(transcript, query: query) {
                    hits.append(hit(.transcript, "", text: transcript))
                }

                // Generated notes, one per format. A session from before
                // per-format notes only has `summary.txt`, so that's searched
                // when no per-format note exists (otherwise it just mirrors
                // the latest one).
                var hasFormatNote = false
                for format in ProgressNoteFormat.allCases {
                    guard let text = note(for: patient, session: session, format: format) else { continue }
                    hasFormatNote = true
                    if TextSearch.matches(text, query: query) {
                        hits.append(hit(.note, "-\(format.rawValue)", text: text, noteLabel: format.shortName, noteFormat: format))
                    }
                }
                if !hasFormatNote, let text = summary(for: patient, session: session),
                   TextSearch.matches(text, query: query) {
                    hits.append(hit(.note, "-summary", text: text, noteLabel: ProgressNoteFormat.narrative.shortName, noteFormat: .narrative))
                }

                if let commentStore {
                    let notes = commentStore.note(sessionID: session.id)
                    if TextSearch.matches(notes, query: query) {
                        hits.append(hit(.sessionNotes, "", text: notes))
                    }
                    for comment in commentStore.comments(sessionID: session.id) {
                        // Prefer what the therapist wrote; fall back to the passage it's on.
                        let text: String
                        if TextSearch.matches(comment.body, query: query) {
                            text = comment.body
                        } else if TextSearch.matches(comment.quotedText, query: query) {
                            text = comment.quotedText
                        } else {
                            continue
                        }
                        hits.append(hit(.comment, "-\(comment.id)", text: text, commentID: comment.id, seconds: comment.anchorSeconds))
                    }
                }
            }
        }
        return hits
    }

    // MARK: - Export

    /// The therapist's comments on a session's transcript (none when the database isn't open).
    func comments(for session: SessionRecord) -> [SessionComment] {
        commentStore?.comments(sessionID: session.id) ?? []
    }

    func exportSessionMarkdown(patient: Patient, session: SessionRecord) -> String {
        MarkdownExporter.session(
            date: session.date,
            patientName: patient.name,
            transcript: transcript(for: patient, session: session),
            summary: summary(for: patient, session: session)
        )
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
    /// When every transcript fits, each goes in whole under its header with
    /// that session's generated notes, the therapist's own notes and her
    /// transcript comments. When they don't, the history is read by zoom level
    /// (`PatientZoom`, `zoomedPatientContext`): notes and comments, session
    /// summaries, the parts search points at and their summaries, and the
    /// lines around the best hits; no transcript goes in whole. `sources`
    /// lists only the sessions that appear in the text.
    ///
    /// `characterBudget` is the most the whole text may run to (see
    /// `AssistantService.patientContextCharacters`): background, search block,
    /// notes and comments (newest sessions first, up to a third of what is
    /// left) and the rest all come out of it.
    ///
    /// The background and the question are the therapist's own text: over
    /// `TherapistInput.characterLimit` the context carries `inputError` (and
    /// nothing is gathered); a background over a quarter of `characterBudget`
    /// goes in as the parts that match the question, and the coverage says so.
    func gatherCitedPatientContext(
        for patient: Patient,
        relevantTo question: String,
        characterBudget: Int = ContextBudget.current.availableCharacters(reserving: 0),
        includeBackground: Bool = true
    ) -> PatientContext {
        // Prepend the patient's background (clinical history + meds) when enabled
        // so the assistant can draw on it whenever it's relevant, without it having
        // to be requested. Empty when nothing has been entered or when disabled.
        let rawBackground = includeBackground ? patient.aiBackgroundBlock : ""
        do {
            try TherapistInput.check([(question, .question), (rawBackground, .background)])
        } catch let error as TherapistInput.TooLong {
            return PatientContext(text: "", sources: [], inputError: error)
        } catch {}
        let fitted = TherapistInput.fit(rawBackground, room: characterBudget / 4, query: question)
        var context = gatherPatientContext(
            for: patient, relevantTo: question, characterBudget: characterBudget, background: fitted.text)
        if fitted.excerpted { context.coverage.excerptedFields = [.background] }
        return context
    }

    private func gatherPatientContext(
        for patient: Patient,
        relevantTo question: String,
        characterBudget: Int,
        background: String
    ) -> PatientContext {
        let room = max(0, characterBudget - background.count)
        var extrasRemaining = room / 3
        var extrasUsed = 0
        var notesCut = 0
        let sessions = ((try? listSessions(for: patient)) ?? []).sorted { $0.date > $1.date }
        // Same-day sessions share a date key (the retriever groups by date too),
        // so they share one tag and cite as one source.
        var labels: [Date: String] = [:]
        var dates: [Date] = []
        var firstFolder: [Date: String] = [:]
        var extras: [Date: [String]] = [:]
        var documents: [TranscriptDocument] = []
        var searchDocuments: [SessionSearch.Document] = []
        var datedDigests: [PatientDigestMerger.DatedDigest] = []
        var sessionDigests: [ZoomSessionMaterial] = []
        var notesDates = Set<Date>()
        var unreadable = 0
        var index = 1
        for session in sessions {
            let parts = sessionMaterialParts(for: patient, session: session)
            let limit = min(Store.patientChatSessionExtrasLimit, extrasRemaining)
            // Generated notes are the model's writing: tagged as material once
            // capped, so a cut can't drop the closing tag.
            var material = (limit > 0 ? Store.capped(parts.map(\.text), limit: limit) : [])
                .enumerated().map { index, block in
                    index < parts.count && parts[index].kind == .note && block != Store.omittedNotesMarker
                        ? UntrustedText(.material, block).rendered : block
                }
            if parts.reduce(0, { $0 + $1.text.count }) > limit { notesCut += 1 }
            let materialSize = material.reduce(0) { $0 + $1.count }
            extrasRemaining -= materialSize
            let hasNotes = !material.isEmpty
            extrasUsed += materialSize + (hasNotes ? 80 : 0)   // 80: its session header
            var transcript: String?
            do {
                transcript = try readTranscript(for: patient, session: session)
            } catch {
                unreadable += 1
                material.insert(Store.unreadableTranscriptMarker, at: 0)
            }
            let transcriptText = transcript ?? ""
            // Tagged by what the session has, not by what this budget kept of it,
            // so the tags match `localToolScope(for:)`.
            guard !transcriptText.isEmpty || !material.isEmpty || !parts.isEmpty else { continue }

            if labels[session.date] == nil {
                labels[session.date] = "S\(index)"
                index += 1
                dates.append(session.date)
                firstFolder[session.date] = session.folderName
            }
            let tag = labels[session.date] ?? ""
            if !transcriptText.isEmpty {
                documents.append(TranscriptDocument(date: session.date, text: transcriptText))
                searchDocuments.append(.init(
                    date: session.date, tag: tag, kind: .transcript, text: transcriptText, session: session.id, patient: patient.id))
                let storedDigest = anyCurrentDigest(for: patient, session: session, transcript: transcriptText)
                if let storedDigest {
                    datedDigests.append(.init(
                        tag: tag,
                        date: session.date,
                        folderName: session.folderName,
                        digest: storedDigest.sessionDigest
                    ))
                }
                sessionDigests.append(ZoomSessionMaterial(
                    id: session.id, tag: tag, date: session.date, transcript: transcriptText, digest: storedDigest))
            }
            for part in parts {
                searchDocuments.append(.init(
                    date: session.date, tag: tag, kind: part.kind, text: part.text, session: session.id, patient: patient.id))
            }
            if hasNotes { notesDates.insert(session.date) }
            extras[session.date, default: []].append(contentsOf: material)
        }

        // Search every transcript, note and comment; counts are exact, and the
        // prompt states them. Transcript text comes from the best hits.
        let search = SessionSearch.search(searchDocuments, question: question, characterBudget: room)
        // What the transcripts may use: the room left after the background, the
        // notes kept and the search block (about 120 characters a term).
        let searchBlockReserve = 400 + 120 * search.terms.count
        let remainingAfterExtras = max(0, room - extrasUsed - searchBlockReserve)
        let filteredDigests = datedDigests.filter { search.dateRange?.contains($0.date) ?? true }
        let selection = PatientContextRetriever.select(
            transcripts: documents, search: search,
            characterBudget: remainingAfterExtras, labels: labels,
            wantsWholeTranscripts: SessionSearch.readsAcrossSessions(question)
        )
        // Counted from what is in `text`: a session whose transcript is
        // unreadable is not counted as read.
        let transcriptDates = Set(documents.map { $0.date }.filter { search.dateRange?.contains($0) ?? true })
        let notesCoverage = (sessions: notesDates.count, cut: notesCut)
        guard selection.whole else {
            // Too long to send whole: read it by zoom level instead.
            return zoomedPatientContext(
                ZoomInput(
                    background: background, room: remainingAfterExtras, search: search, documents: documents,
                    labels: labels, dates: dates, firstFolder: firstFolder, extras: extras,
                    digests: filteredDigests, sessionDigests: sessionDigests, transcriptDates: transcriptDates,
                    notes: notesCoverage, unreadable: unreadable
                )
            )
        }

        // Everything fits: every transcript whole, with the notes and comments.
        let excerptsByDate = Dictionary(grouping: selection.excerpts, by: { $0.date })
        var blocks: [String] = []
        var sources: [CitationSource] = []
        for date in dates {
            var parts: [String] = []
            parts.append(contentsOf: (excerptsByDate[date] ?? []).map { UntrustedText(.transcript, $0.text).rendered })
            parts.append(contentsOf: extras[date] ?? [])
            // Nothing from this session made it into the context: don't cite it.
            guard !parts.isEmpty, let tag = labels[date], let folderName = firstFolder[date] else { continue }
            let header = PatientContextRetriever.header(date, labels: labels)
            blocks.append("\(header)\n\(parts.joined(separator: "\n\n"))")
            sources.append(CitationSource(tag: tag, date: date, folderName: folderName))
        }
        let sessionsText = blocks.joined(separator: "\n\n")
        let passageDates = transcriptDates.intersection(excerptsByDate.keys)
        // The same sessions by tag, so follow-up lookups of a session already
        // read are not counted again (`TranscriptCoverage.addLookups`).
        let passageTags = Set(passageDates.compactMap { labels[$0] })
        let searchBlock = Prompts.searchBlock(
            search, shown: selection.hitsShown, whole: true, unreadableSessions: unreadable
        )
        let text = [background, searchBlock, sessionsText]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        var coverage = TranscriptCoverage(
            transcriptSessions: selection.totalCount,
            sessionsWithPassages: selection.wholeCount,
            notesSessions: notesDates.count,
            unreadableSessions: unreadable,
            mentions: search.totalMentions - search.similarMentions,
            similarMentions: search.similarMentions,
            searched: !search.terms.isEmpty,
            wholeTranscripts: true,
            fullTexts: true,
            notesCutSessions: notesCut,
            passageTags: passageTags
        )
        coverage.noteSearch(search)
        return PatientContext(text: text, sources: sources, unreadableSessions: unreadable, coverage: coverage)
    }

    /// What `zoomedPatientContext` works from, gathered by `gatherCitedPatientContext`.
    private struct ZoomInput {
        let background: String
        /// Characters left for session material after the background, the notes and the search block.
        let room: Int
        let search: SessionSearch.Result
        let documents: [TranscriptDocument]
        let labels: [Date: String]
        /// Session dates with material, newest first.
        let dates: [Date]
        let firstFolder: [Date: String]
        /// Each date's notes and comments, already capped.
        let extras: [Date: [String]]
        /// Current digests of sessions in the question's date range.
        let digests: [PatientDigestMerger.DatedDigest]
        /// Every session with a readable transcript: its tag, date, transcript and current digest.
        let sessionDigests: [ZoomSessionMaterial]
        /// Dates in range with a readable transcript.
        let transcriptDates: Set<Date>
        let notes: (sessions: Int, cut: Int)
        let unreadable: Int
    }

    struct ZoomSessionMaterial {
        let id: UUID
        let tag: String
        let date: Date
        let transcript: String
        let digest: SessionDigest?
    }

    /// The patient's history read by zoom level (`PatientZoom`) when it is too
    /// long to send whole: notes and comments (already in `extras`), session
    /// summaries up to their share, the parts search points at with their
    /// summaries, and the transcript lines around the best hits; or, when
    /// search has no lines to quote, the openings of sessions with no summary
    /// yet in what the summaries' share has left. No transcript goes in whole;
    /// a part is read in full only when the model asks for it.
    private func zoomedPatientContext(_ input: ZoomInput) -> PatientContext {
        let search = input.search
        let shares = PatientZoom.Shares(room: input.room)

        // 1,000 ft: summaries, newest first, older ones merged by month.
        // Each summary kept under its own session header needs room for that header.
        let individualLimit = PatientZoom.individualSummaryLimit(summaryRoom: shares.summaries)
        let digestPlan = PatientDigestMerger.plan(
            digests: input.digests,
            recentIndividualLimit: individualLimit,
            characterBudget: max(0, shares.summaries - individualLimit * PatientZoom.headerAllowance)
        )
        var summariesUsed = digestPlan.individualByDate.count * PatientZoom.headerAllowance
        for block in digestPlan.individualByDate.values { summariesUsed += block.count + 2 }
        for month in digestPlan.monthBlocks { summariesUsed += month.text.count + 2 }

        // 500 ft: the parts of sessions the hits fall in, and the summaries that name the question's words.
        var hitSessions = Set<UUID>()
        for hit in search.hits where hit.kind == .transcript {
            if let id = hit.sessionID { hitSessions.insert(id) }
        }
        var inputs: [PatientZoom.SessionInput] = []
        for material in input.sessionDigests where input.transcriptDates.contains(material.date) {
            let hit = hitSessions.contains(material.id)
            guard material.digest != nil || hit else { continue }
            let parts = material.digest == nil ? TranscriptSections.split(material.transcript) : []
            let lineCount = hit ? LineTable(material.transcript).count : 0
            inputs.append(PatientZoom.SessionInput(
                tag: material.tag, date: material.date, sessionID: material.id,
                digest: material.digest, parts: parts, lineCount: lineCount
            ))
        }
        let ranked = PatientZoom.areas(sessions: inputs, hits: search.hits, stems: PatientZoom.stems(of: search.terms))
        let areasBlock = PatientZoom.areasBlock(ranked, budget: shares.areas)
        let listed = areasBlock?.shown ?? []
        let areasUsed = areasBlock.map { $0.text.count + 2 } ?? 0

        // 100 ft: the summaries of those parts, then the lines around the best hits.
        let sectionAreas = PatientZoom.sectionSummaries(listed, budget: shares.sections)
        var sectionsUsed = 0
        var sectionsByDate: [Date: [String]] = [:]
        for area in sectionAreas {
            let block = PatientZoom.sectionSummaryBlock(area)
            sectionsUsed += block.count + 2 + PatientZoom.headerAllowance
            sectionsByDate[area.date, default: []].append(block)
        }
        let passageRoom = max(0, input.room - summariesUsed - areasUsed - sectionsUsed)
        let hasTranscriptHits = search.hits.contains { $0.kind == .transcript }
        var excerpts: [PatientContextRetriever.Excerpt] = []
        var hitsShown = 0
        if !search.terms.isEmpty, hasTranscriptHits, passageRoom > 200 {
            // The transcripts don't fit `room`, or the question is about one
            // thing: `select` keeps the best hits' lines, never whole transcripts.
            let passages = PatientContextRetriever.select(
                transcripts: input.documents, search: search, characterBudget: passageRoom, labels: input.labels,
                wantsWholeTranscripts: false
            )
            if !passages.fullTexts {
                excerpts = passages.excerpts
                hitsShown = passages.hitsShown
            }
        }
        let excerptsByDate = Dictionary(grouping: excerpts, by: { $0.date })

        // 1,000 ft, continued: with no transcript lines to quote (no words to
        // search for, or none in a transcript), the room the summaries' share
        // keeps for summaries not built yet would go unused. It goes to the
        // openings of those sessions' transcripts instead, newest first.
        var openings: [PatientZoom.Opening] = []
        if excerpts.isEmpty {
            let unsummarized = input.sessionDigests
                .filter { $0.digest == nil && input.transcriptDates.contains($0.date) }
                .map { PatientZoom.OpeningInput(tag: $0.tag, date: $0.date, transcript: $0.transcript) }
            openings = PatientZoom.openings(unsummarized, budget: max(0, shares.summaries - summariesUsed))
        }
        let openingsByDate = Dictionary(grouping: openings, by: { $0.date })
        let openingDates = Set(openings.map(\.date))

        var blocks: [String] = []
        var sources: [CitationSource] = []
        var seenTags = Set<String>()
        for date in input.dates {
            var parts: [String] = []
            if let digestBlock = digestPlan.individualByDate[date] { parts.append(digestBlock) }
            parts.append(contentsOf: (openingsByDate[date] ?? []).map(\.block))
            parts.append(contentsOf: sectionsByDate[date] ?? [])
            parts.append(contentsOf: (excerptsByDate[date] ?? []).map { UntrustedText(.transcript, $0.text).rendered })
            parts.append(contentsOf: input.extras[date] ?? [])
            guard !parts.isEmpty, let tag = input.labels[date], let folderName = input.firstFolder[date] else { continue }
            blocks.append("\(PatientContextRetriever.header(date, labels: input.labels))\n\(parts.joined(separator: "\n\n"))")
            if seenTags.insert(tag).inserted {
                sources.append(CitationSource(tag: tag, date: date, folderName: folderName))
            }
        }
        for month in digestPlan.monthBlocks {
            blocks.append(month.text)
            for source in month.sources where seenTags.insert(source.tag).inserted {
                sources.append(source)
            }
        }
        // A listed part says what search found in that session, so it can be cited.
        for area in listed where !seenTags.contains(area.tag) {
            guard let folderName = input.firstFolder[area.date] else { continue }
            seenTags.insert(area.tag)
            sources.append(CitationSource(tag: area.tag, date: area.date, folderName: folderName))
        }
        sources.sort { $0.date > $1.date }

        let passageDates = input.transcriptDates.intersection(excerptsByDate.keys)
        let passageTags = Set(passageDates.compactMap { input.labels[$0] })
        var digestTags = Set(digestPlan.individualByDate.keys.compactMap { input.labels[$0] })
        for month in digestPlan.monthBlocks { digestTags.formUnion(month.tags) }
        let digestDates = Set(input.digests.map(\.date))
        var searchOnly = 0
        var noSummary = 0
        for date in input.transcriptDates {
            guard let tag = input.labels[date], !digestTags.contains(tag), !openingDates.contains(date) else { continue }
            searchOnly += 1
            if !digestDates.contains(date) { noSummary += 1 }
        }

        let searchBlock = Prompts.searchBlock(
            search, shown: hitsShown, whole: false, layered: true, openings: openingDates.count,
            unreadableSessions: input.unreadable
        )
        let text = [input.background, searchBlock, areasBlock?.text ?? "", blocks.joined(separator: "\n\n")]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        var coverage = TranscriptCoverage(
            transcriptSessions: input.transcriptDates.count,
            sessionsWithPassages: passageDates.count,
            notesSessions: input.notes.sessions,
            unreadableSessions: input.unreadable,
            mentions: search.totalMentions - search.similarMentions,
            similarMentions: search.similarMentions,
            searched: !search.terms.isEmpty,
            notesCutSessions: input.notes.cut,
            digestSessions: digestPlan.digestSessionCount,
            monthMergedSessions: digestPlan.monthMergedSessionCount,
            passageTags: passageTags,
            digestTags: digestTags
        )
        coverage.layered = true
        coverage.areas = listed.count
        coverage.summarySections = sectionAreas.count
        coverage.searchOnlySessions = searchOnly
        coverage.noSummarySessions = noSummary
        coverage.openingSessions = openingDates.count
        coverage.noteSearch(search)
        return PatientContext(text: text, sources: sources, unreadableSessions: input.unreadable, coverage: coverage)
    }

    /// Builds a read-only `LocalToolScope` over all readable sessions of `patient`,
    /// tagged `S1`, `S2`, … in newest-first order matching `gatherCitedPatientContext`.
    func localToolScope(for patient: Patient) -> LocalToolScope {
        let sessions = ((try? listSessions(for: patient)) ?? []).sorted { $0.date > $1.date }
        var labels: [Date: String] = [:]
        var index = 1
        var toolSessions: [LocalToolSession] = []
        for session in sessions {
            // An unreadable transcript still takes its tag, as it does in the context.
            var unreadable = false
            var transcriptText = ""
            do {
                transcriptText = try readTranscript(for: patient, session: session) ?? ""
            } catch {
                unreadable = true
            }
            let notes = commentStore?.note(sessionID: session.id) ?? ""
            let comments = AssistantService.formatComments(commentStore?.comments(sessionID: session.id) ?? [])
            let generated = generatedNotes(for: patient, session: session)
                .map { "Generated progress note (\($0.0)):\n\($0.1)" }
            let combinedNotes = ([notes] + generated)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            guard !transcriptText.isEmpty || unreadable || !combinedNotes.isEmpty || !comments.isEmpty else { continue }
            if labels[session.date] == nil {
                labels[session.date] = "S\(index)"
                index += 1
            }
            let tag = labels[session.date] ?? "S\(index)"
            let digest = !transcriptText.isEmpty
                ? anyCurrentDigest(for: patient, session: session, transcript: transcriptText)
                : nil
            toolSessions.append(LocalToolSession(
                id: session.id,
                tag: tag,
                date: session.date,
                folderName: session.folderName,
                transcript: transcriptText,
                digest: digest,
                notes: combinedNotes,
                comments: comments
            ))
        }
        return LocalToolScope(sessions: toolSessions)
    }

    /// The blocks the patient-wide chat adds under a session's header besides the
    /// transcript (the caller caps them to `patientChatSessionExtrasLimit` in
    /// total). Order is the therapist's own words first (her notes, then her
    /// comments, as the single-session chat renders them), then generated
    /// notes, so a long generated note is what gets cut. Unreadable notes are
    /// skipped. Each block's kind says what it is, for search.
    private func sessionMaterialParts(for patient: Patient, session: SessionRecord) -> [(kind: SessionSearch.Kind, text: String)] {
        var blocks: [(kind: SessionSearch.Kind, text: String)] = []

        let notes = commentStore?.note(sessionID: session.id) ?? ""
        let comments = AssistantService.formatComments(commentStore?.comments(sessionID: session.id) ?? [])
        let therapistSections: [(SessionSearch.Kind, String)] = [
            (.sessionNotes, Prompts.therapistMaterial(notes: notes, comments: [])),
            (.comment, Prompts.therapistMaterial(notes: "", comments: comments)),
        ]
        for (kind, section) in therapistSections {
            let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { blocks.append((kind, trimmed)) }
        }

        for (label, text) in generatedNotes(for: patient, session: session) {
            blocks.append((.note, "Generated progress note (\(label)):\n\(text)"))
        }
        return blocks
    }

    /// A session's generated notes, one per format that has been generated, as
    /// (format label, text). Falls back to the legacy `summary.txt` when no
    /// per-format file exists. Reads files directly rather than through
    /// `note(for:session:format:)`, which adopts a legacy summary by writing.
    private func generatedNotes(for patient: Patient, session: SessionRecord) -> [(String, String)] {
        generatedNoteEntries(for: patient, session: session).map { entry -> (String, String) in
            let label = entry.isLegacy ? "earlier format" : (entry.format?.shortName ?? entry.raw)
            return (label, entry.text)
        }
    }

    /// One generated note file: `raw` is the format part of its name
    /// ("note.soap.txt" -> "soap"); `isLegacy` marks the `summary.txt` of a
    /// session from before per-format notes.
    struct GeneratedNoteEntry {
        let raw: String
        let format: ProgressNoteFormat?
        let text: String
        let isLegacy: Bool
    }

    /// The non-empty generated notes, by file name, trimmed; the legacy summary
    /// when there is no per-format note file at all.
    func generatedNoteEntries(for patient: Patient, session: SessionRecord) -> [GeneratedNoteEntry] {
        let dir = sessionDir(for: patient, session: session)
        let names = ((try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { Store.isNoteFileName($0) }
            .sorted()
        var result: [GeneratedNoteEntry] = []
        for name in names {
            let url = dir.appendingPathComponent(name)
            let text = ((try? protector.stringIfPresent(at: url)) ?? nil) ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let raw = String(name.dropFirst("note.".count).dropLast(".txt".count))
            result.append(GeneratedNoteEntry(raw: raw, format: ProgressNoteFormat(rawValue: raw), text: trimmed, isLegacy: false))
        }
        if names.isEmpty, let legacy = summary(for: patient, session: session) {
            let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result.append(GeneratedNoteEntry(raw: "summary", format: nil, text: trimmed, isLegacy: true))
            }
        }
        return result
    }

    /// Keeps as many of `blocks` as fit in `limit` characters, cutting the block
    /// that crosses the limit with a marker and noting if later ones were left out.
    static let omittedNotesMarker = "[further notes omitted]"

    static func capped(_ blocks: [String], limit: Int) -> [String] {
        var remaining = limit
        var kept: [String] = []
        for block in blocks {
            if remaining <= 0 {
                kept.append(omittedNotesMarker)
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
