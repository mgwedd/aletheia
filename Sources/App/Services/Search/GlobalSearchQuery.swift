import Foundation

/// One word of a global-search query, in the form the index stores words
/// (see `SearchIndex.stored`): folded, letters and digits only, stemmed
/// unless it is a common word.
struct GlobalSearchTerm: Equatable {
    /// The word as typed, folded: "Worries" → "worries".
    let word: String
    /// Its stored form: "worries" → "worry", "time" → "time".
    let stem: String

    /// `raw` is one token from `SessionSearch.tokenize`.
    init(raw: String) {
        word = SearchIndex.ftsToken(raw)
        stem = SearchIndex.stored(raw)
    }

    var isNumber: Bool { GlobalSearchQuery.isNumber(word) }

    /// Whether a stored word that merely starts with this one matches, so
    /// results keep up with typing ("thera" finds "therapy"). Not for a single
    /// letter or digit, which matches as a whole word ("I", "8"): as a prefix
    /// it would match most of the index.
    var matchesPrefixes: Bool {
        word.count >= 2
    }

    /// The FTS5 MATCH expression: the stem itself, or any stored word starting
    /// with the word as typed. Words hold only letters and digits, so quoting
    /// is safe.
    var clause: String {
        guard matchesPrefixes else { return "\"\(word)\"" }
        if stem == word { return "\"\(word)\" *" }
        return "\"\(stem)\" OR \"\(word)\" *"
    }

    /// Whether a stored word (index form) matches: the same test as `clause`.
    func matches(indexed token: String) -> Bool {
        if token == stem || token == word { return true }
        return matchesPrefixes && token.hasPrefix(word)
    }
}

/// A global-search query: the words typed, which of them must match, and
/// which are looked up in notes, comments and transcripts. Pure.
///
/// Every word must match somewhere for a place to be a result. No word is
/// left out, however common or short: ranking, not the query, keeps "the"
/// from mattering.
///   - a patient: in the patient's name (anywhere in it, as typed);
///   - a session: in its date or its patient's name, at least one in the date;
///   - a note, comment or transcript: in its text, its patient's name, or its
///     session's date, at least one in the text. So "jane insomnia" finds
///     Jane's sessions that mention insomnia, and "insomnia march" those in March.
struct GlobalSearchQuery: Equatable {
    /// More words than this are ignored (each is one index lookup).
    static let maximumWords = 8

    let text: String
    /// The folded words, in order, without repeats.
    let words: [String]
    /// What patients and sessions must match: every word.
    var required: [String] { words }
    /// What notes, comments and transcripts must match, one bit each: every word.
    let textTerms: [GlobalSearchTerm]

    init(_ text: String) {
        self.text = text
        var seen = Set<String>()
        var words: [String] = []
        var terms: [GlobalSearchTerm] = []
        for raw in SessionSearch.tokenize(text) {
            let word = SearchIndex.ftsToken(raw)
            guard !word.isEmpty, seen.insert(word).inserted else { continue }
            guard words.count < Self.maximumWords else { break }
            words.append(word)
            terms.append(GlobalSearchTerm(raw: raw))
        }
        self.words = words
        self.textTerms = terms
    }

    var isEmpty: Bool { words.isEmpty }

    /// Bits for every text term set.
    var allTermsMask: UInt32 { GlobalSearchQuery.mask(count: textTerms.count) }

    static func mask(count: Int) -> UInt32 {
        if count <= 0 { return 0 }
        if count >= 32 { return UInt32.max }
        return (UInt32(1) << UInt32(count)) - 1
    }

    static func isNumber(_ word: String) -> Bool {
        !word.isEmpty && word.allSatisfy { $0.isASCII && $0.isNumber }
    }

    // MARK: Names

    /// A name as the query's words are compared with it: folded words joined by spaces.
    static func nameForm(_ name: String) -> String {
        SessionSearch.tokenize(name).map { SearchIndex.ftsToken($0) }.joined(separator: " ")
    }

    /// Whether `word` appears in the name (anywhere, so "ann" finds "Joanne").
    static func name(_ nameForm: String, contains word: String) -> Bool {
        nameForm.contains(word)
    }

    /// Whether a patient matches: every required word is in the name.
    func matchesPatient(nameForm: String) -> Bool {
        !required.isEmpty && required.allSatisfy { GlobalSearchQuery.name(nameForm, contains: $0) }
    }

    /// Whether `word` names `date`. A month name that is also an everyday word
    /// ("may", "march") counts only next to a day or year of that date ("may 5",
    /// "march 2026"), the rule the chat's date filter follows too (#354), so
    /// "she may" or "march on" isn't read as a date.
    func dateMatches(_ word: String, _ date: GlobalSearchDate) -> Bool {
        guard date.matches(word) else { return false }
        guard GlobalSearchDate.everydayMonthWords.contains(word) else { return true }
        return required.contains { GlobalSearchQuery.isNumber($0) && date.matches($0) }
    }

    /// Whether a session matches: every required word is in its date or its
    /// patient's name, and at least one is in the date.
    func matchesSession(date: GlobalSearchDate, nameForm: String) -> Bool {
        var inDate = false
        for word in required {
            if dateMatches(word, date) {
                inDate = true
            } else if !GlobalSearchQuery.name(nameForm, contains: word) {
                return false
            }
        }
        return inDate
    }

    /// The text terms the patient's name or the session's date already answer.
    func termsAnsweredBy(date: GlobalSearchDate, nameForm: String) -> UInt32 {
        var mask: UInt32 = 0
        for (i, term) in textTerms.enumerated() {
            if dateMatches(term.word, date) || GlobalSearchQuery.name(nameForm, contains: term.word) {
                mask |= UInt32(1) << UInt32(i)
            }
        }
        return mask
    }
}

/// The words a session's date answers to: the day, the month (number and
/// name, in the user's language and in English) and the year, so "oct 8",
/// "october 2026", "10/8/26" and "2026-10-08" all find it. Pure.
struct GlobalSearchDate: Equatable {
    /// Month names (and their start) that are also everyday words; see `GlobalSearchQuery.dateMatches`.
    static let everydayMonthWords: Set<String> = ["may", "mar", "march"]

    let numbers: Set<Int>
    /// Folded month names, full and short.
    let monthNames: [String]

    /// `monthNames` is `monthNameTable(calendar:)`, passed in when many dates are made at once.
    init(_ date: Date, calendar: Calendar, monthNames table: [[String]]? = nil) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        var numbers = Set<Int>()
        if let day = parts.day { numbers.insert(day) }
        if let month = parts.month { numbers.insert(month) }
        if let year = parts.year {
            numbers.insert(year)
            numbers.insert(year % 100)
        }
        self.numbers = numbers
        let names = table ?? GlobalSearchDate.monthNameTable(calendar: calendar)
        if let month = parts.month, month >= 1, month <= names.count {
            self.monthNames = names[month - 1]
        } else {
            self.monthNames = []
        }
    }

    /// Per month (January first), its folded names: full and short, in the
    /// calendar's language and in English.
    static func monthNameTable(calendar: Calendar) -> [[String]] {
        var english = Calendar(identifier: .gregorian)
        english.locale = Locale(identifier: "en_US_POSIX")
        let lists = [calendar.monthSymbols, calendar.shortMonthSymbols, english.monthSymbols, english.shortMonthSymbols]
        let count = lists.map { $0.count }.max() ?? 0
        var table: [[String]] = []
        for month in 0..<count {
            var names: [String] = []
            for symbols in lists where month < symbols.count {
                let folded = GlobalSearchQuery.nameForm(symbols[month]).replacingOccurrences(of: " ", with: "")
                if !folded.isEmpty, !names.contains(folded) { names.append(folded) }
            }
            table.append(names)
        }
        return table
    }

    /// A number matches the day, month or year exactly ("08" is 8); a word of
    /// three or more letters matches the start of the month's name.
    func matches(_ word: String) -> Bool {
        if GlobalSearchQuery.isNumber(word) {
            guard let value = Int(word) else { return false }
            return numbers.contains(value)
        }
        guard word.count >= 3 else { return false }
        return monthNames.contains { $0.hasPrefix(word) }
    }
}

/// Matching query terms against original text, the same way the index does,
/// for snippets and for checking a place still matches. Pure.
enum GlobalSearchText {
    /// Which terms the text contains, one bit per term.
    static func mask(of text: String, terms: [GlobalSearchTerm]) -> UInt32 {
        guard !terms.isEmpty else { return 0 }
        let full = GlobalSearchQuery.mask(count: terms.count)
        var mask: UInt32 = 0
        for token in SessionSearch.tokenize(text) {
            let stored = SearchIndex.stored(token)
            for (i, term) in terms.enumerated() where term.matches(indexed: stored) {
                mask |= UInt32(1) << UInt32(i)
            }
            if mask == full { break }
        }
        return mask
    }

    /// The passage to show for a place: the one matching the most terms (the
    /// first of those). nil when the place doesn't match: not every term is in
    /// some passage or in `answered` (name and date), or no term is in the text.
    static func bestPassage(_ passages: [String], terms: [GlobalSearchTerm], answered: UInt32) -> Int? {
        let full = GlobalSearchQuery.mask(count: terms.count)
        var union: UInt32 = 0
        var best: Int?
        var bestCount = 0
        for (i, passage) in passages.enumerated() {
            let found = mask(of: passage, terms: terms)
            guard found != 0 else { continue }
            union |= found
            if found.nonzeroBitCount > bestCount {
                best = i
                bestCount = found.nonzeroBitCount
            }
        }
        guard let best, (union | answered) & full == full else { return nil }
        return best
    }

    /// Paragraphs of notes, as the index splits them (blank lines between).
    static func paragraphs(_ text: String) -> [String] {
        var result: [String] = []
        var current: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !current.isEmpty { result.append(current.joined(separator: " ")) }
                current = []
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { result.append(current.joined(separator: " ")) }
        return result
    }

    /// A transcript line's time code and speaker ("[00:01] You: "), which the
    /// index leaves out (`TranscriptTimeline.spokenText`).
    private static let speakerLabel = try? NSRegularExpression(pattern: #"^\s*\[[0-9:]+\][^:\n]*:"#, options: .anchorsMatchLines)

    /// Where each word of `text` that matches one of `terms` is. Words in a
    /// transcript line's speaker label are skipped, as the index skips them, so
    /// "you" or "patient" marks what was said, not who said it.
    static func wordRanges(in text: String, terms: [GlobalSearchTerm]) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        let labels = speakerLabel?.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text) } ?? []
        var start: String.Index?
        var index = text.startIndex
        func close(at end: String.Index) {
            guard let begin = start else { return }
            start = nil
            if labels.contains(where: { $0.contains(begin) }) { return }
            let word = String(text[begin..<end])
            for token in SessionSearch.tokenize(word) {
                let stored = SearchIndex.stored(token)
                if terms.contains(where: { $0.matches(indexed: stored) }) {
                    ranges.append(begin..<end)
                    return
                }
            }
        }
        while index < text.endIndex {
            let character = text[index]
            let isWord = character.isLetter || character.isNumber || character == "'" || character == "\u{2019}"
            if isWord {
                if start == nil { start = index }
            } else {
                close(at: index)
            }
            index = text.index(after: index)
        }
        close(at: text.endIndex)
        return ranges
    }

    /// One line of `text` around its first matching word, about `radius`
    /// characters either side, with "…" where it was cut.
    static func snippet(_ text: String, terms: [GlobalSearchTerm], radius: Int = 70) -> String {
        let flat = text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !flat.isEmpty else { return "" }
        let first = wordRanges(in: flat, terms: terms).first
        let center = first ?? flat.startIndex..<flat.startIndex
        let lower = flat.index(center.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
        let span = first == nil ? 2 * radius : radius
        let upper = flat.index(center.upperBound, offsetBy: span, limitedBy: flat.endIndex) ?? flat.endIndex
        var excerpt = String(flat[lower..<upper]).trimmingCharacters(in: .whitespaces)
        if lower > flat.startIndex { excerpt = "\u{2026}" + excerpt }
        if upper < flat.endIndex { excerpt += "\u{2026}" }
        return excerpt
    }
}
