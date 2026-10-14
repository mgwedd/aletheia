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
/// sound-alike matching). When a patient's transcripts fit the budget, whole
/// transcripts go in newest first; with no search terms or no match, the newest
/// that fit; otherwise the best hits' context
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
        /// Every session's whole transcript was sent; nothing was dropped.
        let whole: Bool
        /// The excerpts are whole transcripts (all of them, or the newest that fit).
        let fullTexts: Bool
    }

    /// Transcript characters the patient-wide chat sends per question when a
    /// caller doesn't size it from the Mac's `ContextBudget`.
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
    /// filter applies here too. `labels` is used to measure header length
    /// against the budget, exactly as the rendered context does. The result
    /// never exceeds `characterBudget`; `whole` is false when anything was left out.
    static func select(
        transcripts: [TranscriptDocument],
        search: SessionSearch.Result,
        characterBudget: Int,
        labels: [Date: String] = [:]
    ) -> Selection {
        // Compacted for the model (`TranscriptCompactor`), so the budget below
        // measures what is actually sent.
        let usable = transcripts.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (search.dateRange?.contains($0.date) ?? true)
        }.map { TranscriptDocument(date: $0.date, text: TranscriptCompactor.compact($0.text)) }
        guard !usable.isEmpty else { return Selection(excerpts: [], hitsShown: 0, whole: true, fullTexts: true) }
        let transcriptHits = search.hits.filter { $0.kind == .transcript }

        // Everything fits: all of it, newest first, so nothing a search could
        // have found is left out.
        let totalChars = usable.reduce(0) { $0 + blockLength($1, labels: labels) }
        if totalChars <= characterBudget {
            return Selection(excerpts: wholeExcerpts(usable, budget: characterBudget, labels: labels), hitsShown: transcriptHits.count, whole: true, fullTexts: true)
        }
        // No terms to rank on, or terms with no transcript match: the newest
        // sessions that fit, rather than nothing. `whole` is false: older
        // sessions were left out, and the label says how many.
        guard !search.terms.isEmpty, !transcriptHits.isEmpty else {
            return Selection(excerpts: wholeExcerpts(usable, budget: characterBudget, labels: labels), hitsShown: 0, whole: false, fullTexts: true)
        }

        // Best hits first; each adds only the context lines not already kept
        // by an earlier hit in the same transcript.
        struct Slot: Hashable { let document: Int; let line: Int }
        var kept: [Slot: String] = [:]
        var dateOf: [Int: Date] = [:]
        var headed = Set<Date>()
        var used = 0
        var shown = 0
        for hit in transcriptHits {
            // Lines are compacted before they are counted, so the room saved admits more hits.
            var fresh = hit.context.enumerated().filter { kept[Slot(document: hit.documentIndex, line: hit.contextStart + $0.offset)] == nil }
                .map { (offset: $0.offset, element: TranscriptCompactor.compact($0.element)) }
            let headerCost = headed.contains(hit.date) ? 0 : header(hit.date, labels: labels).count + 3
            var cost = fresh.reduce(0) { $0 + $1.element.count + 1 } + headerCost
            if used + cost > characterBudget {
                // A later hit that doesn't fit is skipped; the best hit is cut
                // down around its matching line rather than dropped.
                guard shown == 0 else { continue }
                fresh = trimmed(fresh, around: hit.lineIndex - hit.contextStart, room: characterBudget - headerCost)
                cost = fresh.reduce(0) { $0 + $1.element.count + 1 } + headerCost
                guard !fresh.isEmpty else { break }
            }
            for (offset, line) in fresh { kept[Slot(document: hit.documentIndex, line: hit.contextStart + offset)] = line }
            dateOf[hit.documentIndex] = hit.date
            headed.insert(hit.date)
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
        let excerpts = byDate.keys.sorted(by: >).map { Excerpt(date: $0, text: TranscriptCompactor.compact(byDate[$0]!.joined(separator: "\n…\n"))) }
        return Selection(excerpts: excerpts, hitsShown: shown, whole: false, fullTexts: false)
    }

    /// The lines nearest `center` (a position in `lines`) that fit `room`
    /// characters, in order; the centre line itself is cut with "…" if it alone is too long.
    private static func trimmed(_ lines: [(offset: Int, element: String)], around center: Int, room: Int) -> [(offset: Int, element: String)] {
        var chosen: [(offset: Int, element: String)] = []
        var left = room
        for line in lines.sorted(by: { abs($0.offset - center) < abs($1.offset - center) }) {
            let cost = line.element.count + 1
            if cost <= left {
                chosen.append(line)
                left -= cost
            } else if chosen.isEmpty, left > 1 {
                chosen.append((line.offset, String(line.element.prefix(left - 2)) + "…"))
                left = 0
            }
        }
        return chosen.sorted { $0.offset < $1.offset }
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

    private static func blockLength(_ doc: TranscriptDocument, labels: [Date: String]) -> Int {
        header(doc.date, labels: labels).count + 1 + doc.text.count + 2
    }

    /// Whole transcripts, newest first, stopping at the first one that does not
    /// fit `budget` (never cut, never skipped over), so what is kept is always
    /// exactly "the newest K sessions".
    private static func wholeExcerpts(_ documents: [TranscriptDocument], budget: Int, labels: [Date: String]) -> [Excerpt] {
        var result: [Excerpt] = []
        var used = 0
        for doc in documents.sorted(by: { $0.date > $1.date }) {
            let length = blockLength(doc, labels: labels)
            guard used + length <= budget else { break }
            result.append(Excerpt(date: doc.date, text: doc.text))
            used += length
        }
        return result
    }
}
