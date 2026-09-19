import Foundation

enum StoreError: LocalizedError {
    case noDataRoot
    case patientNotFound
    case sessionNotFound

    var errorDescription: String? {
        switch self {
        case .noDataRoot: return "No data folder has been chosen yet. Open Settings to pick one."
        case .patientNotFound: return "That patient couldn't be found on disk."
        case .sessionNotFound: return "That session couldn't be found on disk."
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
///       summary.txt
///
/// Identity is a persisted `UUID`, never the path. A patient's id lives in
/// `patient.json`, a session's in `session.json` — both assigned once at
/// creation. The folder names (`<Patient-Slug>/`, `YYYY-MM-DD_Session/`) are a
/// human-friendly *organization* detail, freely renamable: the SQLite store
/// (`CommentStore`) keys comments/notes/chats on those ids, so annotations
/// follow a session or patient across a rename or move. A folder that turns up
/// without a `session.json` (created before this scheme, or dropped in by hand)
/// is minted an id on first listing and stays stable from then on.
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
    private let dateFolderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Result of reconciling this data folder's schema stamp with the version
    /// this build understands, computed once when the store opens.
    let schemaCompatibility: SchemaCompatibility

    init(root: URL, protector: FileProtector = .passthrough, commentStore: CommentStore? = nil) {
        self.root = root
        self.protector = protector
        self.commentStore = commentStore ?? CommentStore(root: root, protector: protector)
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

    func listPatients() throws -> [Patient] {
        try fileManager.createDirectory(at: patientsDir, withIntermediateDirectories: true)
        let entries = try fileManager.contentsOfDirectory(at: patientsDir, includingPropertiesForKeys: nil)
        let patients: [Patient] = entries.compactMap { dir in
            let file = dir.appendingPathComponent("patient.json")
            guard let data = (try? protector.dataIfPresent(at: file)) ?? nil else { return nil }
            return try? JSONDecoder.aletheia.decode(Patient.self, from: data)
        }
        return patients.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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

    func listSessions(for patient: Patient) throws -> [SessionRecord] {
        let dir = patientDir(for: patient)
        guard fileManager.fileExists(atPath: dir.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])
        let sessions: [SessionRecord] = entries.compactMap { folder in
            guard let isDir = try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDir else { return nil }
            // A session folder is one carrying a `session.json` identity record,
            // or (legacy / manually created) one named "…_Session". The latter
            // is minted an id on sight so it becomes stable from here on.
            let hasMetadata = fileManager.fileExists(atPath: sessionMetadataURL(for: folder).path)
            guard hasMetadata || folder.lastPathComponent.hasSuffix("_Session") else { return nil }
            let meta = sessionMetadata(for: folder)
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
        return sessions.sorted { $0.date > $1.date }
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

    /// Reads a session folder's persisted identity, minting and persisting one
    /// the first time a folder is seen without it (a folder from before this
    /// scheme, or one a therapist created by hand in Finder). The date falls
    /// back to the folder name's leading `YYYY-MM-DD` for such folders.
    ///
    /// Written as **plaintext**, not through the `protector`: it carries no name
    /// or note text — only a UUID and the session date, and that date is already
    /// visible in the cleartext folder name. Keeping it plaintext also keeps
    /// identity independent of the encryption toggle (`DataMigrator` doesn't
    /// rewrite this file), so turning encryption on/off can never orphan a
    /// session by leaving its id file unreadable.
    private func sessionMetadata(for sessionDir: URL) -> SessionMetadata {
        let url = sessionMetadataURL(for: sessionDir)
        if let data = try? Data(contentsOf: url),
           let meta = try? JSONDecoder.aletheia.decode(SessionMetadata.self, from: data) {
            return meta
        }
        let dateString = String(sessionDir.lastPathComponent.prefix(10))
        let date = dateFolderFormatter.date(from: dateString) ?? Date.distantPast
        let meta = SessionMetadata(id: UUID(), date: date)
        try? writeSessionMetadata(meta, to: url)
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
        let url = sessionDir(for: patient, session: session).appendingPathComponent("transcript.txt")
        return (try? protector.stringIfPresent(at: url)) ?? nil
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

    // MARK: - Chat

    /// A session's assistant conversation, read from the DB. Any leftover
    /// `chat.json` (from a build before this offload) is imported into the DB and
    /// removed the first time this runs.
    func loadSessionChat(for patient: Patient, session: SessionRecord) -> [ChatMessage] {
        migrateLegacySessionChat(for: patient, session: session)
        return commentStore?.sessionChat(sessionID: session.id) ?? []
    }

    func saveSessionChat(_ messages: [ChatMessage], for patient: Patient, session: SessionRecord) throws {
        commentStore?.saveSessionChat(messages, sessionID: session.id)
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

    func saveChatThread(_ thread: ChatThread, for patient: Patient) throws {
        commentStore?.saveChatThread(thread, patientID: patient.id)
    }

    func deleteChatThread(id: UUID, for patient: Patient) throws {
        commentStore?.deleteChatThread(id: id, patientID: patient.id)
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

    /// Like `gatherPatientContext(for:relevantTo:)`, but also assigns each
    /// session a short citation tag (`S1` newest first) embedded in its header,
    /// and returns the tag→session mapping. This is what lets the chat show
    /// which sessions an answer drew from (see `Citations`).
    func gatherCitedPatientContext(for patient: Patient, relevantTo question: String) -> PatientContext {
        let sessions = ((try? listSessions(for: patient)) ?? []).sorted { $0.date > $1.date }
        var labels: [Date: String] = [:]
        var sources: [CitationSource] = []
        var documents: [TranscriptDocument] = []
        var index = 1
        for session in sessions {
            guard let transcript = transcript(for: patient, session: session), !transcript.isEmpty else { continue }
            let tag = "S\(index)"
            index += 1
            // Same-day sessions share a date key; the retriever groups by date
            // too, so they cite as one source — consistent with how it renders.
            labels[session.date] = tag
            sources.append(CitationSource(tag: tag, date: session.date, folderName: session.folderName))
            documents.append(TranscriptDocument(date: session.date, text: transcript))
        }
        let transcriptsText = PatientContextRetriever.context(for: documents, question: question, labels: labels)
        // Always prepend the patient's background (clinical history + meds) so the
        // assistant can draw on it whenever it's relevant, without it having to be
        // requested. Empty when nothing has been entered.
        let background = patient.aiBackgroundBlock
        let text = [background, transcriptsText]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        return PatientContext(text: text, sources: sources)
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
