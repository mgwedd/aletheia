import Foundation

// Global search over every patient: names, session dates, notes, comments and
// transcripts, answered from the search index (`SearchIndex`), with snippets
// cut from the original text of just the places shown.
//
//   query ─▶ GlobalSearchQuery (words, which must match, FTS clauses)
//     ├─▶ catalog (patients, sessions)  ─▶ Patients, Sessions   (names, dates)
//     └─▶ SearchIndex.matchLive (one MATCH per word, live documents only)
//           ─▶ GlobalSearchRanking.rank (every word in the place, bm25)
//           ─▶ read the original text of the places shown ─▶ snippets
//   + coverage: what the index is known to be missing (`SearchIndexProgress`)

// MARK: - Results

/// How many results each group shows. A group starts at `initial` and grows
/// by `step` each time "Show more" is chosen, up to `maximum`; past that the
/// count says how many more there are and the query has to be narrowed.
struct GlobalSearchLimits: Equatable {
    static let initial = 5
    static let step = 25
    static let maximum = 200

    var perKind: [SearchKind: Int] = [:]
    var defaultLimit = GlobalSearchLimits.initial

    func limit(for kind: SearchKind) -> Int {
        min(perKind[kind] ?? defaultLimit, GlobalSearchLimits.maximum)
    }

    /// Shows `step` more of `kind`. Returns false when it already shows the maximum.
    @discardableResult
    mutating func showMore(of kind: SearchKind) -> Bool {
        let current = limit(for: kind)
        guard current < GlobalSearchLimits.maximum else { return false }
        perKind[kind] = min(current + GlobalSearchLimits.step, GlobalSearchLimits.maximum)
        return true
    }
}

/// One group of results: every match of one kind, best first; `hits` holds
/// the first `GlobalSearchLimits.limit(for:)` of `total`.
struct GlobalSearchSection: Equatable, Identifiable {
    let kind: SearchKind
    let hits: [SearchHit]
    let total: Int

    var id: SearchKind { kind }
    /// Matches counted but not shown.
    var hiddenCount: Int { max(0, total - hits.count) }
}

/// Whether the results cover everything, or the index is known to be missing something.
enum GlobalSearchCoverage: Equatable {
    /// The index holds every session as it is now.
    case complete
    /// Not yet compared with the data folder (just launched or unlocked, or the index started over).
    case checking
    /// These many sessions are still being indexed.
    case indexing(sessions: Int)
    /// The index couldn't be read, so every file was searched instead (complete, but slow).
    case scanned

    init(_ snapshot: SearchIndexProgress.Snapshot) {
        if !snapshot.checked {
            self = .checking
        } else if snapshot.pendingSessions > 0 {
            self = .indexing(sessions: snapshot.pendingSessions)
        } else {
            self = .complete
        }
    }

    var isComplete: Bool { self == .complete || self == .scanned }

    /// The line shown above the results while they may be incomplete.
    var statusText: String? {
        switch self {
        case .complete, .scanned:
            return nil
        case .checking:
            return "Checking the search index; results may be incomplete."
        case .indexing(let sessions):
            let noun = sessions == 1 ? "session" : "sessions"
            return "Indexing \(sessions) \(noun); results may be incomplete."
        }
    }
}

struct GlobalSearchResults: Equatable {
    /// Non-empty groups, in `SearchKind` order.
    var sections: [GlobalSearchSection]
    var coverage: GlobalSearchCoverage

    static let empty = GlobalSearchResults(sections: [], coverage: .complete)

    /// Every shown hit, group by group.
    var hits: [SearchHit] { sections.flatMap { $0.hits } }
    /// Every match, shown or not.
    var total: Int { sections.reduce(0) { $0 + $1.total } }

    func section(_ kind: SearchKind) -> GlobalSearchSection? {
        sections.first { $0.kind == kind }
    }
}

// MARK: - Inputs

/// Every patient (alphabetically) and their sessions (newest first), listed
/// once per query: what results may point at. A session that is no longer
/// listed never shows up, even if the index still holds its text.
struct GlobalSearchCatalog {
    struct Entry {
        let patient: Patient
        let sessions: [SessionRecord]
    }

    struct Place {
        let patient: Patient
        let session: SessionRecord
    }

    let entries: [Entry]
    private let places: [String: Place]

    init(entries: [Entry]) {
        self.entries = entries
        var places: [String: Place] = [:]
        for entry in entries {
            for session in entry.sessions {
                places[session.id.uuidString] = Place(patient: entry.patient, session: session)
            }
        }
        self.places = places
    }

    func place(session: String) -> Place? { places[session] }
}

/// A generated progress note as global search shows it.
struct GlobalSearchNote: Equatable {
    /// The format to open; `.narrative` for a note from before per-format notes.
    let format: ProgressNoteFormat?
    let label: String
    let text: String
    /// Distinguishes notes of one session in result ids.
    let key: String
}

/// Reads the original text of a place, only for places a query matched.
/// Closures so tests can count what a query reads.
struct GlobalSearchReader {
    var transcript: (Patient, SessionRecord) -> String?
    var notes: (Patient, SessionRecord) -> [GlobalSearchNote]
    var sessionNotes: (UUID) -> String
    var comments: (UUID) -> [SessionComment]
}

// MARK: - Ranking

/// Turns per-word passage matches into ranked places. Pure.
enum GlobalSearchRanking {
    struct Ranked: Equatable {
        let doc: Int64
        /// The passage to show: the one matching the most words, then the best scored, then the first.
        let line: Int
        /// The sum, over the words, of the word's best passage score (bm25, higher is better).
        let score: Double
        /// How many passages matched any word.
        let passages: Int
    }

    /// `passages[i]` holds the passages matching word `i`. A document is kept
    /// when every word is in one of its passages or answered elsewhere
    /// (`answered`: the patient's name or session date; nil drops the document,
    /// e.g. its session is gone), and at least one is in its text.
    /// Order: score, then more matching passages, then newer, then session id
    /// and document id, so equal input always gives equal output.
    static func rank(
        passages: [[SearchIndex.MatchedPassage]],
        documents: [Int64: SearchIndex.LiveDocument],
        answered: (SearchIndex.LiveDocument) -> UInt32?
    ) -> [Ranked] {
        let termCount = passages.count
        guard termCount > 0, termCount < 32 else { return [] }
        let full = GlobalSearchQuery.mask(count: termCount)
        var docMask: [Int64: UInt32] = [:]
        var docScore: [Int64: Double] = [:]
        var rowMask: [Int64: UInt32] = [:]
        var rowScore: [Int64: Double] = [:]
        for term in 0..<termCount {
            let bit = UInt32(1) << UInt32(term)
            var best: [Int64: Double] = [:]
            for match in passages[term] {
                docMask[match.doc, default: 0] |= bit
                let row = SearchIndex.rowid(doc: match.doc, line: match.line)
                rowMask[row, default: 0] |= bit
                rowScore[row, default: 0] += match.score
                if let current = best[match.doc] {
                    if match.score > current { best[match.doc] = match.score }
                } else {
                    best[match.doc] = match.score
                }
            }
            for (doc, score) in best { docScore[doc, default: 0] += score }
        }

        var picks: [Int64: Pick] = [:]
        for (row, mask) in rowMask {
            let (doc, line) = SearchIndex.split(rowid: row)
            let words = mask.nonzeroBitCount
            let score = rowScore[row] ?? 0
            guard var pick = picks[doc] else {
                picks[doc] = Pick(line: line, words: words, score: score, count: 1)
                continue
            }
            pick.count += 1
            if isBetter(words: words, score: score, line: line, than: pick) {
                pick.line = line
                pick.words = words
                pick.score = score
            }
            picks[doc] = pick
        }

        var ranked: [Ranked] = []
        for (doc, mask) in docMask {
            guard let document = documents[doc], let elsewhere = answered(document), let pick = picks[doc] else { continue }
            guard (mask | elsewhere) & full == full else { continue }
            ranked.append(Ranked(doc: doc, line: pick.line, score: docScore[doc] ?? 0, passages: pick.count))
        }
        ranked.sort { a, b in precedes(a, b, documents) }
        return ranked
    }

    /// The passage picked so far for one document, and how many matched.
    private struct Pick {
        var line: Int
        var words: Int
        var score: Double
        var count: Int
    }

    private static func isBetter(words: Int, score: Double, line: Int, than pick: Pick) -> Bool {
        if words != pick.words { return words > pick.words }
        if score != pick.score { return score > pick.score }
        return line < pick.line
    }

    static func precedes(_ a: Ranked, _ b: Ranked, _ documents: [Int64: SearchIndex.LiveDocument]) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.passages != b.passages { return a.passages > b.passages }
        let dateA = documents[a.doc]?.date ?? 0
        let dateB = documents[b.doc]?.date ?? 0
        if dateA != dateB { return dateA > dateB }
        let sessionA = documents[a.doc]?.session ?? ""
        let sessionB = documents[b.doc]?.session ?? ""
        if sessionA != sessionB { return sessionA < sessionB }
        return a.doc < b.doc
    }
}
