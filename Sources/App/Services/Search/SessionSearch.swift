import Foundation

/// In-memory search over one patient's material (#286): BM25 over passages,
/// with whole-word matching, one-letter typo tolerance and a sound-alike match
/// for names (whisper misspells them). Pure and deterministic; nothing is
/// written to disk and the model never sees anything the code didn't count.
///
/// A passage is one transcript line, or one paragraph of notes. The counts in
/// `Result` are exact over every document passed in (after the date filter),
/// whatever part of them ends up in a prompt.
enum SessionSearch {
    enum Kind: Equatable { case transcript, note, sessionNotes, comment }

    /// One piece of a session's material. `tag` is the citation tag ("S1").
    struct Document {
        let date: Date
        let tag: String
        let kind: Kind
        let text: String
    }

    /// A search term: one or more words. Quoted phrases keep all their words
    /// and match consecutive words only; names also match sound-alikes.
    struct Term: Equatable {
        let words: [String]
        let isName: Bool
        /// Typed in quotes: matches exactly, with no typo or sound-alike matching.
        var quoted = false
        var text: String { words.joined(separator: " ") }
    }

    struct DateRange: Equatable {
        let start: Date
        let end: Date
        func contains(_ date: Date) -> Bool { date >= start && date <= end }
    }

    struct Hit {
        let documentIndex: Int
        let date: Date
        let tag: String
        let kind: Kind
        /// Time stamp of the matching transcript line (or the nearest one above
        /// it), in seconds. Nil for notes and untimed transcripts.
        let seconds: Int?
        /// Position of the passage within its document (line number for a transcript).
        let lineIndex: Int
        let line: String
        /// The matching line plus up to two lines either side (transcripts only).
        let context: [String]
        /// Line number of `context[0]` within the document.
        let contextStart: Int
        let score: Double
    }

    struct TermCount: Equatable {
        let term: Term
        /// Occurrences of the word itself (or the phrase).
        let exact: Int
        /// Occurrences of a one-letter typo or sound-alike of it.
        let similar: Int
    }

    struct Result {
        let terms: [Term]
        let dateRange: DateRange?
        /// Passages with at least one match, best first.
        let hits: [Hit]
        /// Every matching word occurrence (a quoted phrase counts once),
        /// exact and similar spellings together.
        let totalMentions: Int
        /// Of `totalMentions`, those that matched a typo or sound-alike, not the word itself.
        let similarMentions: Int
        /// One entry per term, in order, so a claim about one word rests on its own count.
        let termCounts: [TermCount]
        let sessionsWithHits: Int
        /// Sessions (by tag) with any document inside the date range.
        let sessionsSearched: Int
        /// Other spellings each term matched (by the term's text), e.g. "micheal" for "michael".
        let matchedVariants: [String: [String]]
    }

    // MARK: - Terms

    /// Search terms in a question: quoted phrases whole, capitalized words as
    /// names, and every other word that isn't a stopword or part of a date
    /// expression ("past 6 months"). Words match whole, never as substrings.
    static func terms(from question: String) -> [Term] {
        var rest = DateFilter.parse(question, now: Date()).remainder
        var result: [Term] = []
        func add(_ term: Term) {
            if !term.words.isEmpty, !result.contains(term) { result.append(term) }
        }

        // Quoted phrases first, then remove them from what's left.
        let quoted = try? NSRegularExpression(pattern: "[\"“”]([^\"“”]+)[\"“”]")
        let whole = NSRange(rest.startIndex..., in: rest)
        for match in quoted?.matches(in: rest, range: whole) ?? [] {
            if let r = Range(match.range(at: 1), in: rest) {
                add(Term(words: tokenize(String(rest[r])), isName: false, quoted: true))
            }
        }
        rest = quoted?.stringByReplacingMatches(in: rest, range: whole, withTemplate: " ") ?? rest

        for raw in rest.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }) {
            guard let word = tokenize(String(raw)).first, word.count > 1, !stopwords.contains(word) else { continue }
            add(Term(words: [word], isName: raw.first?.isUppercase == true))
        }
        return result
    }

    static let stopwords: Set<String> = Set("""
        a about above after again all also am an and any are as at be because been before being between both but by \
        can could did do does doing done down during each few for from further get got had has have having he her here \
        hers herself don't didn't doesn't isn't wasn't aren't weren't haven't hasn't hadn't won't wouldn't can't couldn't shouldn't mustn't \
        i'm i've i'll i'd you're you've you'll you'd we're we've we'll we'd they're they've they'll they'd he'll he'd she'll she'd \
        it'll that'll who're what're him himself his how i if in into is it its itself just let like me might more most my myself no nor \
        not now of off on once only or other our ours ourselves out over own really same she should so some such than \
        that the their theirs them themselves then there these they this those through to too under until up very was \
        we were what when where which while who whom why will with would you your yours yourself yourselves \
        say said says tell told talk talked talking mention mentioned mentions discuss discussed discussing show find \
        give list summarize summarise describe happen happened session sessions patient patients client clients \
        therapist anything something everything anyone someone thing things time times past last since ago week weeks \
        month months year years day days ever always never again yes yeah okay ok please
        """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    // MARK: - Date filter

    /// The date range a question asks for, relative to `now`, or nil if it
    /// doesn't name one. Forms: "past/last N days|weeks|months|years",
    /// "since <Month> [year]", "in <Month> [year]", "this year", "last year".
    static func dateRange(in question: String, now: Date, calendar: Calendar = .current) -> DateRange? {
        DateFilter.parse(question, now: now, calendar: calendar).range
    }

    private enum DateFilter {
        private static let months = [
            "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6, "july": 7, "august": 8,
            "september": 9, "october": 10, "november": 11, "december": 12,
            "jan": 1, "feb": 2, "apr": 4, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12,
        ]
        private static let numberWords = [
            "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
            "ten": 10, "eleven": 11, "twelve": 12, "a": 1, "an": 1,
        ]
        private static let monthPattern = months.keys.sorted { $0.count > $1.count }.joined(separator: "|")

        static func parse(_ question: String, now: Date, calendar: Calendar = .current) -> (range: DateRange?, remainder: String) {
            let lower = question.lowercased()

            if let m = match(#"\b(?:past|last)\s+(\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|a|an)?\s*(day|week|month|year)s?\b"#, in: lower) {
                // "last year" with no number is the previous calendar year, handled below.
                if !(m.groups[0] == nil && m.groups[1] == "year" && m.text.hasPrefix("last")) {
                    let n = m.groups[0].flatMap { Int($0) ?? numberWords[$0] } ?? 1
                    let unit: Calendar.Component = ["day": .day, "week": .weekOfYear, "month": .month, "year": .year][m.groups[1]!]!
                    guard let start = calendar.date(byAdding: unit, value: -n, to: now) else { return (nil, question) }
                    return (DateRange(start: calendar.startOfDay(for: start), end: now), remove(m.range, from: question))
                }
            }
            if let m = match(#"\b(this|last)\s+year\b"#, in: lower) {
                let year = calendar.component(.year, from: now) - (m.groups[0] == "last" ? 1 : 0)
                return (yearRange(year, calendar), remove(m.range, from: question))
            }
            if let m = match(#"\bsince\s+(\#(monthPattern))\b(?:\s+(\d{4}))?"#, in: lower) {
                guard let start = monthStart(m.groups[0]!, year: m.groups[1], now: now, calendar: calendar) else { return (nil, question) }
                return (DateRange(start: start, end: now), remove(m.range, from: question))
            }
            if let m = match(#"\bin\s+(\#(monthPattern))\b(?:\s+(\d{4}))?"#, in: lower) {
                guard let start = monthStart(m.groups[0]!, year: m.groups[1], now: now, calendar: calendar),
                      let next = calendar.date(byAdding: .month, value: 1, to: start) else { return (nil, question) }
                return (DateRange(start: start, end: next.addingTimeInterval(-1)), remove(m.range, from: question))
            }
            return (nil, question)
        }

        private static func yearRange(_ year: Int, _ calendar: Calendar) -> DateRange? {
            guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let next = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else { return nil }
            return DateRange(start: start, end: next.addingTimeInterval(-1))
        }

        /// First day of the month. Without a year, the most recent such month
        /// that isn't in the future.
        private static func monthStart(_ name: String, year: String?, now: Date, calendar: Calendar) -> Date? {
            guard let month = months[name] else { return nil }
            let currentYear = calendar.component(.year, from: now)
            if let year, let y = Int(year) { return calendar.date(from: DateComponents(year: y, month: month, day: 1)) }
            guard let thisYears = calendar.date(from: DateComponents(year: currentYear, month: month, day: 1)) else { return nil }
            return thisYears <= now ? thisYears : calendar.date(from: DateComponents(year: currentYear - 1, month: month, day: 1))
        }

        private struct Match {
            let range: Range<String.Index>
            let text: String
            let groups: [String?]
        }

        private static func match(_ pattern: String, in text: String) -> Match? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let whole = Range(m.range, in: text) else { return nil }
            let groups = (1..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } }
            return Match(range: whole, text: String(text[whole]), groups: groups)
        }

        /// `lower` has the same length as the question for ASCII; for anything
        /// else fall back to removing nothing rather than cutting wrongly.
        private static func remove(_ range: Range<String.Index>, from question: String) -> String {
            guard let lowerCount = Optional(question.lowercased().count), lowerCount == question.count else { return question }
            let lower = question.lowercased()
            let start = lower.distance(from: lower.startIndex, to: range.lowerBound)
            let end = lower.distance(from: lower.startIndex, to: range.upperBound)
            var copy = question
            let s = copy.index(copy.startIndex, offsetBy: start), e = copy.index(copy.startIndex, offsetBy: end)
            copy.replaceSubrange(s..<e, with: " ")
            return copy
        }
    }

    // MARK: - Index

    /// An immutable in-memory inverted index over one document, like a
    /// Lucene segment: term -> postings (passage, position). Terms are
    /// stemmed, stopwords are skipped but keep their position so phrases
    /// still line up. Never written to disk.
    final class DocumentIndex {
        /// Passage start line (a transcript line, or the first line of a paragraph).
        let passageLines: [Int]
        /// Indexed (non-stopword) tokens per passage, for BM25 length normalisation.
        let passageLengths: [Int]
        /// Parallel arrays, one entry per occurrence, in passage order.
        let postings: [String: (passages: [Int32], positions: [Int32])]
        /// An original spelling for each stem, to report what a term matched as.
        let surface: [String: String]
        let lines: [String]

        init(text: String, kind: Kind) {
            lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var passages: [[String]] = []
            var starts: [Int] = []
            if kind == .transcript {
                for (i, line) in lines.enumerated() {
                    let tokens = SessionSearch.tokenize(TranscriptTimeline.spokenText(line))
                    if !tokens.isEmpty { passages.append(tokens); starts.append(i) }
                }
            } else {
                // Paragraphs: runs of non-blank lines.
                var start: Int?
                for i in 0...lines.count {
                    let blank = i == lines.count || lines[i].trimmingCharacters(in: .whitespaces).isEmpty
                    if !blank, start == nil { start = i }
                    if blank, let s = start {
                        let tokens = SessionSearch.tokenize(lines[s..<i].joined(separator: " "))
                        if !tokens.isEmpty { passages.append(tokens); starts.append(s) }
                        start = nil
                    }
                }
            }
            var postings: [String: (passages: [Int32], positions: [Int32])] = [:]
            var surface: [String: String] = [:]
            var lengths: [Int] = []
            for (p, tokens) in passages.enumerated() {
                var kept = 0
                for (position, token) in tokens.enumerated() where !SessionSearch.stopwords.contains(token) {
                    let stem = SessionSearch.stem(token)
                    postings[stem, default: ([], [])].passages.append(Int32(p))
                    postings[stem]!.positions.append(Int32(position))
                    if surface[stem] == nil { surface[stem] = token }
                    kept += 1
                }
                lengths.append(kept)
            }
            passageLines = starts
            passageLengths = lengths
            self.postings = postings
            self.surface = surface
        }
    }

    /// Indexes by content, so editing one session rebuilds only that session.
    /// In memory only (it holds transcript text; `clearCache()` runs when the
    /// app or the data folder locks). Each search marks the entries it uses;
    /// when the cache is full, only entries the current search is not using
    /// are evicted, so one search can't evict its own sessions. A patient with
    /// more documents than `cacheLimit` leaves the surplus uncached. A search
    /// running when the cache is cleared adds nothing more to it, so a lock
    /// mid-search doesn't leave transcript text behind.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (index: DocumentIndex, generation: Int)] = [:]
    nonisolated(unsafe) private static var generation = 0
    nonisolated(unsafe) private static var clears = 0
    static let cacheLimit = 1_500

    /// Returns the clear count at the start, for `index(for:clearsAtStart:)`.
    private static func beginSearch() -> Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        generation += 1
        return clears
    }

    static func index(for document: Document, clearsAtStart: Int? = nil) -> DocumentIndex {
        let key = "\(document.kind)-" + NoteFreshness.fingerprint(of: document.text)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cache[key] {
            cache[key] = (hit.index, generation)
            return hit.index
        }
        let built = DocumentIndex(text: document.text, kind: document.kind)
        if let clearsAtStart, clearsAtStart != clears { return built }
        if cache.count >= cacheLimit { cache = cache.filter { $0.value.generation == generation } }
        if cache.count < cacheLimit { cache[key] = (built, generation) }
        return built
    }

    static func clearCache() {
        cacheLock.lock()
        cache.removeAll()
        clears += 1
        cacheLock.unlock()
    }

    /// Entries held, for tests.
    static var cachedIndexCount: Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache.count
    }

    // MARK: - Search

    /// Searches `documents` for the terms in `question`. Documents dated
    /// outside a range the question names are skipped (and not counted).
    /// Per-document indexes are combined here: passage counts, lengths and
    /// document frequencies are summed across them for BM25.
    static func search(
        _ documents: [Document], question: String, now: Date = Date(), calendar: Calendar = .current
    ) -> Result {
        let clearsAtStart = beginSearch()
        let range = dateRange(in: question, now: now, calendar: calendar)
        let terms = terms(from: question)
        let inRange = documents.indices.filter { range?.contains(documents[$0].date) ?? true }
        let sessionsSearched = Set(inRange.map { documents[$0].tag }).count
        guard !terms.isEmpty else {
            return Result(
                terms: [], dateRange: range, hits: [], totalMentions: 0, similarMentions: 0, termCounts: [],
                sessionsWithHits: 0, sessionsSearched: sessionsSearched, matchedVariants: [:]
            )
        }

        let indexes = inRange.map { index(for: documents[$0], clearsAtStart: clearsAtStart) }
        let passageCount = indexes.reduce(0) { $0 + $1.passageLengths.count }
        let totalLength = indexes.reduce(0) { $0 + $1.passageLengths.reduce(0, +) }
        let avgLength = max(1, Double(totalLength) / Double(max(1, passageCount)))

        // Per term: weighted frequency by (document, passage), mentions, and the
        // spellings it matched besides its own.
        struct Key: Hashable { let doc: Int, passage: Int32 }
        var frequencies: [[Key: Double]] = Array(repeating: [:], count: terms.count)
        var exactCounts = Array(repeating: 0, count: terms.count)
        var similarCounts = Array(repeating: 0, count: terms.count)
        var variants: [String: [String]] = [:]
        for (ti, term) in terms.enumerated() {
            for (n, index) in indexes.enumerated() {
                if term.words.count == 1 {
                    for (key, weight) in expand(term, in: index) {
                        guard let list = index.postings[key] else { continue }
                        if weight < 1, let spelling = index.surface[key], !(variants[term.text]?.contains(spelling) ?? false) {
                            variants[term.text, default: []].append(spelling)
                        }
                        for p in list.passages { frequencies[ti][Key(doc: n, passage: p), default: 0] += weight }
                        if weight < 1 { similarCounts[ti] += list.passages.count } else { exactCounts[ti] += list.passages.count }
                    }
                } else {
                    for p in phraseMatches(term, in: index) {
                        frequencies[ti][Key(doc: n, passage: p), default: 0] += 1
                        exactCounts[ti] += 1
                    }
                }
            }
        }

        let k1: Double = 1.2
        let b: Double = 0.75
        let total = Double(passageCount)
        let idf: [Double] = frequencies.map { (freq: [Key: Double]) -> Double in
            let n: Double = Double(freq.count)
            let ratio: Double = (total - n + 0.5) / (n + 0.5)
            return log(1 + ratio)
        }
        var scores: [Key: Double] = [:]
        for (ti, freq) in frequencies.enumerated() {
            for (key, tf) in freq {
                let length: Double = Double(indexes[key.doc].passageLengths[Int(key.passage)])
                let lengthRatio: Double = length / avgLength
                let norm: Double = k1 * (1 - b + b * lengthRatio)
                let gain: Double = tf * (k1 + 1) / (tf + norm)
                scores[key, default: 0] += idf[ti] * gain
            }
        }
        // Best first; ties go to the more recent session, then the earlier line.
        let ranked = scores.sorted { l, r in
            if l.value != r.value { return l.value > r.value }
            let (ld, rd) = (documents[inRange[l.key.doc]].date, documents[inRange[r.key.doc]].date)
            if ld != rd { return ld > rd }
            if l.key.doc != r.key.doc { return l.key.doc < r.key.doc }
            return l.key.passage < r.key.passage
        }

        let hits = ranked.map { item -> Hit in
            let d = inRange[item.key.doc]
            let doc = documents[d]
            let index = indexes[item.key.doc]
            let i = index.passageLines[Int(item.key.passage)]
            var context = [String](), start = i, seconds: Int?
            if doc.kind == .transcript {
                start = max(0, i - 2)
                context = Array(index.lines[start..<min(index.lines.count, i + 3)])
                var j = i
                while j >= 0, seconds == nil {
                    seconds = TranscriptTimeline.leadingSeconds(of: index.lines[j])
                    j -= 1
                }
            }
            return Hit(
                documentIndex: d, date: doc.date, tag: doc.tag, kind: doc.kind, seconds: seconds,
                lineIndex: i, line: index.lines[i], context: context, contextStart: start, score: item.value
            )
        }
        return Result(
            terms: terms, dateRange: range, hits: hits,
            totalMentions: exactCounts.reduce(0, +) + similarCounts.reduce(0, +), similarMentions: similarCounts.reduce(0, +),
            termCounts: terms.indices.map { TermCount(term: terms[$0], exact: exactCounts[$0], similar: similarCounts[$0]) },
            sessionsWithHits: Set(hits.map(\.tag)).count, sessionsSearched: sessionsSearched,
            matchedVariants: variants.mapValues { Array($0.sorted().prefix(5)) }
        )
    }

    /// The dictionary entries a single-word term matches in `index`, with
    /// weights: the term itself, one-letter typos, and sound-alike names.
    /// Expanding over the dictionary (distinct stems) rather than every token
    /// is what keeps fuzzy matching cheap. Names are not stemmed; they match
    /// the stored stem of their own spelling ("Jane" finds "jan") or a
    /// one-letter variant of it.
    private static func expand(_ term: Term, in index: DocumentIndex) -> [(String, Double)] {
        let word = term.words[0]
        let stemmed = stem(word)
        var result: [(String, Double)] = []
        for key in index.postings.keys {
            let weight: Double?
            if key == stemmed || (term.isName && key == word) {
                weight = 1
            } else if term.quoted {
                weight = nil
            } else {
                weight = matchWeight(token: key, term: term.isName ? word : stemmed, isName: term.isName)
            }
            if let weight { result.append((key, weight)) }
        }
        return result
    }

    /// Passages where the phrase's words occur at consecutive positions
    /// (stopwords inside the phrase take a position but are not checked, as
    /// the index doesn't store them).
    private static func phraseMatches(_ term: Term, in index: DocumentIndex) -> [Int32] {
        let content = term.words.enumerated().filter { !stopwords.contains($0.element) }
        guard let first = content.first, let lead = index.postings[stem(first.element)] else { return [] }
        func packed(_ passage: Int32, _ position: Int32) -> Int64 {
            let high: Int64 = Int64(passage) << 32
            return high | Int64(position)
        }
        var others: [(offset: Int, positions: Set<Int64>)] = []
        for (offset, word) in content.dropFirst() {
            guard let list = index.postings[stem(word)] else { return [] }
            var positions = Set<Int64>()
            for (p, position) in zip(list.passages, list.positions) { positions.insert(packed(p, position)) }
            others.append((offset - first.offset, positions))
        }
        var found: [Int32] = []
        for (p, position) in zip(lead.passages, lead.positions) {
            var all = true
            for other in others where !other.positions.contains(packed(p, position + Int32(other.offset))) {
                all = false
                break
            }
            if all { found.append(p) }
        }
        return found
    }

    /// Conservative English stemmer in the spirit of Lucene's minimal stemmers:
    /// plurals, past tense and -ing, so "worries", "worried" and "worrying" all
    /// meet at "worry". Applied to indexed words and non-name query words alike.
    static func stem(_ word: String) -> String {
        var w = word
        guard w.count > 3 else { return w }
        if w.hasSuffix("sses") {
            w.removeLast(2)
        } else if w.hasSuffix("ies"), w.count > 4 {
            w.removeLast(3); w += "y"
        } else if w.hasSuffix("s"), !w.hasSuffix("ss"), !w.hasSuffix("us"), !w.hasSuffix("is") {
            w.removeLast()
        }
        func undouble(_ s: String) -> String {
            guard let last = s.last, s.count > 2, last == s[s.index(before: s.index(before: s.endIndex))],
                  !"lsz".contains(last), last.isLetter, !"aeiou".contains(last) else { return s }
            return String(s.dropLast())
        }
        if w.hasSuffix("ied"), w.count > 4 {
            w.removeLast(3); w += "y"
        } else if w.hasSuffix("ed"), w.count > 4 {
            w = undouble(String(w.dropLast(2)))
        } else if w.hasSuffix("ing"), w.count > 5 {
            w = undouble(String(w.dropLast(3)))
        }
        if w.hasSuffix("e"), w.count > 3 { w.removeLast() }
        return w
    }

    // MARK: - Matching

    /// 1 for the same word, 0.7 for a one-letter typo (terms of five or more
    /// letters), 0.6 for a name that sounds alike. Nil for no match.
    ///
    /// Sound-alike (Soundex) needs words of four or more letters and an edit
    /// distance of at most two, so "Dana" does not match "Dan" (too short) but
    /// "Micheal"/"Michael", "Mikael" and "Stephen"/"Steven" are caught. The
    /// price is that a different name that sounds the same
    /// ("Michael"/"Michelle") matches too, so a count is "mentions of a name
    /// like this", not proof of who was meant; the search block lists every
    /// extra spelling it matched so the answer can say so.
    static func matchWeight(token: String, term: String, isName: Bool) -> Double? {
        if token == term { return 1 }
        if term.count >= 5, token.count >= 4, damerauLevenshtein(token, term, limit: 1) <= 1 { return 0.7 }
        if isName, term.count >= 4, token.count >= 4,
           soundex(token) == soundex(term), damerauLevenshtein(token, term, limit: 2) <= 2 { return 0.6 }
        return nil
    }

    /// Lowercase, accent-free words; `'s` stripped so "Dana's" is "dana".
    static func tokenize(_ text: String) -> [String] {
        var folded = text.lowercased().replacingOccurrences(of: "’", with: "'")
        if folded.utf8.contains(where: { $0 >= 128 }) {
            folded = folded.folding(options: .diacriticInsensitive, locale: nil)
        }
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            guard !current.isEmpty else { return }
            var word = String(current)
            for suffix in ["'s", "’s"] where word.hasSuffix(suffix) { word.removeLast(2) }
            word = word.trimmingCharacters(in: CharacterSet(charactersIn: "'’"))
            if !word.isEmpty { tokens.append(word) }
            current = String.UnicodeScalarView()
        }
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" || scalar == "’" {
                current.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// Optimal-string-alignment distance (insert, delete, substitute, swap two
    /// neighbours). Returns `limit + 1` early when the words differ by more.
    static func damerauLevenshtein(_ a: String, _ b: String, limit: Int) -> Int {
        let s = Array(a.unicodeScalars), t = Array(b.unicodeScalars)
        if abs(s.count - t.count) > limit { return limit + 1 }
        var previous2 = [Int](repeating: 0, count: t.count + 1)
        var previous = Array(0...t.count)
        for i in 1...max(1, s.count) where !s.isEmpty {
            var row = [Int](repeating: i, count: t.count + 1)
            for j in 1...max(1, t.count) where !t.isEmpty {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, s[i - 1] == t[j - 2], s[i - 2] == t[j - 1] {
                    row[j] = min(row[j], previous2[j - 2] + 1)
                }
            }
            previous2 = previous
            previous = row
        }
        return s.isEmpty ? t.count : (t.isEmpty ? s.count : previous[t.count])
    }

    /// American Soundex: first letter plus three digits. Empty for no letters.
    static func soundex(_ word: String) -> String {
        let codes: [Character: Character] = [
            "b": "1", "f": "1", "p": "1", "v": "1",
            "c": "2", "g": "2", "j": "2", "k": "2", "q": "2", "s": "2", "x": "2", "z": "2",
            "d": "3", "t": "3", "l": "4", "m": "5", "n": "5", "r": "6",
        ]
        let letters = word.lowercased().filter { $0.isASCII && $0.isLetter }
        guard let first = letters.first else { return "" }
        var result = String(first).uppercased()
        var last = codes[first]
        for ch in letters.dropFirst() {
            if let code = codes[ch] {
                if code != last { result.append(code) }
                last = code
            } else if ch != "h" && ch != "w" {
                last = nil   // a vowel separates repeats; h and w do not
            }
            if result.count == 4 { break }
        }
        return result.padding(toLength: 4, withPad: "0", startingAt: 0)
    }
}
