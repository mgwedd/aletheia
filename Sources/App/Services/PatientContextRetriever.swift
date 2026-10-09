import Foundation

struct TranscriptDocument {
    let date: Date
    let text: String
}

/// Selects the transcript passages most relevant to a question so the
/// cross-session chat can answer from a large history without stuffing every
/// word into the prompt.
///
/// This is the retrieval behind `Store.gatherPatientContext`'s designed
/// "swap point": when a patient's transcripts fit comfortably in the budget
/// it returns them whole (the original naive behavior, unchanged); past
/// that, it ranks passages by TF-IDF term overlap with the question and
/// keeps the top ones — regrouped by session date, newest first, with the
/// same `===== Session <date> =====` headers so the model can still cite
/// when something was said.
enum PatientContextRetriever {
    private struct ScoredChunk {
        let date: Date
        /// Position within its source transcript, so a session's kept
        /// passages stay in spoken order when regrouped.
        let order: Int
        let text: String
        let score: Double
    }

    /// The transcript text kept for one session date, before any header is put
    /// on it. Exposed so a caller that adds its own per-session material (see
    /// `Store.gatherCitedPatientContext`) can tell which sessions the ranker
    /// kept and put everything under one header.
    struct Excerpt {
        let date: Date
        let text: String
    }

    /// Transcript characters the patient-wide chat sends per question. Also the
    /// figure quoted in the chat sheet and docs/DESIGN-DECISIONS.md.
    static let defaultCharacterBudget = 6000

    static func context(
        for documents: [TranscriptDocument],
        question: String,
        characterBudget: Int = PatientContextRetriever.defaultCharacterBudget,
        labels: [Date: String] = [:]
    ) -> String {
        let kept = excerpts(for: documents, question: question, characterBudget: characterBudget, labels: labels)
        return kept
            .map { "\(header($0.date, labels: labels))\n\($0.text)" }
            .joined(separator: "\n\n")
    }

    /// The selection step behind `context`: which transcript text survives the
    /// budget, newest session first. `labels` is only used to measure header
    /// length against the budget, exactly as the rendered context does.
    static func excerpts(
        for documents: [TranscriptDocument],
        question: String,
        characterBudget: Int = PatientContextRetriever.defaultCharacterBudget,
        labels: [Date: String] = [:]
    ) -> [Excerpt] {
        let usable = documents.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else { return [] }

        let totalChars = usable.reduce(0) { $0 + $1.text.count }
        let terms = TextSearch.queryTerms(question)

        // Small enough, or no usable query terms to rank on: return the whole
        // history, newest first — identical to the naive path.
        if terms.isEmpty || totalChars <= characterBudget {
            return wholeExcerpts(usable, labels: labels)
        }

        var chunks: [(date: Date, order: Int, text: String)] = []
        for doc in usable {
            for (index, passage) in passages(of: doc.text).enumerated() {
                chunks.append((doc.date, index, passage))
            }
        }

        let idf = idf(chunkTexts: chunks.map(\.text), terms: terms)
        let scored = chunks.compactMap { chunk -> ScoredChunk? in
            let s = score(text: chunk.text, terms: terms, idf: idf)
            guard s > 0 else { return nil }
            return ScoredChunk(date: chunk.date, order: chunk.order, text: chunk.text, score: s)
        }

        // No passage mentions the question: hand back the most recent history
        // that fits, rather than nothing.
        guard !scored.isEmpty else { return wholeExcerpts(usable, budget: characterBudget, labels: labels) }

        var selected: [ScoredChunk] = []
        var used = 0
        for chunk in scored.sorted(by: { $0.score > $1.score }) {
            if !selected.isEmpty && used + chunk.text.count > characterBudget { continue }
            selected.append(chunk)
            used += chunk.text.count
            if used >= characterBudget { break }
        }
        return selectedExcerpts(selected)
    }

    // MARK: - Chunking

    /// Splits a transcript into passages of roughly `targetChars`, breaking
    /// only on line boundaries so a `[MM:SS] Speaker: …` line stays intact.
    private static func passages(of text: String, targetChars: Int = 600) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [String] = []
        var current = ""
        for line in lines {
            if current.isEmpty {
                current = line
            } else if current.count + 1 + line.count > targetChars {
                result.append(current)
                current = line
            } else {
                current += "\n" + line
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.isEmpty ? [text] : result
    }

    // MARK: - Scoring

    private static func idf(chunkTexts: [String], terms: [String]) -> [String: Double] {
        let n = Double(chunkTexts.count)
        var result: [String: Double] = [:]
        for term in Set(terms) {
            let df = chunkTexts.reduce(0) { $0 + ($1.range(of: term, options: TextSearch.compareOptions) != nil ? 1 : 0) }
            // Smoothed so it's always positive even when a term is in every chunk.
            result[term] = log(1.0 + n / Double(1 + df))
        }
        return result
    }

    private static func score(text: String, terms: [String], idf: [String: Double]) -> Double {
        var total = 0.0
        for term in terms {
            let count = occurrences(of: term, in: text)
            if count > 0 { total += Double(count) * (idf[term] ?? 0) }
        }
        return total
    }

    private static func occurrences(of term: String, in text: String) -> Int {
        var count = 0
        var range = text.startIndex..<text.endIndex
        while let found = text.range(of: term, options: TextSearch.compareOptions, range: range) {
            count += 1
            range = found.upperBound..<text.endIndex
        }
        return count
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

    private static func selectedExcerpts(_ chunks: [ScoredChunk]) -> [Excerpt] {
        let byDate = Dictionary(grouping: chunks, by: { $0.date })
        return byDate.keys.sorted(by: >).map { date in
            let passages = byDate[date]!
                .sorted { $0.order < $1.order }
                .map(\.text)
            return Excerpt(date: date, text: passages.joined(separator: "\n…\n"))
        }
    }
}
