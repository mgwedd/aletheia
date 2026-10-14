import Foundation

struct TranscriptDocument {
    let date: Date
    let text: String
}

/// Selects the transcript passages most relevant to a question so the
/// cross-session chat can answer from a large history without stuffing every
/// word into the prompt.
///
/// Relevance comes from `SessionSearch` (BM25, whole words, typo and
/// sound-alike matching). When a patient's transcripts fit the budget, or the
/// question has no search terms, whole transcripts go in newest first;
/// otherwise the best hits' context
/// windows are kept, merged per session and regrouped by date, newest first,
/// with the same `===== Session <date> =====` headers so the model can still
/// cite when something was said.
enum PatientContextRetriever {
    /// The transcript text kept for one session date, before any header is put
    /// on it. Exposed so a caller that adds its own per-session material (see
    /// `Store.gatherCitedPatientContext`) can tell which sessions the ranker
    /// kept and put everything under one header.
    struct Excerpt {
        let date: Date
        let text: String
    }

    /// What `select` kept, and how many transcript hits it shows.
    struct Selection {
        let excerpts: [Excerpt]
        /// Search hits in transcripts whose text is in `excerpts`.
        let hitsShown: Int
        /// Whole transcripts were sent, not search windows.
        let whole: Bool
    }

    /// Transcript characters the patient-wide chat sends per question.
    static let defaultCharacterBudget = 6000

    static func context(
        for documents: [TranscriptDocument],
        question: String,
        characterBudget: Int = PatientContextRetriever.defaultCharacterBudget,
        labels: [Date: String] = [:]
    ) -> String {
        let search = SessionSearch.search(
            documents.map { SessionSearch.Document(date: $0.date, tag: labels[$0.date] ?? "", kind: .transcript, text: $0.text) },
            question: question
        )
        return select(transcripts: documents, search: search, characterBudget: characterBudget, labels: labels)
            .excerpts
            .map { "\(header($0.date, labels: labels))\n\($0.text)" }
            .joined(separator: "\n\n")
    }

    /// Which transcript text survives the budget, newest session first.
    /// `search` must have been run over (at least) `transcripts`; its date
    /// filter applies here too. `labels` is only used to measure header
    /// length against the budget, exactly as the rendered context does.
    static func select(
        transcripts: [TranscriptDocument],
        search: SessionSearch.Result,
        characterBudget: Int = PatientContextRetriever.defaultCharacterBudget,
        labels: [Date: String] = [:]
    ) -> Selection {
        let usable = transcripts.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (search.dateRange?.contains($0.date) ?? true)
        }
        guard !usable.isEmpty else { return Selection(excerpts: [], hitsShown: 0, whole: true) }
        let transcriptHits = search.hits.filter { $0.kind == .transcript }

        // No terms to rank on, or everything fits: all of it, newest first, so
        // nothing a search could have found is left out.
        let totalChars = usable.reduce(0) { $0 + $1.text.count }
        if search.terms.isEmpty || totalChars <= characterBudget {
            return Selection(excerpts: wholeExcerpts(usable, labels: labels), hitsShown: transcriptHits.count, whole: true)
        }
        // Terms but no transcript match: the most recent history that fits,
        // rather than nothing (the search block says there were no matches).
        guard !transcriptHits.isEmpty else {
            return Selection(excerpts: wholeExcerpts(usable, budget: characterBudget, labels: labels), hitsShown: 0, whole: true)
        }

        // Best hits first; each adds only the context lines not already kept
        // by an earlier hit in the same transcript.
        struct Slot: Hashable { let document: Int; let line: Int }
        var kept: [Slot: String] = [:]
        var dateOf: [Int: Date] = [:]
        var used = 0
        var shown = 0
        for hit in transcriptHits {
            let fresh = hit.context.enumerated().filter { kept[Slot(document: hit.documentIndex, line: hit.contextStart + $0.offset)] == nil }
            let cost = fresh.reduce(0) { $0 + $1.element.count + 1 }
            if shown > 0 && used + cost > characterBudget { continue }
            for (offset, line) in fresh { kept[Slot(document: hit.documentIndex, line: hit.contextStart + offset)] = line }
            dateOf[hit.documentIndex] = hit.date
            used += cost
            shown += 1
            if used >= characterBudget { break }
        }

        // Per transcript in line order, "…" between gaps; transcripts of one
        // date are joined under it.
        var byDate: [Date: [String]] = [:]
        for document in Set(kept.keys.map(\.document)) {
            let slots = kept.keys.filter { $0.document == document }.sorted { $0.line < $1.line }
            var text = ""
            var previous: Int?
            for slot in slots {
                if let previous { text += slot.line == previous + 1 ? "\n" : "\n…\n" }
                text += kept[slot]!
                previous = slot.line
            }
            byDate[dateOf[document]!, default: []].append(text)
        }
        let excerpts = byDate.keys.sorted(by: >).map { Excerpt(date: $0, text: byDate[$0]!.joined(separator: "\n…\n")) }
        return Selection(excerpts: excerpts, hitsShown: shown, whole: false)
    }

    // MARK: - Formatting

    private static let headerFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        return f
    }()

    /// A session header. When a citation `label` is supplied (e.g. "S1"), it's
    /// embedded so the model can cite that session inline as `[S1]`.
    static func header(_ date: Date, labels: [Date: String]) -> String {
        let dateString = headerFormatter.string(from: date)
        if let tag = labels[date] {
            return "===== Session [\(tag)] \(dateString) ====="
        }
        return "===== Session \(dateString) ====="
    }

    private static func wholeExcerpts(_ documents: [TranscriptDocument], budget: Int? = nil, labels: [Date: String] = [:]) -> [Excerpt] {
        let sorted = documents.sorted { $0.date > $1.date }
        var result: [Excerpt] = []
        var used = 0
        for doc in sorted {
            let blockLength = "\(header(doc.date, labels: labels))\n\(doc.text)".count
            if let budget, !result.isEmpty, used + blockLength > budget { break }
            result.append(Excerpt(date: doc.date, text: doc.text))
            used += blockLength
        }
        return result
    }
}
