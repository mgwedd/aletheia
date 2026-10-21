import Foundation

/// How the patient chat reads a history too long to send whole, from far out
/// to close up. Search (the FTS index) picks where to look; the model never
/// reads a transcript to find out whether it matters.
///
///   1,000 ft  the patient's background, the therapist's notes and comments,
///             and the stored session summaries (digests), newest first, older
///             ones merged by month, up to a share of this Mac's budget.
///     500 ft  search over every transcript, note and comment: exact counts,
///             and the parts of sessions the hits fall in ("areas"), ranked.
///     100 ft  the summaries of those parts, where the session has a digest,
///             plus the few transcript lines around the best hits.
///      10 ft  a transcript part read in full, only when the model asks for it
///             (`LocalToolLoop`, `read_section`) at Normal or Focus.
///
/// Nothing here calls a model. `Store.gatherCitedPatientContext` gathers the
/// sessions and the search result and assembles the text from these pieces.
enum PatientZoom {
    /// Most areas listed for one question.
    static let maxAreas = 12

    /// Room kept for the session header a block may need ("===== Session [S12]
    /// September 30, 2026 =====" and the blank line before it).
    static let headerAllowance = 60

    /// How the room left after the background, the notes and the search block
    /// is shared between the levels. What a level leaves unused goes to the
    /// transcript lines around the hits, which are assembled last.
    struct Shares: Equatable {
        let summaries: Int
        let areas: Int
        let sections: Int

        init(room: Int) {
            let room = max(0, room)
            summaries = room * 45 / 100
            areas = room * 10 / 100
            sections = room * 20 / 100
        }
    }

    /// How many of the newest sessions keep their own summary before older ones
    /// are merged by month: about one per 1,500 characters of the summaries'
    /// share, so a Mac with more memory reads more sessions' summaries whole
    /// (at Normal on an empty conversation, with notes using their full third:
    /// about 5 on 8 GB, 14 on 16 GB, 32 on 32 GB and up; more when there are fewer notes).
    static func individualSummaryLimit(summaryRoom: Int) -> Int {
        max(4, summaryRoom / 1_500)
    }

    // MARK: - Areas (500 ft)

    /// One session as the area ranking sees it.
    struct SessionInput {
        let tag: String
        let date: Date
        let sessionID: UUID
        /// The session's current digest, if it has one.
        let digest: SessionDigest?
        /// The transcript's parts (`TranscriptSections.split`), used for a
        /// session without a digest. Empty when the session has a digest.
        let parts: [TranscriptSection]
        /// Lines in the transcript, to place an untimed hit in its part.
        let lineCount: Int
    }

    /// One part of one session that the question points at.
    struct Area: Equatable {
        let tag: String
        let date: Date
        let sessionID: UUID
        /// Index of the part in its session, and how many parts it has.
        let index: Int
        let count: Int
        let start: Int?
        let end: Int?
        /// Transcript search hits in this part.
        let transcriptHits: Int
        /// The question's words found in this part's summary.
        let summaryMatches: Int
        /// The part's summary, when the session has a digest.
        let summary: String?

        /// A word spoken in the session counts for more than one in its AI summary.
        var score: Int { transcriptHits * 2 + summaryMatches }

        /// `[12:30–22:10]`, or `[part 2 of 5]` for an untimed transcript.
        var anchor: String {
            TranscriptSection(start: start, end: end, text: "").anchor(index: index, count: count)
        }

        /// The `read_section` times that open this part. An untimed transcript is
        /// read in parts of ten minutes' worth (`LocalToolScope`), so part k starts at k × 10:00.
        var readTimes: (start: String, end: String) {
            if let start, let end {
                return (TranscriptTimeline.format(start), TranscriptTimeline.format(end))
            }
            let from = index * TranscriptSections.targetSeconds
            return (TranscriptTimeline.format(from), TranscriptTimeline.format(from + TranscriptSections.targetSeconds - 1))
        }
    }

    /// The question's words as the index compares them (stemmed), stopwords left out.
    static func stems(of terms: [SessionSearch.Term]) -> Set<String> {
        var result = Set<String>()
        for term in terms {
            for word in term.words where !SessionSearch.stopwords.contains(word) {
                result.insert(SessionSearch.stem(word))
            }
        }
        return result
    }

    /// How many words of `text` are one of `stems`.
    static func matches(of stems: Set<String>, in text: String) -> Int {
        guard !stems.isEmpty else { return 0 }
        var count = 0
        for word in SessionSearch.tokenize(text) where stems.contains(SessionSearch.stem(word)) {
            count += 1
        }
        return count
    }

    /// The part a hit at `seconds` falls in: the last one starting at or before
    /// it (the first part for a hit before any start). Nil for untimed parts.
    static func partIndex(forSeconds seconds: Int, starts: [Int?]) -> Int? {
        var found: Int?
        for (index, start) in starts.enumerated() {
            guard let start else { return nil }
            if start <= seconds || found == nil { found = index }
            if start > seconds { break }
        }
        return found
    }

    /// The part an untimed hit on line `line` of `lineCount` falls in, by position.
    static func partIndex(forLine line: Int, lineCount: Int, parts: Int) -> Int {
        guard parts > 1, lineCount > 0 else { return 0 }
        return min(parts - 1, max(0, line * parts / lineCount))
    }

    /// Every part the question points at, best first: by transcript hits and by
    /// the question's words in the part's summary. Ties go to the newer session,
    /// then the earlier part.
    static func areas(sessions: [SessionInput], hits: [SessionSearch.Hit], stems: Set<String>) -> [Area] {
        var hitsByPart: [UUID: [Int: Int]] = [:]
        var inputByID: [UUID: SessionInput] = [:]
        for session in sessions { inputByID[session.sessionID] = session }
        for hit in hits where hit.kind == .transcript {
            guard let id = hit.sessionID, let session = inputByID[id] else { continue }
            let starts: [Int?] = session.digest.map { $0.sections.map(\.start) } ?? session.parts.map(\.start)
            guard !starts.isEmpty else { continue }
            var index: Int?
            if let seconds = hit.seconds {
                index = partIndex(forSeconds: seconds, starts: starts)
            }
            let part = index ?? partIndex(forLine: hit.lineIndex, lineCount: session.lineCount, parts: starts.count)
            hitsByPart[id, default: [:]][part, default: 0] += 1
        }

        var out: [Area] = []
        for session in sessions {
            let partHits = hitsByPart[session.sessionID] ?? [:]
            if let digest = session.digest {
                for (index, section) in digest.sections.enumerated() {
                    let area = Area(
                        tag: session.tag, date: session.date, sessionID: session.sessionID,
                        index: index, count: digest.sections.count, start: section.start, end: section.end,
                        transcriptHits: partHits[index] ?? 0,
                        summaryMatches: matches(of: stems, in: section.digest),
                        summary: section.digest
                    )
                    if area.score > 0 { out.append(area) }
                }
            } else {
                for (index, part) in session.parts.enumerated() {
                    guard let hitCount = partHits[index], hitCount > 0 else { continue }
                    out.append(Area(
                        tag: session.tag, date: session.date, sessionID: session.sessionID,
                        index: index, count: session.parts.count, start: part.start, end: part.end,
                        transcriptHits: hitCount, summaryMatches: 0, summary: nil
                    ))
                }
            }
        }
        out.sort { l, r in
            if l.score != r.score { return l.score > r.score }
            if l.date != r.date { return l.date > r.date }
            return l.index < r.index
        }
        return out
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateStyle = .medium
        return f
    }()

    /// One line of the areas list: where, why, and how to open it.
    static func areaLine(_ area: Area) -> String {
        var reasons: [String] = []
        if area.transcriptHits > 0 {
            reasons.append("\(area.transcriptHits) matching transcript line\(area.transcriptHits == 1 ? "" : "s")")
        }
        if area.summaryMatches > 0 {
            reasons.append("its summary has \(area.summaryMatches) of your words")
        }
        if area.summary == nil {
            reasons.append("no summary yet")
        }
        let times = area.readTimes
        return "- [\(area.tag)] \(dateFormatter.string(from: area.date)) \(area.anchor): "
            + reasons.joined(separator: ", ")
            + " (read_section session \(area.tag), start \(times.start), end \(times.end))"
    }

    static let areasHeader = "Where search points, best first (these transcript parts are not included in full):"

    /// The areas list, best first, as many lines as fit `budget`. Nil when none fit.
    static func areasBlock(_ areas: [Area], budget: Int) -> (text: String, shown: [Area])? {
        var lines: [String] = [areasHeader]
        var used = areasHeader.count + 1
        var shown: [Area] = []
        for area in areas.prefix(maxAreas) {
            let line = areaLine(area)
            guard used + line.count + 1 <= budget else { continue }
            lines.append(line)
            used += line.count + 1
            shown.append(area)
        }
        guard !shown.isEmpty else { return nil }
        return (lines.joined(separator: "\n"), shown)
    }

    /// The summary of one part, as it goes under its session's header.
    static func sectionSummaryBlock(_ area: Area) -> String {
        let why = area.transcriptHits > 0
            ? " (\(area.transcriptHits) matching transcript line\(area.transcriptHits == 1 ? "" : "s"))"
            : ""
        return "Summary of the part search points at \(area.anchor)\(why):\n" + (area.summary ?? "")
    }

    /// The part summaries (100 ft) to show, best first, while they fit `budget`;
    /// one that doesn't fit is skipped, not cut.
    static func sectionSummaries(_ areas: [Area], budget: Int) -> [Area] {
        var used = 0
        var out: [Area] = []
        for area in areas where area.summary != nil {
            let cost = sectionSummaryBlock(area).count + 2 + headerAllowance
            guard used + cost <= budget else { continue }
            out.append(area)
            used += cost
        }
        return out
    }
}

/// The phases of one question to the patient chat, for its progress bar:
/// gathering (search, summaries, notes: no model), then at Normal and Focus
/// up to `maxRefinementRounds` rounds of choosing what to open (one model call
/// each), then writing the answer (one model call).
struct PatientAskSteps: Equatable {
    let total: Int
    let rounds: Int

    init(effort: AnswerEffort, layered: Bool) {
        rounds = layered && effort.maxToolCalls > 0 ? effort.maxRefinementRounds : 0
        total = 1 + rounds + 1
    }

    var gathering: AIRunSteps { AIRunSteps(done: 0, total: total) }
    /// Choosing what to open, round `round` (0-based).
    func choosing(round: Int) -> AIRunSteps { AIRunSteps(done: 1 + min(round, max(0, rounds - 1)), total: total) }
    var writing: AIRunSteps { AIRunSteps(done: total - 1, total: total) }

    /// What the line beside the bar says while the sessions are searched.
    static func gatheringText(sessions n: Int) -> String {
        n > 0
            ? "Searching \(n) session\(n == 1 ? "" : "s") and gathering summaries and notes…"
            : "Searching and gathering summaries and notes…"
    }

    /// The finished steps listed once the model starts, from what was gathered.
    static func finishedLines(_ coverage: TranscriptCoverage) -> [String] {
        func sessions(_ n: Int) -> String { "\(n) session\(n == 1 ? "" : "s")" }
        var lines: [String] = []
        if coverage.wholeTranscripts {
            lines.append("Gathered the full transcripts of \(sessions(coverage.sessionsWithPassages))")
            return lines
        }
        var searched = "Searched \(sessions(coverage.transcriptSessions))"
        if coverage.searched {
            let total = coverage.mentions + coverage.similarMentions
            searched += " · \(total) match\(total == 1 ? "" : "es")"
        }
        lines.append(searched)
        if coverage.digestSessions > 0 { lines.append("Read summaries of \(sessions(coverage.digestSessions))") }
        if coverage.areas > 0 {
            lines.append("Found \(coverage.areas) part\(coverage.areas == 1 ? "" : "s") worth a closer look")
        }
        if coverage.summarySections > 0 {
            lines.append("Read the summaries of \(coverage.summarySections) of them")
        }
        if coverage.sessionsWithPassages > 0 && !coverage.fullTexts {
            lines.append("Took the matching lines from \(sessions(coverage.sessionsWithPassages))")
        }
        return lines
    }
}
