import XCTest
@testable import Aletheia

/// The pure pieces of the patient chat's zoom levels: where a hit falls, how
/// parts are ranked and listed, the per-Mac caps, and the progress steps.
final class PatientZoomTests: XCTestCase {
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func hit(_ session: UUID, tag: String, seconds: Int?, line: Int = 0) -> SessionSearch.Hit {
        SessionSearch.Hit(
            documentIndex: 0, date: date(2026, 1, 1), tag: tag, kind: .transcript, seconds: seconds,
            lineIndex: line, line: "", context: [], contextStart: line, score: 1, sessionID: session
        )
    }

    private func digest(_ parts: [(Int?, Int?, String)]) -> SessionDigest {
        SessionDigest(
            model: "m", promptVersion: Prompts.digestVersion, transcriptFingerprint: "fp",
            sections: parts.map { SessionDigest.Section(start: $0.0, end: $0.1, digest: $0.2) },
            sessionDigest: "whole", createdAt: Date()
        )
    }

    func testAHitFallsInThePartItsTimeIsIn() {
        let starts: [Int?] = [0, 600, 1200]
        XCTAssertEqual(PatientZoom.partIndex(forSeconds: 0, starts: starts), 0)
        XCTAssertEqual(PatientZoom.partIndex(forSeconds: 599, starts: starts), 0)
        XCTAssertEqual(PatientZoom.partIndex(forSeconds: 600, starts: starts), 1)
        XCTAssertEqual(PatientZoom.partIndex(forSeconds: 5_000, starts: starts), 2)
        XCTAssertEqual(PatientZoom.partIndex(forSeconds: 5, starts: [10, 600]), 0, "before the first start: the first part")
        XCTAssertNil(PatientZoom.partIndex(forSeconds: 5, starts: [nil, nil]), "untimed parts are placed by line")
        XCTAssertEqual(PatientZoom.partIndex(forLine: 0, lineCount: 100, parts: 4), 0)
        XCTAssertEqual(PatientZoom.partIndex(forLine: 99, lineCount: 100, parts: 4), 3)
        XCTAssertEqual(PatientZoom.partIndex(forLine: 50, lineCount: 100, parts: 4), 2)
    }

    func testAreasRankSpokenHitsAboveSummaryWordsThenNewerSessions() {
        let older = UUID(), newer = UUID(), noDigest = UUID()
        let sessions = [
            PatientZoom.SessionInput(
                tag: "S1", date: date(2026, 3, 1), sessionID: newer,
                digest: digest([(0, 590, "Small talk."), (600, 1190, "Talked about kayaking plans.")]),
                parts: [], lineCount: 100),
            PatientZoom.SessionInput(
                tag: "S2", date: date(2026, 2, 1), sessionID: older,
                digest: digest([(0, 590, "Kayaking again."), (600, 1190, "Work.")]),
                parts: [], lineCount: 100),
            PatientZoom.SessionInput(
                tag: "S3", date: date(2026, 1, 1), sessionID: noDigest, digest: nil,
                parts: [TranscriptSection(start: 0, end: 590, text: ""), TranscriptSection(start: 600, end: 1100, text: "")],
                lineCount: 100),
        ]
        let hits = [hit(noDigest, tag: "S3", seconds: 700), hit(noDigest, tag: "S3", seconds: 800)]
        let areas = PatientZoom.areas(sessions: sessions, hits: hits, stems: PatientZoom.stems(of: SessionSearch.terms(from: "kayaking")))

        XCTAssertEqual(areas.map(\.tag), ["S3", "S1", "S2"])
        XCTAssertEqual(areas[0].index, 1)
        XCTAssertEqual(areas[0].transcriptHits, 2)
        XCTAssertNil(areas[0].summary)
        XCTAssertEqual(areas[1].summaryMatches, 1)
        XCTAssertEqual(areas[1].summary, "Talked about kayaking plans.")
        XCTAssertEqual(areas[2].index, 0, "a tie goes to the newer session first")
    }

    func testAnAreaSaysWhyAndHowToOpenIt() {
        let timed = PatientZoom.Area(
            tag: "S4", date: date(2026, 3, 5), sessionID: UUID(), index: 2, count: 6, start: 1200, end: 1740,
            transcriptHits: 3, summaryMatches: 1, summary: "x")
        let line = PatientZoom.areaLine(timed)
        XCTAssertTrue(line.hasPrefix("- [S4] "), line)
        XCTAssertTrue(line.contains("Mar 5, 2026 [20:00–29:00]: 3 matching transcript lines, its summary has 1 of your words"), line)
        XCTAssertTrue(line.hasSuffix("(read_section session S4, start 20:00, end 29:00)"), line)

        // Untimed: read_section reads part k as the ten minutes from k × 10:00.
        let untimed = PatientZoom.Area(
            tag: "S9", date: date(2026, 3, 5), sessionID: UUID(), index: 1, count: 3, start: nil, end: nil,
            transcriptHits: 1, summaryMatches: 0, summary: nil)
        let untimedLine = PatientZoom.areaLine(untimed)
        XCTAssertTrue(untimedLine.contains("[part 2 of 3]: 1 matching transcript line, no summary yet"), untimedLine)
        XCTAssertTrue(untimedLine.hasSuffix("(read_section session S9, start 10:00, end 19:59)"), untimedLine)
    }

    func testTheAreasListKeepsToItsBudgetAndCap() {
        let many = (0..<20).map { i in
            PatientZoom.Area(
                tag: "S\(i + 1)", date: date(2026, 1, 1), sessionID: UUID(), index: 0, count: 1, start: 0, end: 60,
                transcriptHits: 1, summaryMatches: 0, summary: nil)
        }
        let all = PatientZoom.areasBlock(many, budget: 100_000)
        XCTAssertEqual(all?.shown.count, PatientZoom.maxAreas)
        let few = PatientZoom.areasBlock(many, budget: 400)
        XCTAssertLessThanOrEqual(few?.text.count ?? 0, 400)
        XCTAssertNil(PatientZoom.areasBlock(many, budget: 50), "no line fits")
    }

    /// The summaries' cap grows with this Mac's budget (8 / 16 / 32 GB), never below 4.
    func testSummaryCapFollowsTheBudget() {
        XCTAssertEqual(PatientZoom.individualSummaryLimit(summaryRoom: 1_000), 4)
        let eight = PatientZoom.Shares(room: 38_707 - 13_000).summaries
        let sixteen = PatientZoom.Shares(room: 82_944 - 27_000).summaries
        let thirtyTwo = PatientZoom.Shares(room: 171_417 - 57_000).summaries
        XCTAssertLessThan(PatientZoom.individualSummaryLimit(summaryRoom: eight), PatientZoom.individualSummaryLimit(summaryRoom: sixteen))
        XCTAssertLessThan(PatientZoom.individualSummaryLimit(summaryRoom: sixteen), PatientZoom.individualSummaryLimit(summaryRoom: thirtyTwo))
        let shares = PatientZoom.Shares(room: 10_000)
        XCTAssertLessThanOrEqual(shares.summaries + shares.areas + shares.sections, 10_000)
    }

    func testStepsFollowTheEffort() {
        XCTAssertEqual(PatientAskSteps(effort: .fast, layered: true).total, 2)
        XCTAssertEqual(PatientAskSteps(effort: .normal, layered: true).total, 2 + AnswerEffort.normal.maxRefinementRounds)
        XCTAssertEqual(PatientAskSteps(effort: .focus, layered: true).total, 2 + AnswerEffort.focus.maxRefinementRounds)
        XCTAssertEqual(PatientAskSteps(effort: .focus, layered: false).total, 2, "a history read whole has no lookups")

        let focus = PatientAskSteps(effort: .focus, layered: true)
        let order = [focus.gathering, focus.choosing(round: 0), focus.choosing(round: 1), focus.writing]
        let fractions = order.map(\.fraction)
        XCTAssertEqual(fractions, fractions.sorted())
        XCTAssertLessThan(fractions.last ?? 1, 1, "never full before the answer is written")
        XCTAssertEqual(focus.choosing(round: 9), focus.choosing(round: 1), "a round past the last stays on the last")
    }

    func testFinishedStepsSayWhatWasGathered() {
        var coverage = TranscriptCoverage(transcriptSessions: 100, sessionsWithPassages: 3, mentions: 7, searched: true, digestSessions: 40)
        coverage.layered = true
        coverage.areas = 5
        coverage.summarySections = 2
        XCTAssertEqual(PatientAskSteps.finishedLines(coverage), [
            "Searched 100 sessions · 7 matches",
            "Read summaries of 40 sessions",
            "Found 5 parts worth a closer look",
            "Read the summaries of 2 of them",
            "Took the matching lines from 3 sessions",
        ])
    }

    // MARK: - Openings of sessions with no summary yet

    /// `lines` lines of about 50 characters, alternating speakers, as stored.
    private func transcript(_ name: String, lines: Int) -> String {
        (0..<lines).map { i in
            "[\(String(format: "%02d", i)):00] \(i % 2 == 0 ? "You" : "Call audio"): \(name) line \(i) about the week."
        }.joined(separator: "\n")
    }

    func testAnOpeningIsTheCompactedStartCutAtTheEndOfALine() throws {
        let long = transcript("Ana", lines: 100)
        let excerpt = try XCTUnwrap(PatientZoom.openingExcerpt(of: long, limit: 500))
        XCTAssertLessThanOrEqual(excerpt.count, 500)
        XCTAssertTrue(excerpt.hasPrefix("[00:00] Y: Ana line 0 about the week."), "compacted as the model reads transcripts")
        XCTAssertTrue(excerpt.hasSuffix("\n" + PatientZoom.openingCutMarker))
        let lines = excerpt.split(separator: "\n").dropLast()
        XCTAssertFalse(lines.isEmpty)
        for line in lines { XCTAssertTrue(line.hasSuffix("about the week."), "cut only at a line end: \(line)") }

        let short = transcript("Ben", lines: 3)
        XCTAssertEqual(PatientZoom.openingExcerpt(of: short, limit: 500), TranscriptCompactor.compact(short), "short enough: whole, unmarked")

        XCTAssertNil(PatientZoom.openingExcerpt(of: long, limit: PatientZoom.minOpeningCharacters - 1))
        XCTAssertNil(PatientZoom.openingExcerpt(of: "  \n ", limit: 500))

        let oneLongLine = "[00:00] You: " + String(repeating: "word ", count: 200)
        let cut = try XCTUnwrap(PatientZoom.openingExcerpt(of: oneLongLine, limit: 400))
        XCTAssertLessThanOrEqual(cut.count, 400)
        XCTAssertTrue(cut.hasSuffix(PatientZoom.openingCutMarker))
    }

    func testOpeningsShareTheBudgetNewestFirstAndNeverExceedIt() {
        let sessions = (1...6).map { n in
            PatientZoom.OpeningInput(tag: "S\(n)", date: date(2026, 1, 10 - n), transcript: transcript("S\(n)", lines: 200))
        }
        let budget = 6_000
        let openings = PatientZoom.openings(sessions, budget: budget)

        XCTAssertEqual(openings.map(\.tag), ["S1", "S2", "S3", "S4"], "newest first, room for \(PatientZoom.openingSlots)")
        XCTAssertLessThanOrEqual(openings.reduce(0) { $0 + $1.cost }, budget)
        for opening in openings {
            XCTAssertLessThanOrEqual(opening.cost, budget / PatientZoom.openingSlots)
            XCTAssertEqual(opening.cost, opening.block.count + 2 + PatientZoom.headerAllowance)
            XCTAssertTrue(opening.block.hasPrefix(PatientZoom.openingLabel + "\n[00:00] Y: \(opening.tag) line 0"))
        }

        // Two sessions split the room in two.
        let two = PatientZoom.openings(Array(sessions.prefix(2)), budget: budget)
        XCTAssertEqual(two.count, 2)
        for opening in two { XCTAssertLessThanOrEqual(opening.cost, budget / 2) }

        XCTAssertEqual(PatientZoom.openings(sessions, budget: 0), [])
        XCTAssertEqual(PatientZoom.openings([], budget: budget), [])
    }

    func testRoomAShortOpeningLeavesGoesToTheNextSession() {
        let short = PatientZoom.OpeningInput(tag: "S1", date: date(2026, 1, 9), transcript: transcript("S1", lines: 2))
        let long = (2...5).map { n in
            PatientZoom.OpeningInput(tag: "S\(n)", date: date(2026, 1, 10 - n), transcript: transcript("S\(n)", lines: 200))
        }
        let budget = 4_000
        let openings = PatientZoom.openings([short] + long, budget: budget)

        XCTAssertEqual(openings.map(\.tag), ["S1", "S2", "S3", "S4", "S5"], "the fifth gets what the short first one left")
        XCTAssertLessThanOrEqual(openings.reduce(0) { $0 + $1.cost }, budget)
        XCTAssertFalse(openings[0].block.contains(PatientZoom.openingCutMarker), "a short transcript goes in whole")
    }

    func testCoverageSaysWhichSessionsWereReadFromTheirOpenings() {
        var coverage = TranscriptCoverage(transcriptSessions: 5, digestSessions: 2)
        coverage.layered = true
        coverage.openingSessions = 1
        coverage.searchOnlySessions = 2
        coverage.noSummarySessions = 2
        XCTAssertEqual(
            coverage.label,
            "Read: summaries of 2 sessions · transcript opening of 1 session with no summary yet · nothing from 2 sessions (no words to search for; 2 with no summary yet)"
        )
        coverage.openingSessions = 3
        coverage.searchOnlySessions = 0
        coverage.noSummarySessions = 0
        XCTAssertEqual(coverage.label, "Read: summaries of 2 sessions · transcript openings of 3 sessions with no summary yet")
        XCTAssertEqual(PatientAskSteps.finishedLines(coverage), [
            "Searched 5 sessions",
            "Read summaries of 2 sessions",
            "Read the openings of 3 sessions with no summary yet",
        ])
    }
}
