import Foundation

/// The layered plan for a patient-wide question over a history too long to send
/// whole. The default material is the patient's own: background, the
/// therapist's notes and comments, and session summaries (digests), up to the
/// question's budget. Transcript text is reached only by drilling down from
/// where search points, never to fill spare room.
///
///   Level 1  summaries of the sessions, newest first, older ones merged by
///            month; past the cap the oldest go to search only     search, no model call
///   Level 2  the summary sections the question points at          search, no model call
///   Level 3  the transcript section under the best of those,
///            only where a transcript search hit falls in it       search, no model call
///   Level 4  exact lines: passages around each transcript hit,
///            then lookups the model asks for (read_section, …)    one model call per lookup round
///
/// Then one call writes the answer. Pure: `Store.gatherCitedPatientContext`
/// hands it what search found and what each digest holds.
enum HistoryRetrieval {
    /// Most transcript sections opened in full for one question.
    static let maxOpenedSections = 3

    /// How the room left for session material (after background, notes and the
    /// search block) is split between the levels. Search passages (level 4)
    /// get what the first three leave; they are only ever lines around a hit.
    struct Shares: Equatable {
        let summaries: Int
        let sections: Int
        let opened: Int

        init(room: Int) {
            let room = max(0, room)
            summaries = room * 45 / 100
            sections = room * 15 / 100
            opened = room * 20 / 100
        }
    }

    /// One session that has a current digest.
    struct Session: Equatable {
        let date: Date
        let sections: [SessionDigest.Section]
        /// Time (seconds) of each transcript search hit in this session; nil for a hit with no time.
        let hitSeconds: [Int?]
    }

    /// One digest section, with how strongly the question points at it.
    struct Candidate: Equatable {
        /// Index into the `sessions` given to `rank` (newest first, so lower is newer).
        let session: Int
        let section: Int
        /// Transcript search hits whose time falls in this section.
        let transcriptHits: Int
        /// Question words found in the section's summary.
        let summaryMatches: Int

        /// A hit in the words spoken counts for more than a word in the summary.
        var score: Int { transcriptHits * 2 + summaryMatches }
    }

    /// The section a hit at `seconds` falls in: the last one that starts at or
    /// before it. Nil for an untimed digest or a time before the first section.
    static func sectionIndex(forSeconds seconds: Int, in sections: [SessionDigest.Section]) -> Int? {
        var found: Int?
        for (index, section) in sections.enumerated() {
            guard let start = section.start else { return nil }
            if start <= seconds { found = index }
        }
        return found
    }

    /// The question's words as the index compares them (stemmed), stopwords left out.
    static func stems(of terms: [SessionSearch.Term]) -> Set<String> {
        Set(terms.flatMap(\.words)
            .filter { !SessionSearch.stopwords.contains($0) }
            .map { SessionSearch.stem($0) })
    }

    /// How many words of `text` are one of `stems`.
    static func matches(of stems: Set<String>, in text: String) -> Int {
        guard !stems.isEmpty else { return 0 }
        return SessionSearch.tokenize(text).filter { stems.contains(SessionSearch.stem($0)) }.count
    }

    /// Every digest section the question points at, best first; ties go to the
    /// newer session, then the earlier section.
    static func rank(_ sessions: [Session], stems: Set<String>) -> [Candidate] {
        var out: [Candidate] = []
        for (s, session) in sessions.enumerated() {
            var hits = Array(repeating: 0, count: session.sections.count)
            for seconds in session.hitSeconds {
                if let seconds, let index = sectionIndex(forSeconds: seconds, in: session.sections) { hits[index] += 1 }
            }
            for (i, section) in session.sections.enumerated() {
                let candidate = Candidate(
                    session: s, section: i, transcriptHits: hits[i], summaryMatches: matches(of: stems, in: section.digest))
                if candidate.score > 0 { out.append(candidate) }
            }
        }
        return out.sorted { l, r in
            if l.score != r.score { return l.score > r.score }
            if l.session != r.session { return l.session < r.session }
            return l.section < r.section
        }
    }

    /// Summary sections shown as text (level 2), best first, while their
    /// `cost` fits `budget`. One that doesn't fit is skipped, not cut.
    static func sectionsToShow(_ ranked: [Candidate], budget: Int, cost: (Candidate) -> Int) -> [Candidate] {
        var used = 0
        var out: [Candidate] = []
        for candidate in ranked {
            let c = cost(candidate)
            guard used + c <= budget else { continue }
            out.append(candidate)
            used += c
        }
        return out
    }

    /// Transcript sections opened in full (level 3): only where a transcript
    /// hit falls, best first, at most `limit`, while their `size` fits
    /// `budget`. `size` is nil for a section that can't be opened.
    static func sectionsToOpen(
        _ ranked: [Candidate], budget: Int, limit: Int = maxOpenedSections, size: (Candidate) -> Int?
    ) -> [Candidate] {
        var used = 0
        var out: [Candidate] = []
        for candidate in ranked where candidate.transcriptHits > 0 {
            guard out.count < limit else { break }
            guard let s = size(candidate), used + s <= budget else { continue }
            out.append(candidate)
            used += s
        }
        return out
    }

    /// How a section is pointed at: `[12:30–22:10]`, or `[part 2 of 5]` untimed.
    static func anchor(_ section: SessionDigest.Section, index: Int, count: Int) -> String {
        TranscriptSection(start: section.start, end: section.end, text: "").anchor(index: index, count: count)
    }

    /// Dates of `dates` as "Mar 3, 2025 – Oct 8, 2026" (one date alone when they
    /// are all the same day), or nil for none.
    static func span(_ dates: [Date], formatter: DateFormatter) -> String? {
        guard let first = dates.min(), let last = dates.max() else { return nil }
        let a = formatter.string(from: first), b = formatter.string(from: last)
        return a == b ? a : "\(a) – \(b)"
    }
}

/// The steps of a patient-wide answer, for the progress bar: what was done
/// before the model started (search, summaries, transcript sections, passages),
/// then the lookups (Normal and Focus), then writing the answer.
struct HistoryAnswerSteps: Equatable {
    /// Lines for the steps already finished when the answer starts.
    let finished: [String]
    let looksUp: Bool

    init(coverage: TranscriptCoverage, looksUp: Bool) {
        func sessions(_ n: Int) -> String { "\(n) session\(n == 1 ? "" : "s")" }
        var lines = ["Searched \(sessions(coverage.transcriptSessions))"]
        if coverage.digestSessions > 0 { lines.append("Read summaries of \(sessions(coverage.digestSessions))") }
        if coverage.openedSections > 0 {
            lines.append("Opened \(coverage.openedSections) transcript section\(coverage.openedSections == 1 ? "" : "s")")
        }
        if coverage.sessionsWithPassages > 0 && !coverage.wholeTranscripts {
            lines.append("Found passages in \(sessions(coverage.sessionsWithPassages))")
        }
        finished = lines
        self.looksUp = looksUp
    }

    /// Every step: the finished ones, the lookups, and writing the answer.
    var total: Int { finished.count + (looksUp ? 1 : 0) + 1 }

    /// Where the bar stands once the model starts, and after the lookups.
    var atStart: AIRunSteps { AIRunSteps(done: finished.count, total: total) }
    var afterLookups: AIRunSteps { AIRunSteps(done: finished.count + (looksUp ? 1 : 0), total: total) }
}
