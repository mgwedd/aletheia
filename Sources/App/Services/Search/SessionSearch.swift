import Foundation

/// Search over one patient's material (#286): FTS5 BM25 over passages (see
/// `SearchIndex`), with whole-word matching, one-letter typo tolerance and a
/// sound-alike match for names (whisper misspells them). Deterministic; the
/// model never sees anything the code didn't count.
///
/// A passage is one transcript line, or one paragraph of notes. The counts in
/// `Result` are exact over every document passed in (after the date filter),
/// whatever part of them ends up in a prompt.
enum SessionSearch {
    enum Kind: String, Equatable { case transcript, note, sessionNotes, comment }

    /// One piece of a session's material. `tag` is the citation tag ("S1").
    struct Document {
        let date: Date
        let tag: String
        let kind: Kind
        let text: String
        /// The session and patient the text belongs to, when the caller knows
        /// them. They let the index replace a session's older text and drop it
        /// when the session goes; without them the text is indexed but only
        /// cleaned up by the launch sweep.
        var session: UUID? = nil
        var patient: UUID? = nil
    }

    /// A search term: one or more words. Quoted phrases keep all their words
    /// and match consecutive words only; names also match sound-alikes.
    struct Term: Equatable {
        let words: [String]
        let isName: Bool
        /// Typed in quotes: matches exactly, with no typo or sound-alike matching.
        var quoted = false
        /// Typed with a trailing `*` ("wor*"): matches every word starting with it.
        var prefix = false
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
        /// The session the passage belongs to, when the document named one.
        var sessionID: UUID? = nil
        /// Positions (in indexed words, stopwords included) of the matches within the passage at `lineIndex`.
        var tokenOffsets: [Int] = []
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

        // Prefixes: a word of two or more letters or digits ending in `*`.
        let starred = try? NSRegularExpression(pattern: #"([\p{L}\p{N}]{2,})\*"#)
        let remaining = NSRange(rest.startIndex..., in: rest)
        for match in starred?.matches(in: rest, range: remaining) ?? [] {
            if let r = Range(match.range(at: 1), in: rest), let word = tokenize(String(rest[r])).first {
                add(Term(words: [word], isName: false, prefix: true))
            }
        }
        rest = starred?.stringByReplacingMatches(in: rest, range: remaining, withTemplate: " ") ?? rest

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

    /// The persistent index every search runs against. In memory until the app
    /// points it at `<dataRoot>/search.sqlite` (see `AppModel`).
    nonisolated(unsafe) static var index = SearchIndex()

    /// Closes the index's database connection so no indexed text stays in
    /// SQLite's memory while the app or data folder is locked. The next search
    /// reopens it.
    static func closeIndex() { index.close() }

    // MARK: - Search

    /// How one term is matched against a stored passage.
    private enum Matcher {
        /// Stored word -> weight (1 exact, below 1 a typo or sound-alike).
        case words([String: Double])
        /// Stored words, `SearchIndex.stopToken` standing for a stopword.
        case phrase([String])
        case prefix(String)
    }

    /// Searches `documents` for the terms in `question`. Documents dated
    /// outside a range the question names are skipped (and not counted).
    /// Documents are stored in the persistent index the first time they are
    /// seen (keyed by session, kind and a fingerprint of their text, so only
    /// changed text is re-indexed); candidates and ranking come from FTS5
    /// MATCH + bm25, and the exact counts are taken from the matched passages.
    static func search(
        _ documents: [Document], question: String, now: Date = Date(), calendar: Calendar = .current
    ) -> Result {
        let range = dateRange(in: question, now: now, calendar: calendar)
        let terms = terms(from: question)
        let inRange = documents.indices.filter { range?.contains(documents[$0].date) ?? true }
        let sessionsSearched = Set(inRange.map { documents[$0].tag }).count
        func empty(_ terms: [Term]) -> Result {
            Result(
                terms: terms, dateRange: range, hits: [], totalMentions: 0, similarMentions: 0,
                termCounts: terms.map { TermCount(term: $0, exact: 0, similar: 0) },
                sessionsWithHits: 0, sessionsSearched: sessionsSearched, matchedVariants: [:]
            )
        }
        guard !terms.isEmpty else { return empty([]) }

        let items = inRange.map { i -> SearchIndex.Item in
            let d = documents[i]
            return SearchIndex.Item(
                session: d.session?.uuidString ?? "", patient: d.patient?.uuidString, kind: d.kind.rawValue,
                date: d.date.timeIntervalSinceReferenceDate, fingerprint: SearchIndex.fingerprint(of: d.text), text: d.text
            )
        }
        // Tokenize what isn't stored yet outside the index's lock.
        let current = index
        var prepared: [Int: [SearchIndex.Passage]] = [:]
        for i in current.missing(items) { prepared[i] = SearchIndex.passages(of: items[i].text, kind: documents[inRange[i]].kind) }
        // One retry: a database that turned out corrupt was reset, and storing the documents again refills it.
        var found: (rows: [SearchIndex.Row], docs: [Int64: [Int]], info: [Matcher]?)?
        for _ in 0..<2 where found == nil {
            found = current.query(items: items, passages: prepared) { vocabulary in matchPlan(for: terms, vocabulary: vocabulary) }
        }
        guard let found, let matchers = found.info else { return empty(terms) }

        var exact = Array(repeating: 0, count: terms.count)
        var similar = Array(repeating: 0, count: terms.count)
        var variants: [String: [String]] = [:]
        struct Candidate { let position: Int; let line: Int; let offsets: [Int]; let score: Double }
        var candidates: [Candidate] = []
        for row in found.rows {
            for position in found.docs[row.doc] ?? [] {
                var offsets: [Int] = []
                for (ti, matcher) in matchers.enumerated() {
                    switch matcher {
                    case .words(let weights):
                        for (at, token) in row.tokens.enumerated() {
                            guard let weight = weights[token] else { continue }
                            offsets.append(at)
                            if weight < 1 {
                                similar[ti] += 1
                                if !(variants[terms[ti].text]?.contains(token) ?? false) { variants[terms[ti].text, default: []].append(token) }
                            } else {
                                exact[ti] += 1
                            }
                        }
                    case .prefix(let prefix):
                        for (at, token) in row.tokens.enumerated() where token.hasPrefix(prefix) { offsets.append(at); exact[ti] += 1 }
                    case .phrase(let pattern):
                        var at = 0
                        while at + pattern.count <= row.tokens.count {
                            if pattern.indices.allSatisfy({ row.tokens[at + $0] == pattern[$0] }) {
                                offsets.append(at)
                                exact[ti] += 1
                                at += pattern.count
                            } else {
                                at += 1
                            }
                        }
                    }
                }
                if !offsets.isEmpty { candidates.append(Candidate(position: position, line: row.line, offsets: offsets.sorted(), score: row.score)) }
            }
        }
        // Best first; ties go to the more recent session, then the earlier line.
        candidates.sort { l, r in
            if l.score != r.score { return l.score > r.score }
            let (ld, rd) = (documents[inRange[l.position]].date, documents[inRange[r.position]].date)
            if ld != rd { return ld > rd }
            if l.position != r.position { return l.position < r.position }
            return l.line < r.line
        }

        var lineCache: [Int: LineTable] = [:]
        let hits = candidates.map { c -> Hit in
            let d = inRange[c.position]
            let doc = documents[d]
            let lines = lineCache[d] ?? LineTable(doc.text)
            lineCache[d] = lines
            let i = c.line
            var context = [String](), start = i, seconds: Int?
            if doc.kind == .transcript {
                start = max(0, i - 2)
                context = (start..<min(lines.count, i + 3)).map { lines[$0] }
                var j = i
                while j >= 0, seconds == nil {
                    seconds = TranscriptTimeline.leadingSeconds(of: lines[j])
                    j -= 1
                }
            }
            return Hit(
                documentIndex: d, date: doc.date, tag: doc.tag, kind: doc.kind, seconds: seconds,
                lineIndex: i, line: lines[i], context: context, contextStart: start, score: c.score,
                sessionID: doc.session, tokenOffsets: c.offsets
            )
        }
        return Result(
            terms: terms, dateRange: range, hits: hits,
            totalMentions: exact.reduce(0, +) + similar.reduce(0, +), similarMentions: similar.reduce(0, +),
            termCounts: terms.indices.map { TermCount(term: terms[$0], exact: exact[$0], similar: similar[$0]) },
            sessionsWithHits: Set(hits.map(\.tag)).count, sessionsSearched: sessionsSearched,
            matchedVariants: variants.mapValues { Array($0.sorted().prefix(5)) }
        )
    }

    /// The FTS5 MATCH string for `terms` and how to count each term in a
    /// matched passage. Single words expand over the index vocabulary to the
    /// word itself, one-letter typos and sound-alike names (the vocabulary is
    /// the distinct stored words, which is what keeps this cheap). Names are
    /// not stemmed; they match the stored stem of their own spelling ("Jane"
    /// finds "jan") or a one-letter variant of it.
    private static func matchPlan(for terms: [Term], vocabulary: () -> [String]) -> (match: String, info: [Matcher])? {
        var clauses: [String] = []
        var matchers: [Matcher] = []
        var words: [String]?
        for term in terms {
            if term.prefix {
                let prefix = SearchIndex.ftsToken(term.words[0])
                matchers.append(.prefix(prefix))
                clauses.append("\"\(prefix)\" *")
                continue
            }
            if term.words.count > 1 {
                var pattern = term.words.map { stopwords.contains($0) ? SearchIndex.stopToken : SearchIndex.ftsToken(stem($0)) }
                while pattern.first == SearchIndex.stopToken { pattern.removeFirst() }
                while pattern.last == SearchIndex.stopToken { pattern.removeLast() }
                if !pattern.isEmpty {
                    matchers.append(.phrase(pattern))
                    clauses.append("\"\(pattern.joined(separator: " "))\"")
                    continue
                }
            }
            let word = SearchIndex.ftsToken(term.words[0])
            let stemmed = SearchIndex.ftsToken(stem(term.words[0]))
            let target = term.isName ? word : stemmed
            var weights: [String: Double] = [stemmed: 1]
            if term.isName { weights[word] = 1 }
            if !term.quoted {
                if words == nil { words = vocabulary() }
                for key in words ?? [] where weights[key] == nil && abs(key.count - target.count) <= 2 {
                    if let weight = matchWeight(token: key, term: target, isName: term.isName) { weights[key] = weight }
                }
            }
            matchers.append(.words(weights))
            clauses.append(weights.keys.sorted().map { "\"\($0)\"" }.joined(separator: " OR "))
        }
        return clauses.isEmpty ? nil : (clauses.joined(separator: " OR "), matchers)
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
