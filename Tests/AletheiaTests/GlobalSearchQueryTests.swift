import XCTest
@testable import Aletheia

/// The pure parts of global search: how a query is read, how words match
/// names, dates and text, ranking, snippets, coverage and limits.
final class GlobalSearchQueryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    // MARK: Query words

    func testWordsAreFoldedDeduplicatedAndCapped() {
        let query = GlobalSearchQuery("Couples THERAPY, couples")
        XCTAssertEqual(query.words, ["couples", "therapy"])
        XCTAssertEqual(query.required, ["couples", "therapy"])
        XCTAssertEqual(query.textTerms.map(\.word), ["couples", "therapy"])

        XCTAssertEqual(GlobalSearchQuery("Dana's dana").words, ["dana"])
        XCTAssertEqual(GlobalSearchQuery("José").words, ["jose"])
        let many = GlobalSearchQuery("one1 two2 three3 four4 five5 six6 seven7 eight8 nine9 ten10")
        XCTAssertEqual(many.words.count, GlobalSearchQuery.maximumWords)
        XCTAssertEqual(many.words.last, "eight8")
    }

    func testEveryWordIsLookedUpInTextHoweverCommonOrShort() {
        let query = GlobalSearchQuery("the therapist I s")
        XCTAssertEqual(query.required, ["the", "therapist", "i", "s"])
        XCTAssertEqual(query.textTerms.map(\.word), ["the", "therapist", "i", "s"])

        XCTAssertEqual(GlobalSearchQuery("8").textTerms.map(\.word), ["8"])
        XCTAssertTrue(GlobalSearchQuery("  ,. ").isEmpty)
    }

    func testTermsMatchStemsAndTheStartOfWords() {
        let worries = GlobalSearchTerm(raw: "worries")
        XCTAssertEqual(worries.stem, "worry")
        XCTAssertEqual(worries.clause, "\"worry\" OR \"worries\" *")
        XCTAssertTrue(worries.matches(indexed: "worry"), "worried and worrying are stored as worry")
        XCTAssertFalse(worries.matches(indexed: "work"))

        let typing = GlobalSearchTerm(raw: "thera")
        XCTAssertEqual(typing.clause, "\"thera\" *")
        XCTAssertTrue(typing.matches(indexed: "therapy"))
        XCTAssertFalse(typing.matches(indexed: "thermal"))

        let digit = GlobalSearchTerm(raw: "8")
        XCTAssertFalse(digit.matchesPrefixes)
        XCTAssertEqual(digit.clause, "\"8\"")
        XCTAssertTrue(digit.matches(indexed: "8"))
        XCTAssertFalse(digit.matches(indexed: "80"))

        let letter = GlobalSearchTerm(raw: "i")
        XCTAssertEqual(letter.clause, "\"i\"", "a single letter is a whole word, not the start of most of the index")
        XCTAssertFalse(letter.matches(indexed: "if"))
    }

    // MARK: Names and dates

    func testPatientsMatchEveryRequiredWordAnywhereInTheName() {
        let name = GlobalSearchQuery.nameForm("Joanne O'Brien")
        XCTAssertEqual(name, "joanne obrien")
        XCTAssertTrue(GlobalSearchQuery("ann").matchesPatient(nameForm: name))
        XCTAssertTrue(GlobalSearchQuery("o'brien jo").matchesPatient(nameForm: name))
        XCTAssertFalse(GlobalSearchQuery("joanne smith").matchesPatient(nameForm: name))
        XCTAssertFalse(GlobalSearchQuery("the obrien").matchesPatient(nameForm: name), "every word is required, common ones too")
    }

    func testDatesAnswerToDayMonthAndYear() {
        let october = GlobalSearchDate(date(2026, 10, 8), calendar: calendar)
        XCTAssertEqual(october.numbers, [8, 10, 2026, 26])
        XCTAssertEqual(october.monthNames, ["october", "oct"])
        for word in ["oct", "octo", "october", "8", "08", "10", "2026", "26"] {
            XCTAssertTrue(october.matches(word), word)
        }
        for word in ["oc", "nov", "9", "2025", "o"] {
            XCTAssertFalse(october.matches(word), word)
        }
    }

    func testSessionsMatchByDateAndPatientName() {
        let day = GlobalSearchDate(date(2026, 10, 8), calendar: calendar)
        let jane = GlobalSearchQuery.nameForm("Jane Doe")
        XCTAssertTrue(GlobalSearchQuery("oct 8").matchesSession(date: day, nameForm: jane))
        XCTAssertTrue(GlobalSearchQuery("2026-10-08").matchesSession(date: day, nameForm: jane))
        XCTAssertTrue(GlobalSearchQuery("jane october").matchesSession(date: day, nameForm: jane))
        XCTAssertFalse(GlobalSearchQuery("jane").matchesSession(date: day, nameForm: jane), "a name alone is a patient, not a session")
        XCTAssertFalse(GlobalSearchQuery("oct 9").matchesSession(date: day, nameForm: jane))
        XCTAssertFalse(GlobalSearchQuery("bob oct").matchesSession(date: day, nameForm: jane))
    }

    func testNameAndDateAnswerTextTerms() {
        let day = GlobalSearchDate(date(2026, 3, 3), calendar: calendar)
        let bob = GlobalSearchQuery.nameForm("Bob Lee")
        XCTAssertEqual(GlobalSearchQuery("insomnia march 2026").termsAnsweredBy(date: day, nameForm: bob), 0b110)
        XCTAssertEqual(GlobalSearchQuery("bob insomnia").termsAnsweredBy(date: day, nameForm: bob), 0b01)
        XCTAssertEqual(GlobalSearchQuery("insomnia").termsAnsweredBy(date: day, nameForm: bob), 0)
    }

    func testEverydayMonthWordsAreDatesOnlyNextToADayOrYear() {
        let may = GlobalSearchDate(date(2026, 5, 5), calendar: calendar)
        let march = GlobalSearchDate(date(2026, 3, 3), calendar: calendar)
        let jane = GlobalSearchQuery.nameForm("Jane Doe")
        XCTAssertFalse(GlobalSearchQuery("may").matchesSession(date: may, nameForm: jane), "\"she may\" is not a date")
        XCTAssertTrue(GlobalSearchQuery("may 5").matchesSession(date: may, nameForm: jane))
        XCTAssertTrue(GlobalSearchQuery("may 2026").matchesSession(date: may, nameForm: jane))
        XCTAssertFalse(GlobalSearchQuery("may 6").matchesSession(date: may, nameForm: jane))
        XCTAssertEqual(GlobalSearchQuery("insomnia march").termsAnsweredBy(date: march, nameForm: jane), 0)
        XCTAssertEqual(GlobalSearchQuery("insomnia mar 3").termsAnsweredBy(date: march, nameForm: jane), 0b110)
        XCTAssertTrue(GlobalSearchQuery("october").matchesSession(date: GlobalSearchDate(date(2026, 10, 8), calendar: calendar), nameForm: jane),
                      "other month names need nothing more")
    }

    // MARK: Text

    func testMaskAndBestPassageMatchTheWayTheIndexDoes() {
        let terms = GlobalSearchQuery("worries sleep").textTerms
        XCTAssertEqual(GlobalSearchText.mask(of: "She worried about sleep.", terms: terms), 0b11)
        XCTAssertEqual(GlobalSearchText.mask(of: "Nothing here.", terms: terms), 0)
        XCTAssertEqual(GlobalSearchText.bestPassage(["nothing", "worried", "worried about sleep"], terms: terms, answered: 0), 2)
        XCTAssertNil(GlobalSearchText.bestPassage(["worried"], terms: terms, answered: 0), "every word must be somewhere")
        XCTAssertEqual(GlobalSearchText.bestPassage(["worried"], terms: terms, answered: 0b10), 0, "or answered by the name or date")
        XCTAssertNil(GlobalSearchText.bestPassage(["nothing"], terms: terms, answered: 0b11), "at least one word is in the text")
    }

    func testParagraphsSplitOnBlankLines() {
        XCTAssertEqual(GlobalSearchText.paragraphs("A\nB\n\nC\n   \nD"), ["A B", "C", "D"])
        XCTAssertEqual(GlobalSearchText.paragraphs(""), [])
    }

    func testSnippetCentresOnTheFirstMatchingWord() {
        let terms = GlobalSearchQuery("insomnia").textTerms
        let long = String(repeating: "word ", count: 40) + "Insomnia again" + String(repeating: " tail", count: 40)
        let cut = GlobalSearchText.snippet(long, terms: terms)
        XCTAssertTrue(cut.hasPrefix("\u{2026}"))
        XCTAssertTrue(cut.hasSuffix("\u{2026}"))
        XCTAssertTrue(cut.contains("Insomnia"))
        XCTAssertLessThan(cut.count, 170)
        XCTAssertEqual(GlobalSearchText.snippet("Insomnia is better", terms: terms), "Insomnia is better")
        XCTAssertEqual(GlobalSearchText.snippet("line one\nInsomnia", terms: terms), "line one Insomnia")
    }

    func testWordRangesFindInflectedAndPartlyTypedWords() {
        let text = "Worried, she slept. Therapy helped."
        let ranges = GlobalSearchText.wordRanges(in: text, terms: GlobalSearchQuery("worries thera").textTerms)
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["Worried", "Therapy"])
    }

    /// The index leaves out "[00:01] You:", so a match there would mark who
    /// spoke instead of what was said.
    func testWordRangesSkipTranscriptSpeakerLabels() {
        let text = "[00:01] You: you said so.\n[00:04] Patient: the patient left."
        let ranges = GlobalSearchText.wordRanges(in: text, terms: GlobalSearchQuery("you patient").textTerms)
        XCTAssertEqual(ranges.map { text.distance(from: text.startIndex, to: $0.lowerBound) }, [13, 47])
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["you", "patient"])
    }

    // MARK: Ranking

    private func doc(_ id: Int64, session: String, date: Double) -> SearchIndex.LiveDocument {
        SearchIndex.LiveDocument(id: id, session: session, patient: "p", kind: "transcript", date: date, fingerprint: "f\(id)")
    }

    private func match(_ doc: Int64, _ line: Int, _ score: Double) -> SearchIndex.MatchedPassage {
        SearchIndex.MatchedPassage(doc: doc, line: line, score: score)
    }

    func testRankingNeedsEveryWordAndPutsTheBestPlaceFirst() {
        let documents: [Int64: SearchIndex.LiveDocument] = [
            1: doc(1, session: "A", date: 100), 2: doc(2, session: "B", date: 200), 3: doc(3, session: "C", date: 300),
            4: doc(4, session: "D", date: 400), 5: doc(5, session: "E", date: 500),
        ]
        let garden = [match(1, 4, 2), match(2, 1, 1), match(3, 0, 1), match(4, 0, 9), match(5, 0, 9)]
        let lake = [match(1, 4, 3), match(2, 7, 1), match(5, 0, 9)]
        let ranked = GlobalSearchRanking.rank(passages: [garden, lake], documents: documents) { document in
            switch document.session {
            case "C": return 0b10   // its patient's name or date answers "lake"
            case "E": return nil    // its session is gone
            default: return 0
            }
        }
        XCTAssertEqual(ranked.map(\.doc), [1, 2, 3], "4 lacks a word; 5's session is gone")
        XCTAssertEqual(ranked[0], GlobalSearchRanking.Ranked(doc: 1, line: 4, score: 5, passages: 1))
        XCTAssertEqual(ranked[1].line, 1, "equal passages: the first line")
        XCTAssertEqual(ranked[1].passages, 2)
        XCTAssertEqual(ranked[2].line, 0)
    }

    func testRankingIsTheSameWhateverOrderMatchesArriveIn() {
        var documents: [Int64: SearchIndex.LiveDocument] = [:]
        var garden: [SearchIndex.MatchedPassage] = []
        for i in 1...40 {
            let id = Int64(i)
            documents[id] = doc(id, session: "S\(i % 7)", date: Double(i % 5))
            garden.append(match(id, i % 3, Double(i % 4)))
            garden.append(match(id, 10 + i % 2, Double(i % 6)))
        }
        let first = GlobalSearchRanking.rank(passages: [garden], documents: documents) { _ in 0 }
        let again = GlobalSearchRanking.rank(passages: [Array(garden.reversed())], documents: documents) { _ in 0 }
        XCTAssertEqual(first, again)
        XCTAssertEqual(first.count, 40)
        for (a, b) in zip(first, first.dropFirst()) {
            XCTAssertTrue(GlobalSearchRanking.precedes(a, b, documents))
        }
    }

    func testRankingTiesGoToTheNewerSession() {
        let documents: [Int64: SearchIndex.LiveDocument] = [1: doc(1, session: "A", date: 100), 2: doc(2, session: "B", date: 200)]
        let ranked = GlobalSearchRanking.rank(passages: [[match(1, 0, 1), match(2, 0, 1)]], documents: documents) { _ in 0 }
        XCTAssertEqual(ranked.map(\.doc), [2, 1])
    }

    // MARK: Coverage, limits, staleness

    func testCoverageSaysWhenResultsMayBeIncomplete() {
        XCTAssertEqual(GlobalSearchCoverage(.init(checked: false, pendingSessions: 0)), .checking)
        XCTAssertEqual(GlobalSearchCoverage(.init(checked: true, pendingSessions: 12)), .indexing(sessions: 12))
        XCTAssertEqual(GlobalSearchCoverage(.init(checked: true, pendingSessions: 0)), .complete)
        XCTAssertEqual(GlobalSearchCoverage.indexing(sessions: 12).statusText, "Indexing 12 sessions; results may be incomplete.")
        XCTAssertEqual(GlobalSearchCoverage.indexing(sessions: 1).statusText, "Indexing 1 session; results may be incomplete.")
        XCTAssertEqual(GlobalSearchCoverage.checking.statusText, "Checking the search index; results may be incomplete.")
        XCTAssertNil(GlobalSearchCoverage.complete.statusText)
        XCTAssertNil(GlobalSearchCoverage.scanned.statusText)
        XCTAssertTrue(GlobalSearchCoverage.scanned.isComplete)
        XCTAssertFalse(GlobalSearchCoverage.checking.isComplete)
    }

    func testLimitsGrowByAStepUpToTheMaximum() {
        var limits = GlobalSearchLimits()
        XCTAssertEqual(limits.limit(for: .transcript), 5)
        XCTAssertTrue(limits.showMore(of: .transcript))
        XCTAssertEqual(limits.limit(for: .transcript), 30)
        XCTAssertEqual(limits.limit(for: .note), 5, "each group grows on its own")
        while limits.showMore(of: .transcript) {}
        XCTAssertEqual(limits.limit(for: .transcript), GlobalSearchLimits.maximum)
        XCTAssertEqual(GlobalSearchLimits(defaultLimit: 1_000).limit(for: .comment), GlobalSearchLimits.maximum)
    }

    func testTranscriptStampsDecideWhatIsReindexed() {
        XCTAssertEqual(SearchIndexStaleness.stamp(exists: false, modified: nil, size: nil), SearchIndexStaleness.noTranscript)
        XCTAssertNil(SearchIndexStaleness.stamp(exists: true, modified: nil, size: 3))
        XCTAssertEqual(SearchIndexStaleness.stamp(exists: true, modified: Date(timeIntervalSinceReferenceDate: 10), size: 3), "10.0-3")
        XCTAssertTrue(SearchIndexStaleness.needsIndexing(current: nil, stored: "x"), "can't tell: index it")
        XCTAssertTrue(SearchIndexStaleness.needsIndexing(current: "a", stored: nil), "never indexed")
        XCTAssertTrue(SearchIndexStaleness.needsIndexing(current: "b", stored: "a"), "changed")
        XCTAssertFalse(SearchIndexStaleness.needsIndexing(current: "a", stored: "a"))
        XCTAssertFalse(SearchIndexStaleness.needsIndexing(current: "none", stored: "none"), "a notes-only session indexed once")
    }

    func testStaleSessionsAreIndexedFirstNewestFirst() {
        let patient = Patient(name: "Jane Doe", slug: "Jane-Doe")
        func target(_ day: Int, stale: Bool) -> Store.SearchIndexTarget {
            Store.SearchIndexTarget(
                patient: patient,
                session: SessionRecord(patientId: patient.id, date: date(2026, 1, day), folderName: "s\(day)"),
                transcriptStale: stale)
        }
        let ordered = SearchIndexStaleness.order([target(1, stale: true), target(2, stale: false), target(3, stale: true), target(4, stale: false)])
        XCTAssertEqual(ordered.map { calendar.component(.day, from: $0.session.date) }, [3, 1, 4, 2])
    }

    func testProgressCountsEachPendingSessionOnce() {
        let progress = SearchIndexProgress()
        var changes = 0
        progress.onChange { changes += 1 }
        XCTAssertEqual(progress.snapshot(), .init(checked: false, pendingSessions: 0))
        progress.checked(stale: ["a", "b"])
        XCTAssertEqual(progress.snapshot(), .init(checked: true, pendingSessions: 2))
        progress.beginWrite(session: "c")
        progress.beginWrite(session: "a")
        XCTAssertEqual(progress.snapshot().pendingSessions, 3, "a is counted once")
        progress.indexed(session: "a")
        XCTAssertEqual(progress.snapshot().pendingSessions, 3, "a's save is still queued")
        progress.endWrite(session: "a")
        progress.endWrite(session: "c")
        progress.endWrite(session: "unknown")
        XCTAssertEqual(progress.snapshot().pendingSessions, 1)
        progress.forget(sessions: ["b"])
        XCTAssertEqual(progress.snapshot(), .init(checked: true, pendingSessions: 0))
        progress.invalidate()
        XCTAssertEqual(progress.snapshot(), .init(checked: false, pendingSessions: 0))
        XCTAssertEqual(changes, 9, "every call reports a change")
    }

    func testActivityIsBusyWhileAnyReasonIsOn() {
        let activity = SearchIndexActivity()
        XCTAssertFalse(activity.isBusy)
        activity.set(.recording, active: true)
        activity.set(.model, active: true)
        activity.set(.recording, active: false)
        XCTAssertTrue(activity.isBusy)
        activity.set(.model, active: false)
        XCTAssertFalse(activity.isBusy)
    }

    func testMonitorFoldsABurstOfChangesIntoOneUpdate() {
        let monitor = SearchIndexMonitor()
        monitor.noteChange()
        monitor.noteChange()
        monitor.noteChange()
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
        XCTAssertEqual(monitor.revision, 1)
        monitor.noteChange()
        let again = expectation(description: "main queue drained again")
        DispatchQueue.main.async { again.fulfill() }
        wait(for: [again], timeout: 5)
        XCTAssertEqual(monitor.revision, 2)
    }

    func testSessionRowsSayWhatTheSessionHolds() {
        let patient = UUID()
        XCTAssertEqual(GlobalSearchEngine.contents(of: SessionRecord(patientId: patient, folderName: "a")), "Nothing recorded yet")
        XCTAssertEqual(
            GlobalSearchEngine.contents(of: SessionRecord(patientId: patient, folderName: "a", hasRecording: true)), "Recording")
        XCTAssertEqual(
            GlobalSearchEngine.contents(of: SessionRecord(patientId: patient, folderName: "a", hasRecording: true, hasTranscript: true, hasSummary: true)),
            "Transcript \u{00B7} Progress note")
    }

    func testResolvedCommentsBecomeOneDocument() {
        let now = Date()
        let comments = [
            SessionComment(id: "1", quotedText: "", body: "open one", createdAt: now, updatedAt: now),
            SessionComment(id: "2", quotedText: " the quote ", body: "closed one", createdAt: now, updatedAt: now, resolved: true),
            SessionComment(id: "3", quotedText: "", body: "closed two", createdAt: now, updatedAt: now, resolved: true),
        ]
        XCTAssertEqual(Store.resolvedCommentsText(comments), "Resolved margin comments:\n- On \u{201C}the quote\u{201D}: closed one\n- closed two")
        XCTAssertNil(Store.resolvedCommentsText([comments[0]]))
    }
}
