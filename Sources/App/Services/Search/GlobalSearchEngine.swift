import Foundation

/// Runs a global search: patients and sessions from the catalog, notes,
/// comments and transcripts from the index, snippets from the original text.
///
/// Cost per query (no full scan): one listing of patients and sessions, one
/// FTS5 MATCH per word over the index, and reading the original text of the
/// transcripts shown (at most the transcript limit) and of the sessions whose
/// notes or comments matched (small files, read to cut snippets and to drop
/// passages that matched only a heading such as "Generated progress note").
enum GlobalSearchEngine {
    /// Answers `query` from `index`. nil when the index can't be read; the
    /// caller then reads every file instead (`scannedResults`).
    static func search(
        _ query: GlobalSearchQuery,
        catalog: GlobalSearchCatalog,
        index: SearchIndex,
        reader: GlobalSearchReader,
        limits: GlobalSearchLimits,
        calendar: Calendar,
        shouldContinue: () -> Bool
    ) -> GlobalSearchResults? {
        guard !query.isEmpty else { return .empty }
        // Taken before the index is read: whatever is indexed after it can only
        // make the results more complete than this says.
        var coverage = GlobalSearchCoverage(index.progress.snapshot())
        let context = GlobalSearchContext(query: query, calendar: calendar)
        var sections = catalogSections(query, catalog: catalog, context: context, limits: limits)
        let clauses = query.textTerms.map { $0.clause }
        switch index.matchLive(clauses: clauses, shouldContinue: shouldContinue) {
        case .unavailable:
            return nil
        case .cancelled:
            return .empty
        case .found(let documents, let passages):
            let ranked = GlobalSearchRanking.rank(passages: passages, documents: documents) { document in
                guard let place = catalog.place(session: document.session) else { return nil }
                return context.answered(place)
            }
            let found = textSections(
                ranked: ranked, documents: documents, catalog: catalog, reader: reader,
                limits: limits, context: context, shouldContinue: shouldContinue)
            sections += found.sections
            if found.staleSessions > 0, coverage == .complete {
                coverage = .indexing(sessions: found.staleSessions)
            }
        }
        return results(sections, coverage: coverage)
    }

    /// The results when the index couldn't be read: patients and sessions as
    /// usual, the rest from `Store.searchHits`, which read every file.
    static func scannedResults(
        _ query: GlobalSearchQuery,
        catalog: GlobalSearchCatalog,
        scanned: [SearchHit],
        limits: GlobalSearchLimits,
        calendar: Calendar
    ) -> GlobalSearchResults {
        guard !query.isEmpty else { return .empty }
        let context = GlobalSearchContext(query: query, calendar: calendar)
        var sections = catalogSections(query, catalog: catalog, context: context, limits: limits)
        for kind in [SearchKind.sessionNotes, .note, .comment, .transcript] {
            sections.append(section(kind, scanned.filter { $0.kind == kind }, limits: limits))
        }
        return results(sections, coverage: .scanned)
    }

    private static func results(_ sections: [GlobalSearchSection], coverage: GlobalSearchCoverage) -> GlobalSearchResults {
        let order = SearchKind.allCases
        let kept = sections.filter { $0.total > 0 }.sorted { a, b in
            (order.firstIndex(of: a.kind) ?? 0) < (order.firstIndex(of: b.kind) ?? 0)
        }
        return GlobalSearchResults(sections: kept, coverage: coverage)
    }

    static func section(_ kind: SearchKind, _ all: [SearchHit], limits: GlobalSearchLimits) -> GlobalSearchSection {
        GlobalSearchSection(kind: kind, hits: Array(all.prefix(limits.limit(for: kind))), total: all.count)
    }

    // MARK: Patients and sessions

    /// Patients by name (alphabetically) and sessions by date (newest first).
    static func catalogSections(
        _ query: GlobalSearchQuery, catalog: GlobalSearchCatalog, context: GlobalSearchContext, limits: GlobalSearchLimits
    ) -> [GlobalSearchSection] {
        var patients: [SearchHit] = []
        var places: [GlobalSearchCatalog.Place] = []
        for entry in catalog.entries {
            let name = context.nameForm(entry.patient)
            if query.matchesPatient(nameForm: name) {
                let count = entry.sessions.count
                patients.append(SearchHit(
                    id: "patient-\(entry.patient.id.uuidString)", kind: .patient, patient: entry.patient, session: nil,
                    snippet: count == 1 ? "1 session" : "\(count) sessions"))
            }
            for session in entry.sessions where query.matchesSession(date: context.date(session), nameForm: name) {
                places.append(GlobalSearchCatalog.Place(patient: entry.patient, session: session))
            }
        }
        places.sort(by: newerFirst)
        let sessions = places.map { place in
            SearchHit(
                id: "session-\(place.session.id.uuidString)", kind: .session, patient: place.patient, session: place.session,
                snippet: contents(of: place.session))
        }
        return [section(.patient, patients, limits: limits), section(.session, sessions, limits: limits)]
    }

    private static func newerFirst(_ a: GlobalSearchCatalog.Place, _ b: GlobalSearchCatalog.Place) -> Bool {
        if a.session.date != b.session.date { return a.session.date > b.session.date }
        let names = a.patient.name.localizedCaseInsensitiveCompare(b.patient.name)
        if names != .orderedSame { return names == .orderedAscending }
        return a.session.id.uuidString < b.session.id.uuidString
    }

    /// What a session holds, for its result row: "Transcript · Progress note".
    static func contents(of session: SessionRecord) -> String {
        var parts: [String] = []
        if session.hasTranscript {
            parts.append("Transcript")
        } else if session.hasRecording {
            parts.append("Recording")
        }
        if session.hasSummary { parts.append("Progress note") }
        return parts.isEmpty ? "Nothing recorded yet" : parts.joined(separator: " \u{00B7} ")
    }

    // MARK: Notes, comments and transcripts

    private struct TextSections {
        var sections: [GlobalSearchSection]
        /// Sessions whose transcript changed since it was indexed (its save is still queued).
        var staleSessions: Int
    }

    private static func textSections(
        ranked: [GlobalSearchRanking.Ranked],
        documents: [Int64: SearchIndex.LiveDocument],
        catalog: GlobalSearchCatalog,
        reader: GlobalSearchReader,
        limits: GlobalSearchLimits,
        context: GlobalSearchContext,
        shouldContinue: () -> Bool
    ) -> TextSections {
        // Transcripts one by one; notes, comments and "my notes" by session, best session first.
        var transcripts: [GlobalSearchRanking.Ranked] = []
        var sessions: [SessionSearch.Kind: [String]] = [:]
        var seen: [SessionSearch.Kind: Set<String>] = [:]
        for match in ranked {
            guard let document = documents[match.doc], let kind = SessionSearch.Kind(rawValue: document.kind) else { continue }
            if kind == .transcript {
                transcripts.append(match)
            } else if seen[kind, default: []].insert(document.session).inserted {
                sessions[kind, default: []].append(document.session)
            }
        }
        let terms = context.query.textTerms
        var stale = Set<String>()

        var myNotes: [SearchHit] = []
        for key in sessions[.sessionNotes] ?? [] {
            guard shouldContinue() else { break }
            guard let place = catalog.place(session: key) else { continue }
            let paragraphs = GlobalSearchText.paragraphs(reader.sessionNotes(place.session.id))
            guard let best = GlobalSearchText.bestPassage(paragraphs, terms: terms, answered: context.answered(place)) else { continue }
            myNotes.append(SearchHit(
                id: "sessionNotes-\(key)", kind: .sessionNotes, patient: place.patient, session: place.session,
                snippet: GlobalSearchText.snippet(paragraphs[best], terms: terms)))
        }

        var notes: [SearchHit] = []
        for key in sessions[.note] ?? [] {
            guard shouldContinue() else { break }
            guard let place = catalog.place(session: key) else { continue }
            let answered = context.answered(place)
            for note in reader.notes(place.patient, place.session) {
                let paragraphs = GlobalSearchText.paragraphs(note.text)
                guard let best = GlobalSearchText.bestPassage(paragraphs, terms: terms, answered: answered) else { continue }
                notes.append(SearchHit(
                    id: "note-\(key)-\(note.key)", kind: .note, patient: place.patient, session: place.session,
                    noteLabel: note.label, noteFormat: note.format, passage: best,
                    snippet: GlobalSearchText.snippet(paragraphs[best], terms: terms)))
            }
        }

        var comments: [SearchHit] = []
        let full = context.query.allTermsMask
        for key in sessions[.comment] ?? [] {
            guard shouldContinue() else { break }
            guard let place = catalog.place(session: key) else { continue }
            let answered = context.answered(place)
            for comment in reader.comments(place.session.id) {
                let inBody = GlobalSearchText.mask(of: comment.body, terms: terms)
                let inQuote = GlobalSearchText.mask(of: comment.quotedText, terms: terms)
                let inText = inBody | inQuote
                guard inText != 0, (inText | answered) & full == full else { continue }
                // Prefer what the therapist wrote; fall back to the passage it's on.
                let shown = inBody != 0 ? comment.body : comment.quotedText
                comments.append(SearchHit(
                    id: "comment-\(key)-\(comment.id)", kind: .comment, patient: place.patient, session: place.session,
                    commentID: comment.id, commentSeconds: comment.anchorSeconds,
                    snippet: GlobalSearchText.snippet(shown, terms: terms)))
            }
        }

        let transcriptLimit = limits.limit(for: .transcript)
        var shown: [SearchHit] = []
        var dropped = 0
        for match in transcripts {
            guard shown.count < transcriptLimit, shouldContinue() else { break }
            guard let document = documents[match.doc], let place = catalog.place(session: document.session) else {
                dropped += 1
                continue
            }
            guard let text = reader.transcript(place.patient, place.session) else {
                stale.insert(document.session)
                dropped += 1
                continue
            }
            let lines = LineTable(text)
            var line = match.line
            if line >= lines.count || SearchIndex.fingerprint(of: text) != document.fingerprint {
                // Edited since it was indexed: find the passage in the text as it is now.
                stale.insert(document.session)
                var spoken: [String] = []
                for i in 0..<lines.count { spoken.append(TranscriptTimeline.spokenText(lines[i])) }
                guard let found = GlobalSearchText.bestPassage(spoken, terms: terms, answered: context.answered(place)) else {
                    dropped += 1
                    continue
                }
                line = found
            }
            shown.append(SearchHit(
                id: "transcript-\(document.session)", kind: .transcript, patient: place.patient, session: place.session,
                passage: line,
                snippet: GlobalSearchText.snippet(
                    TranscriptStyler.forReader(lines[line], callAudioName: Prompts.clientFirstName(place.patient.name)), terms: terms)))
        }
        let transcriptSection = GlobalSearchSection(kind: .transcript, hits: shown, total: max(shown.count, transcripts.count - dropped))

        return TextSections(
            sections: [
                section(.sessionNotes, myNotes, limits: limits),
                section(.note, notes, limits: limits),
                section(.comment, comments, limits: limits),
                transcriptSection,
            ],
            staleSessions: stale.count)
    }
}

/// Names and dates as the query compares them, worked out once per patient
/// and session for one query.
final class GlobalSearchContext {
    let query: GlobalSearchQuery
    let calendar: Calendar
    private let monthNames: [[String]]
    private var names: [UUID: String] = [:]
    private var dates: [UUID: GlobalSearchDate] = [:]

    init(query: GlobalSearchQuery, calendar: Calendar) {
        self.query = query
        self.calendar = calendar
        self.monthNames = GlobalSearchDate.monthNameTable(calendar: calendar)
    }

    func nameForm(_ patient: Patient) -> String {
        if let known = names[patient.id] { return known }
        let form = GlobalSearchQuery.nameForm(patient.name)
        names[patient.id] = form
        return form
    }

    func date(_ session: SessionRecord) -> GlobalSearchDate {
        if let known = dates[session.id] { return known }
        let date = GlobalSearchDate(session.date, calendar: calendar, monthNames: monthNames)
        dates[session.id] = date
        return date
    }

    /// The text terms this place's patient name or session date answers.
    func answered(_ place: GlobalSearchCatalog.Place) -> UInt32 {
        query.termsAnsweredBy(date: date(place.session), nameForm: nameForm(place.patient))
    }
}
