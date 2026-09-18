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
///   <dataRoot>/Patients/<Patient-Slug>/patient_chat.json
///   <dataRoot>/Patients/<Patient-Slug>/YYYY-MM-DD_Session/
///       mic.caf            (therapist's microphone)
///       call.caf            (the other side of the call, captured system audio)
///       transcript.txt
///       summary.txt
///       chat.json
///
/// `gatherPatientContext` is the one place cross-transcript context gets
/// assembled for the chat feature. It's intentionally naive (concatenate
/// everything) so it's the single spot to swap in real retrieval later.
final class Store {
    private let root: URL
    private let fileManager = FileManager.default
    /// Transparently seals/opens every PHI file this store reads or writes.
    /// `.passthrough` (the default) is a byte-for-byte no-op, so the store
    /// behaves exactly as before when encryption is off.
    private let protector: FileProtector
    private let dateFolderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Result of reconciling this data folder's schema stamp with the version
    /// this build understands, computed once when the store opens.
    let schemaCompatibility: SchemaCompatibility

    init(root: URL, protector: FileProtector = .passthrough) {
        self.root = root
        self.protector = protector
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
            return try? JSONDecoder.sessionNotes.decode(Patient.self, from: data)
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
        let data = try JSONEncoder.sessionNotes.encode(patient)
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
            guard folder.lastPathComponent.hasSuffix("_Session") else { return nil }
            guard let isDir = try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDir else { return nil }
            // The date is always the leading "YYYY-MM-DD" of the folder
            // name, whether it's "…_Session" or a collision-suffixed
            // "…_Session-2".
            let dateString = String(folder.lastPathComponent.prefix(10))
            let date = dateFolderFormatter.date(from: dateString) ?? Date.distantPast
            return SessionRecord(
                id: StableID.uuid(from: folder.lastPathComponent),
                patientId: patient.id,
                date: date,
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
        return SessionRecord(id: StableID.uuid(from: folderName), patientId: patient.id, date: date, folderName: folderName)
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

    func loadSessionChat(for patient: Patient, session: SessionRecord) -> [ChatMessage] {
        loadChat(at: sessionDir(for: patient, session: session).appendingPathComponent("chat.json"))
    }

    func saveSessionChat(_ messages: [ChatMessage], for patient: Patient, session: SessionRecord) throws {
        try saveChat(messages, at: sessionDir(for: patient, session: session).appendingPathComponent("chat.json"))
    }

    func loadPatientChat(for patient: Patient) -> [ChatMessage] {
        loadChat(at: patientDir(for: patient).appendingPathComponent("patient_chat.json"))
    }

    func savePatientChat(_ messages: [ChatMessage], for patient: Patient) throws {
        try saveChat(messages, at: patientDir(for: patient).appendingPathComponent("patient_chat.json"))
    }

    private func loadChat(at url: URL) -> [ChatMessage] {
        guard let data = (try? protector.dataIfPresent(at: url)) ?? nil else { return [] }
        return (try? JSONDecoder.sessionNotes.decode([ChatMessage].self, from: data)) ?? []
    }

    private func saveChat(_ messages: [ChatMessage], at url: URL) throws {
        let data = try JSONEncoder.sessionNotes.encode(messages)
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
private let sessionNotesDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

extension JSONEncoder {
    static let sessionNotes: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(sessionNotesDateFormatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let sessionNotes: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = sessionNotesDateFormatter.date(from: string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(string)")
            }
            return date
        }
        return decoder
    }()
}
