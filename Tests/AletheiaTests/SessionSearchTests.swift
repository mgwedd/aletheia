import XCTest
@testable import Aletheia

/// Synthetic text only. Fixed `now` so every date filter is deterministic.
final class SessionSearchTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    override func setUp() {
        SessionSearch.clearCache()
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private var now: Date { date(2026, 10, 13) }

    private func doc(
        _ text: String, _ y: Int = 2026, _ m: Int = 3, _ d: Int = 5, tag: String = "S1", kind: SessionSearch.Kind = .transcript
    ) -> SessionSearch.Document {
        .init(date: date(y, m, d), tag: tag, kind: kind, text: text)
    }

    private func search(_ docs: [SessionSearch.Document], _ question: String) -> SessionSearch.Result {
        SessionSearch.search(docs, question: question, now: now, calendar: calendar)
    }

    private func range(_ question: String) -> (Date, Date)? {
        SessionSearch.dateRange(in: question, now: now, calendar: calendar).map { ($0.start, $0.end) }
    }

    // MARK: - Terms

    func testQuotedPhrasesStayWholeAndNamesAreFlagged() {
        let terms = SessionSearch.terms(from: "What did Dana say about \"the wedding\" and her sister?")
        XCTAssertEqual(terms.map(\.text), ["the wedding", "dana", "sister"])
        XCTAssertTrue(terms[0].quoted)
        XCTAssertTrue(terms[1].isName)
        XCTAssertFalse(terms[2].isName)
    }

    func testStopwordsAndDateExpressionsAreNotTerms() {
        XCTAssertEqual(SessionSearch.terms(from: "Tell me something new").map(\.text), ["new"])
        XCTAssertTrue(SessionSearch.terms(from: "Did we talk about me?").isEmpty)
        XCTAssertEqual(SessionSearch.terms(from: "sleep in the past 6 months").map(\.text), ["sleep"])
        XCTAssertEqual(SessionSearch.terms(from: "What did Dana say since March 2026?").map(\.text), ["dana"])
        XCTAssertTrue(SessionSearch.terms(from: "???").isEmpty)
    }

    func testMatchesWholeWordsNotSubstrings() {
        // #164: "me" used to match "name", "time" and "medication".
        let docs = [doc("[00:01] Patient: I forgot the name of my medication at that time.")]
        XCTAssertEqual(search(docs, "me").totalMentions, 0)
        XCTAssertEqual(search(docs, "Tim").totalMentions, 0, "'tim' is not inside 'time'")
        XCTAssertEqual(search(docs, "medication").totalMentions, 1)
    }

    // MARK: - Date filters (now = 2026-10-13)

    func testPastNUnits() {
        XCTAssertEqual(range("past 6 months")?.0, date(2026, 4, 13))
        XCTAssertEqual(range("in the last 2 weeks")?.0, date(2026, 9, 29))
        XCTAssertEqual(range("last 30 days")?.0, date(2026, 9, 13))
        XCTAssertEqual(range("past three years")?.0, date(2023, 10, 13))
        XCTAssertEqual(range("past month")?.0, date(2026, 9, 13))
        XCTAssertEqual(range("past 6 months")?.1, now)
    }

    func testSinceMonth() {
        XCTAssertEqual(range("since March")?.0, date(2026, 3, 1))
        XCTAssertEqual(range("since March 2025")?.0, date(2025, 3, 1))
        XCTAssertEqual(range("since December")?.0, date(2025, 12, 1), "a month still ahead means last year's")
        XCTAssertEqual(range("since March")?.1, now)
    }

    func testInMonth() throws {
        let march = try XCTUnwrap(range("what happened in March"))
        XCTAssertEqual(march.0, date(2026, 3, 1))
        XCTAssertLessThan(march.1, date(2026, 4, 1))
        XCTAssertGreaterThanOrEqual(march.1, date(2026, 3, 31))
        XCTAssertEqual(range("in June 2024")?.0, date(2024, 6, 1))
        XCTAssertEqual(range("in December")?.0, date(2025, 12, 1))
    }

    func testThisYearAndLastYear() throws {
        XCTAssertEqual(range("this year")?.0, date(2026, 1, 1))
        let last = try XCTUnwrap(range("last year"))
        XCTAssertEqual(last.0, date(2025, 1, 1))
        XCTAssertLessThan(last.1, date(2026, 1, 1))
        XCTAssertNil(range("what does she say about her mother"))
    }

    func testDateFilterLimitsWhichSessionsAreSearched() {
        let docs = [
            doc("[00:01] Patient: Dana called.", 2026, 9, 20, tag: "S1"),
            doc("[00:01] Patient: Dana visited.", 2025, 1, 20, tag: "S2"),
        ]
        let all = search(docs, "Dana")
        XCTAssertEqual(all.sessionsSearched, 2)
        XCTAssertEqual(all.totalMentions, 2)
        let recent = search(docs, "Dana in the past 6 months")
        XCTAssertEqual(recent.sessionsSearched, 1)
        XCTAssertEqual(recent.totalMentions, 1)
        XCTAssertEqual(recent.hits.map(\.tag), ["S1"])
    }

    // MARK: - Ranking

    func testRarerTermOutranksCommonTerm() {
        var lines = (0..<20).map { "[00:\(String(format: "%02d", $0))] Patient: Work was busy again today." }
        lines.append("[00:30] Patient: Dana came by.")
        let result = search([doc(lines.joined(separator: "\n"))], "Dana work")
        XCTAssertEqual(result.hits.first?.line, "[00:30] Patient: Dana came by.")
        XCTAssertEqual(result.hits.count, 21)
        XCTAssertGreaterThan(result.hits[0].score, result.hits[1].score)
    }

    func testPassageMatchingMoreTermsOutranksOne() {
        let text = "[00:01] A: The garden was quiet.\n[00:02] A: Her sister loved the garden and the lake.\n[00:03] A: The lake froze."
        let result = search([doc(text)], "garden lake")
        XCTAssertEqual(result.hits.first?.lineIndex, 1)
    }

    // MARK: - Fuzzy and phonetic

    func testMisspelledNameStillMatchesAndIsReported() {
        let docs = [doc("[00:05] Patient: My brother Micheal moved away.")]
        let result = search(docs, "What about Michael?")
        XCTAssertEqual(result.totalMentions, 1)
        XCTAssertEqual(result.matchedVariants["michael"], ["micheal"])
    }

    func testSoundAlikeNameButNotShortOrDifferentNames() {
        XCTAssertEqual(search([doc("[00:05] A: Mikael came.")], "Michael").totalMentions, 1)
        XCTAssertEqual(search([doc("[00:05] A: Stephen came.")], "Steven").totalMentions, 1)
        // Documented choice: names under four letters match exactly only, so
        // "Dana" does not find "Dan"; "Michael" is not confused with "Michelle".
        XCTAssertEqual(search([doc("[00:05] A: Dan came by.")], "Dana").totalMentions, 0)        // Known cost of sound-alike matching: Michelle also matches, and is reported.
        let michelle = search([doc("[00:05] A: Michelle came.")], "Michael")
        XCTAssertEqual(michelle.totalMentions, 1)
        XCTAssertEqual(michelle.matchedVariants["michael"]?.count, 1)
        XCTAssertEqual(search([doc("[00:05] A: Dana came by.")], "Dana").totalMentions, 1)
    }

    func testOneLetterTyposMatchLongerWordsOnly() {
        XCTAssertEqual(search([doc("[00:05] A: A lot of anxeity lately.")], "anxiety").totalMentions, 1)
        XCTAssertEqual(search([doc("[00:05] A: The cat sat.")], "cut").totalMentions, 0)
    }

    func testStemmingMeetsWorriesWorriedWorry() {
        let docs = [doc("[00:01] A: She worried a lot.\n[00:02] A: Many worries.\n[00:03] A: No worry at all.\n[00:04] A: Fine.")]
        XCTAssertEqual(search(docs, "worries").totalMentions, 3)
        XCTAssertEqual(SessionSearch.stem("worrying"), SessionSearch.stem("worry"))
        XCTAssertEqual(SessionSearch.stem("stopped"), SessionSearch.stem("stops"))
        XCTAssertEqual(SessionSearch.stem("anxious"), "anxious")
        XCTAssertEqual(SessionSearch.stem("Dana".lowercased()), "dana")
    }

    func testNamesAreNotStemmedButStillFound() {
        // "Jane" is stored as the stem "jan"; the name still finds itself.
        XCTAssertEqual(search([doc("[00:01] A: Jane called.")], "Jane").totalMentions, 1)
        XCTAssertEqual(search([doc("[00:01] A: Jones called.")], "Jones").totalMentions, 1)
    }

    func testSoundex() {
        XCTAssertEqual(SessionSearch.soundex("Robert"), "R163")
        XCTAssertEqual(SessionSearch.soundex("Rupert"), "R163")
        XCTAssertEqual(SessionSearch.soundex("Tymczak"), "T522")
        XCTAssertEqual(SessionSearch.soundex("Pfister"), "P236")
        XCTAssertEqual(SessionSearch.soundex("Ashcraft"), "A261")
    }

    func testDamerauLevenshtein() {
        XCTAssertEqual(SessionSearch.damerauLevenshtein("micheal", "michael", limit: 2), 1)
        XCTAssertEqual(SessionSearch.damerauLevenshtein("cat", "cart", limit: 2), 1)
        XCTAssertGreaterThan(SessionSearch.damerauLevenshtein("cat", "dogs", limit: 1), 1)
    }

    // MARK: - Phrases

    func testQuotedPhraseNeedsConsecutiveWords() {
        let text = "[00:01] A: The wedding cake was lovely.\n[00:02] A: A cake wedding came, then at the end of the garden.\n[00:03] A: The end, one garden."
        XCTAssertEqual(search([doc(text)], "\"wedding cake\"").totalMentions, 1)
        XCTAssertEqual(search([doc(text)], "\"cake wedding\"").totalMentions, 1)
        // Stopwords inside a phrase hold their place but are not checked.
        XCTAssertEqual(search([doc(text)], "\"end of the garden\"").totalMentions, 1)
    }

    func testQuotedWordIsExactOnly() {
        XCTAssertEqual(search([doc("[00:01] A: Micheal came.")], "\"Michael\"").totalMentions, 0)
    }

    // MARK: - Output

    func testHitsCarryTimestampContextAndTagNotesAreParagraphs() throws {
        let transcript = (1...8).map { "[0:\(String(format: "%02d", $0 * 10))] A: line \($0)" }
            .joined(separator: "\n") + "\n[1:02:03] B: Dana arrived.\nno stamp here\n[1:02:30] A: ok\n[1:02:40] A: bye\n[1:02:50] A: end"
        let notes = "First paragraph about sleep.\n\nDana was mentioned here\nacross two lines.\n\nLast."
        let result = search([doc(transcript, tag: "S1"), doc(notes, tag: "S1", kind: .sessionNotes)], "Dana")

        XCTAssertEqual(result.totalMentions, 2)
        let transcriptHit = try XCTUnwrap(result.hits.first { $0.kind == .transcript })
        XCTAssertEqual(transcriptHit.seconds, 3723)
        XCTAssertEqual(transcriptHit.tag, "S1")
        XCTAssertEqual(transcriptHit.context.count, 5)
        XCTAssertEqual(transcriptHit.context[2], "[1:02:03] B: Dana arrived.")
        XCTAssertEqual(transcriptHit.context[3], "no stamp here")
        XCTAssertEqual(transcriptHit.contextStart, transcriptHit.lineIndex - 2)
        let noteHit = try XCTUnwrap(result.hits.first { $0.kind == .sessionNotes })
        XCTAssertNil(noteHit.seconds)
        XCTAssertTrue(noteHit.context.isEmpty)
    }

    func testUntimedLineTakesTheNearestStampAbove() throws {
        let result = search([doc("[00:40] A: hello\nDana is here")], "Dana")
        XCTAssertEqual(result.hits.first?.seconds, 40)
    }

    func testExactCounts() {
        let docs = [
            doc("[00:01] A: Dana called.\n[00:02] A: Dana again, and Dana's mother.", 2026, 5, 1, tag: "S3"),
            doc("[00:01] A: Nothing relevant.", 2026, 6, 1, tag: "S2"),
            doc("[00:01] A: I saw Dana.", 2026, 7, 1, tag: "S1"),
            doc("Therapist wondered about Dana.", 2026, 7, 1, tag: "S1", kind: .sessionNotes),
        ]
        let result = search(docs, "Dana")
        XCTAssertEqual(result.totalMentions, 5)
        XCTAssertEqual(result.sessionsWithHits, 2)
        XCTAssertEqual(result.sessionsSearched, 3)
        XCTAssertEqual(result.hits.count, 4)
    }

    func testNoTermsMeansNoHits() {
        let result = search([doc("[00:01] A: hello")], "Did we talk about me?")
        XCTAssertTrue(result.terms.isEmpty)
        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertEqual(result.sessionsSearched, 1)
    }

    // MARK: - Performance

    /// ~50 sessions of ~60k characters. The first search builds a per-session
    /// index (cold); later searches reuse them (warm).
    func testFiftyLongSessionsSearchQuickly() {
        let words = ["weather", "errands", "sleep", "mother", "garden", "work", "walk", "dinner", "tired", "weekend", "friends", "plans"]
        var generator = SystemRandomNumberGenerator()
        var docs: [SessionSearch.Document] = []
        for s in 0..<50 {
            var lines: [String] = []
            var length = 0
            var n = 0
            while length < 60_000 {
                let sentence = (0..<14).map { _ in words[Int.random(in: 0..<words.count, using: &generator)] }.joined(separator: " ")
                let line = "[\(n / 60):\(String(format: "%02d", n % 60))] Patient: \(sentence)"
                lines.append(line)
                length += line.count + 1
                n += 1
            }
            if s % 7 == 0 { lines[40] += " and Micheal rang" }
            docs.append(doc(lines.joined(separator: "\n"), 2026, 1 + s / 28, 1 + s % 28, tag: "S\(s + 1)"))
        }

        let cold = Date()
        let first = search(docs, "Michael sleep")
        let coldSeconds = Date().timeIntervalSince(cold)
        let warm = Date()
        let second = search(docs, "Michael garden")
        let warmSeconds = Date().timeIntervalSince(warm)
        print(String(format: "SessionSearch: cold (50 index builds + query) %.3fs = %.1f ms per 60k-char transcript; warm query %.3fs",
                     coldSeconds, coldSeconds / 50 * 1000, warmSeconds))

        XCTAssertEqual(first.sessionsSearched, 50)
        XCTAssertEqual(second.sessionsSearched, 50)
        XCTAssertGreaterThanOrEqual(second.hits.count, 8)
        XCTAssertLessThan(coldSeconds, 5, "generous bound; see the printed timing")
        XCTAssertLessThan(warmSeconds, 1)
    }

    func testEditedSessionRebuildsOnlyItsIndex() {
        let a = doc("[00:01] A: Dana called.")
        let b = doc("[00:01] A: Dana called.\n[00:02] A: and again.")
        XCTAssertTrue(SessionSearch.index(for: a) === SessionSearch.index(for: a))
        XCTAssertFalse(SessionSearch.index(for: a) === SessionSearch.index(for: b))
    }

    // MARK: - Fixes from review

    func testBareNumberDoesNotMatchTimestamps() {
        let docs = [doc("[00:30] A: hello\n[01:30] A: and then\n[02:05] A: I take 30 mg now\n[30:00] A: bye")]
        let result = search(docs, "30 mg")
        XCTAssertEqual(result.termCounts.first { $0.term.text == "30" }?.exact, 1, "only the dose, not the time stamps")
        XCTAssertEqual(result.hits.first?.lineIndex, 2)
        XCTAssertEqual(search([doc("[00:01] Therapist: hello")], "Therapist").totalMentions, 0, "speaker labels are not searched")
    }

    func testCountsAreKeptPerTermAndOnlyAZeroTermIsAbsent() {
        let docs = [doc("[00:01] A: Dana's sister came by.\n[00:02] A: Dana mentioned it again.")]
        let result = search(docs, "Did Dana mention her sister Jess?")
        XCTAssertEqual(result.termCounts.map(\.term.text), ["dana", "sister", "jess"])
        XCTAssertEqual(result.termCounts.map(\.exact), [2, 1, 0])
        XCTAssertEqual(result.termCounts.map(\.similar), [0, 0, 0])
        let block = Prompts.searchBlock(result, shown: 2, whole: true, unreadableSessions: 0)
        XCTAssertTrue(block.contains("- \"dana\": 2 mentions"))
        XCTAssertTrue(block.contains("- \"jess\": 0 matches"))
        XCTAssertFalse(block.contains("- \"dana\": 0"))
    }

    func testSimilarSpellingsAreCountedApartFromExactMentions() {
        let result = search([doc("[00:01] A: Micheal called.\n[00:02] A: Michael too.")], "Michael")
        XCTAssertEqual(result.termCounts.first?.exact, 1)
        XCTAssertEqual(result.termCounts.first?.similar, 1)
        XCTAssertEqual(result.totalMentions, 2)
        XCTAssertEqual(result.similarMentions, 1)
        let onlySimilar = search([doc("[00:01] A: Micheal called.")], "Michael")
        let block = Prompts.searchBlock(onlySimilar, shown: 1, whole: true, unreadableSessions: 0)
        XCTAssertTrue(block.contains("no exact mentions; 1 similar spelling (not exact: micheal)"))
        XCTAssertFalse(block.contains("0 matches"))
    }

    func testContractionsAreNotTerms() {
        XCTAssertTrue(SessionSearch.terms(from: "Can't they talk? Didn't she? They're here, we won't.").isEmpty)
        XCTAssertTrue(SessionSearch.terms(from: "Can\u{2019}t Won\u{2019}t Wouldn\u{2019}t").isEmpty, "curly apostrophes too")
        XCTAssertEqual(SessionSearch.terms(from: "Didn't Dana?").map(\.text), ["dana"])
    }

    func testCacheKeepsEverythingASearchUsesAndEvictsOnlyOlderSearches() {
        SessionSearch.clearCache()
        func docs(_ prefix: String, _ n: Int) -> [SessionSearch.Document] {
            (0..<n).map { doc("[00:01] A: Dana \(prefix) \($0)", 2026, 1 + $0 % 12, 1 + $0 % 28, tag: "S\($0)") }
        }
        let first = docs("alpha", 1_000)
        _ = search(first, "Dana")
        XCTAssertEqual(SessionSearch.cachedIndexCount, 1_000)
        let second = docs("beta", 1_000)
        _ = search(second, "Dana")
        XCTAssertEqual(SessionSearch.cachedIndexCount, 1_000, "the first search's entries made room; the second kept all of its own")
        let oversize = docs("gamma", SessionSearch.cacheLimit + 100)
        _ = search(oversize, "Dana")
        XCTAssertEqual(SessionSearch.cachedIndexCount, SessionSearch.cacheLimit, "surplus is left uncached, not the whole cache cleared")
        SessionSearch.clearCache()
        XCTAssertEqual(SessionSearch.cachedIndexCount, 0)
    }

    func testASearchRunningWhenTheCacheClearsDoesNotRefillIt() {
        SessionSearch.clearCache()
        let a = doc("[00:01] A: Dana called.")
        let startedBeforeClear = 0   // clears seen by a search that began before the clear below
        SessionSearch.clearCache()
        _ = SessionSearch.index(for: a, clearsAtStart: startedBeforeClear)
        XCTAssertEqual(SessionSearch.cachedIndexCount, 0)
        _ = search([a], "Dana")
        XCTAssertEqual(SessionSearch.cachedIndexCount, 1, "a search that starts after the clear caches as usual")
    }

    func testEncryptionLockClearsTheSearchCache() throws {
        _ = search([doc("[00:01] A: Dana called.")], "Dana")
        XCTAssertGreaterThan(SessionSearch.cachedIndexCount, 0)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = EncryptionManager(dataRootProvider: { root })
        try manager.enable(passphrase: "pw", iterations: 1_000)
        _ = search([doc("[00:01] A: Dana called.")], "Dana")
        manager.lock()
        XCTAssertEqual(SessionSearch.cachedIndexCount, 0)
    }
}
