import XCTest
@testable import Aletheia

/// The layered plan for a patient history too long to send whole, its progress
/// steps, the effort levels' numbers, and the coverage and citation bookkeeping
/// around follow-up lookups. Pure: no store, no model.
final class HistoryRetrievalTests: XCTestCase {
    private let tenMinuteSections: [SessionDigest.Section] = [
        .init(start: 0, end: 590, digest: "Sleep and work stress."),
        .init(start: 600, end: 1190, digest: "Her sister Dana asked to borrow money."),
        .init(start: 1200, end: 1790, digest: "Breathing exercise; plan for next week."),
    ]

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: - Mapping hits to sections

    func testAHitFallsInTheLastSectionStartingAtOrBeforeIt() {
        XCTAssertEqual(HistoryRetrieval.sectionIndex(forSeconds: 0, in: tenMinuteSections), 0)
        XCTAssertEqual(HistoryRetrieval.sectionIndex(forSeconds: 599, in: tenMinuteSections), 0)
        XCTAssertEqual(HistoryRetrieval.sectionIndex(forSeconds: 600, in: tenMinuteSections), 1)
        XCTAssertEqual(HistoryRetrieval.sectionIndex(forSeconds: 5_000, in: tenMinuteSections), 2)
        let untimed: [SessionDigest.Section] = [.init(start: nil, end: nil, digest: "x")]
        XCTAssertNil(HistoryRetrieval.sectionIndex(forSeconds: 30, in: untimed))
        XCTAssertNil(HistoryRetrieval.sectionIndex(forSeconds: 30, in: []))
    }

    func testSummaryWordsMatchByStem() {
        let stems = HistoryRetrieval.stems(of: SessionSearch.terms(from: "What did Dana borrow?"))
        XCTAssertEqual(HistoryRetrieval.matches(of: stems, in: "Her sister Dana asked to borrow money."), 2)
        XCTAssertEqual(HistoryRetrieval.matches(of: stems, in: "Sleep and work stress."), 0)
        XCTAssertEqual(HistoryRetrieval.matches(of: [], in: "Dana"), 0)
    }

    // MARK: - Ranking and picking

    func testRankingPutsSpokenHitsFirstThenSummaryWordsThenNewerSessions() {
        let newer = HistoryRetrieval.Session(date: date(2026, 3, 1), sections: tenMinuteSections, hitSeconds: [])
        let older = HistoryRetrieval.Session(date: date(2026, 1, 1), sections: tenMinuteSections, hitSeconds: [1_250, nil])
        let stems = HistoryRetrieval.stems(of: SessionSearch.terms(from: "Dana"))
        let ranked = HistoryRetrieval.rank([newer, older], stems: stems)

        // The older session's hit at 20:50 (section 3) outranks the summary word "Dana" (section 2).
        XCTAssertEqual(ranked.map { [$0.session, $0.section] }, [[1, 2], [0, 1], [1, 1]])
        XCTAssertEqual(ranked.first?.transcriptHits, 1)
        XCTAssertEqual(ranked.first?.summaryMatches, 0)
        XCTAssertTrue(ranked.allSatisfy { $0.score > 0 }, "a section nothing points at is not a candidate")
    }

    func testSectionsAreShownWhileTheyFitAndSkippedNotCut() {
        let ranked = [
            HistoryRetrieval.Candidate(session: 0, section: 0, transcriptHits: 2, summaryMatches: 0),
            HistoryRetrieval.Candidate(session: 0, section: 1, transcriptHits: 1, summaryMatches: 0),
            HistoryRetrieval.Candidate(session: 1, section: 0, transcriptHits: 0, summaryMatches: 1),
        ]
        let shown = HistoryRetrieval.sectionsToShow(ranked, budget: 250) { $0.section == 1 ? 200 : 100 }
        XCTAssertEqual(shown, [ranked[0], ranked[2]])
    }

    func testTranscriptSectionsOpenOnlyWhereASpokenHitFallsAndWithinTheLimit() {
        let ranked = (0..<6).map {
            HistoryRetrieval.Candidate(session: $0, section: 0, transcriptHits: $0 == 1 ? 0 : 1, summaryMatches: 3)
        }
        let opened = HistoryRetrieval.sectionsToOpen(ranked, budget: 10_000) { $0.session == 2 ? nil : 1_000 }
        // Session 1 has only summary words; session 2's section can't be opened; then the limit of 3.
        XCTAssertEqual(opened.map(\.session), [0, 3, 4])
        XCTAssertEqual(HistoryRetrieval.maxOpenedSections, 3)
        XCTAssertEqual(HistoryRetrieval.sectionsToOpen(ranked, budget: 1_500) { _ in 1_000 }.map(\.session), [0])
    }

    func testSharesLeaveAFifthForSearchPassages() {
        let shares = HistoryRetrieval.Shares(room: 50_000)
        XCTAssertEqual(shares.summaries, 22_500)
        XCTAssertEqual(shares.sections, 7_500)
        XCTAssertEqual(shares.opened, 10_000)
        XCTAssertEqual(HistoryRetrieval.Shares(room: -5), HistoryRetrieval.Shares(room: 0))
    }

    func testSpanNamesFirstAndLastDate() {
        let f = DateFormatter()
        f.dateStyle = .medium
        XCTAssertNil(HistoryRetrieval.span([], formatter: f))
        XCTAssertEqual(HistoryRetrieval.span([date(2026, 3, 1)], formatter: f), f.string(from: date(2026, 3, 1)))
        XCTAssertEqual(
            HistoryRetrieval.span([date(2026, 3, 1), date(2025, 1, 2), date(2025, 6, 1)], formatter: f),
            "\(f.string(from: date(2025, 1, 2))) – \(f.string(from: date(2026, 3, 1)))")
    }

    // MARK: - Progress steps

    func testStepsListWhatWasDoneThenLookupsThenTheAnswer() {
        var coverage = TranscriptCoverage(transcriptSessions: 100, sessionsWithPassages: 4)
        coverage.digestSessions = 6
        coverage.openedSections = 3
        let steps = HistoryAnswerSteps(coverage: coverage, looksUp: true)
        XCTAssertEqual(steps.finished, [
            "Searched 100 sessions", "Read summaries of 6 sessions", "Opened 3 transcript sections", "Found passages in 4 sessions",
        ])
        XCTAssertEqual(steps.total, 6)
        XCTAssertEqual(steps.atStart, AIRunSteps(done: 4, total: 6))
        XCTAssertEqual(steps.afterLookups, AIRunSteps(done: 5, total: 6))
        XCTAssertLessThan(steps.afterLookups.fraction, 1, "never full before the answer is written")

        let fast = HistoryAnswerSteps(coverage: TranscriptCoverage(transcriptSessions: 1), looksUp: false)
        XCTAssertEqual(fast.finished, ["Searched 1 session"])
        XCTAssertEqual(fast.atStart, fast.afterLookups)
        XCTAssertEqual(fast.total, 2)
    }

    // MARK: - Effort levels

    /// The table in the PR: what each level does, pinned.
    func testEffortLevelsDoWhatTheirBlurbsSay() {
        XCTAssertEqual(AnswerEffort.fast.maxToolCalls, 0)
        XCTAssertEqual(AnswerEffort.normal.maxToolCalls, 4)
        XCTAssertEqual(AnswerEffort.focus.maxToolCalls, 10)
        XCTAssertTrue(AnswerEffort.fast.blurb.contains("no follow-up lookups"))
        XCTAssertTrue(AnswerEffort.normal.blurb.contains("up to \(AnswerEffort.normal.maxToolCalls) follow-up lookups"))
        XCTAssertTrue(AnswerEffort.focus.blurb.contains("up to \(AnswerEffort.focus.maxToolCalls) follow-up lookups in two rounds"))
        XCTAssertEqual(AnswerEffort.focus.maxRefinementRounds, 2)
        for level in AnswerEffort.allCases {
            XCTAssertTrue(level.blurb.contains("Short sessions are read in full") || level == .focus, level.rawValue)
            XCTAssertFalse(level.blurb.contains("checks its draft"), "no level checks a chat answer")
        }
        XCTAssertTrue(AnswerEffort.focus.blurb.contains("note is also checked against the transcript"))
    }

    func testFocusGetsMoreLookupRoomThanNormal() {
        for budget in [20_000, 80_000, 170_000] {
            XCTAssertEqual(AnswerEffort.fast.patientLookupReserve(budget: budget), 0)
            XCTAssertGreaterThan(
                AnswerEffort.focus.patientLookupReserve(budget: budget), AnswerEffort.normal.patientLookupReserve(budget: budget))
            XCTAssertEqual(AnswerEffort.fast.sessionLookupReserve(total: budget), 0)
            XCTAssertGreaterThan(
                AnswerEffort.focus.sessionLookupReserve(total: budget), AnswerEffort.normal.sessionLookupReserve(total: budget))
        }
        XCTAssertEqual(AnswerEffort.normal.patientLookupReserve(budget: 80_000), 4_800)
        XCTAssertEqual(AnswerEffort.focus.patientLookupReserve(budget: 80_000), 9_600)
        XCTAssertEqual(AnswerEffort.normal.sessionLookupReserve(total: 30_000), 3_600)
        XCTAssertEqual(AnswerEffort.focus.sessionLookupReserve(total: 30_000), 7_200)
    }

    func testEachLookupGetsItsShareOfTheReserve() {
        XCTAssertEqual(AnswerEffort.fast.lookupCharacters(reserve: 9_600), 0)
        XCTAssertEqual(AnswerEffort.normal.lookupCharacters(reserve: 4_800), 1_200)
        XCTAssertEqual(AnswerEffort.focus.lookupCharacters(reserve: 9_600), 960)
        XCTAssertEqual(AnswerEffort.focus.lookupCharacters(reserve: 1_000), 600, "never below the floor")
        XCTAssertEqual(AnswerEffort.normal.lookupCharacters(reserve: 50_000), 2_400, "never above the cap")
        // All of Focus's lookups fit its reserve; at Normal's they would not.
        XCTAssertLessThanOrEqual(
            AnswerEffort.focus.lookupCharacters(reserve: 9_600) * AnswerEffort.focus.maxToolCalls,
            AnswerEffort.focus.patientLookupReserve(budget: 80_000))
    }

    // MARK: - Coverage and citations after lookups

    func testLookupsCountEachSessionOnce() {
        var coverage = TranscriptCoverage(transcriptSessions: 5, sessionsWithPassages: 2)
        coverage.passageTags = ["S1", "S2"]
        coverage.digestSessions = 1
        coverage.summaryTags = ["S1"]

        coverage.addLookups(transcriptTags: ["S1", "S3"], digestTags: ["S1"])
        XCTAssertEqual(coverage.sessionsWithPassages, 3, "S1 was already read; S3 is new")
        XCTAssertEqual(coverage.digestSessions, 1)

        coverage.addLookups(transcriptTags: ["S3"], digestTags: ["S4", "S5"])
        XCTAssertEqual(coverage.sessionsWithPassages, 3)
        XCTAssertEqual(coverage.digestSessions, 3)
    }

    func testLayeredCoverageSaysWhatWasSummarizedOpenedAndSearchOnly() {
        var coverage = TranscriptCoverage(transcriptSessions: 100, sessionsWithPassages: 4, searched: true)
        coverage.mentions = 7
        coverage.layered = true
        coverage.digestSessions = 30
        coverage.monthMergedSessions = 24
        coverage.summarySpan = "Jan 2, 2025 – Oct 8, 2026"
        coverage.summarySections = 2
        coverage.openedSections = 1
        coverage.openedSpan = "Mar 5, 2026"
        coverage.searchOnlySessions = 69
        coverage.noSummarySessions = 12
        coverage.searchOnlySpan = "Feb 1, 2023 – Dec 20, 2024"
        XCTAssertEqual(
            coverage.label,
            "Read: summaries of 30 sessions (24 merged by month), Jan 2, 2025 – Oct 8, 2026 · 2 matching summary sections"
                + " · 1 transcript section in full, Mar 5, 2026 · transcript passages from 4 of 100 sessions (7 matches for your words)"
                + " · search only for 69 sessions, Feb 1, 2023 – Dec 20, 2024 (12 with no summary yet)")
    }

    func testALookedUpSessionJoinsTheSourcesInDateOrder() {
        let s1 = CitationSource(tag: "S1", date: date(2026, 3, 1), folderName: "a")
        let s2 = CitationSource(tag: "S2", date: date(2026, 2, 1), folderName: "b")
        let s40 = CitationSource(tag: "S40", date: date(2023, 5, 1), folderName: "c")
        XCTAssertEqual(Citations.merged([s1, s40], adding: [s2, s1]), [s1, s2, s40])

        let shown = Citations.decorate(answer: "Money came up long ago [S40].", sources: Citations.merged([s1], adding: [s40]))
        XCTAssertFalse(shown.contains("[S40]"), "a looked-up session's tag renders as its date")
        XCTAssertTrue(shown.contains("Sources: "))
    }
}
