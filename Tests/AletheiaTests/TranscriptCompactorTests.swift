import XCTest
@testable import Aletheia

final class TranscriptCompactorTests: XCTestCase {
    private func compact(_ lines: String...) -> String {
        TranscriptCompactor.compact(lines.joined(separator: "\n"))
    }

    private func assertIdempotent(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let once = TranscriptCompactor.compact(text)
        XCTAssertEqual(TranscriptCompactor.compact(once), once, file: file, line: line)
    }

    // MARK: - Labels and merging

    func testShortLabelsAndMergeSameSpeaker() {
        let out = compact(
            "[00:01] You: How was your week?",
            "[00:05] You: Anything new?",
            "[00:09] Call audio: Pretty good.",
            "[00:12] Call audio: Mostly calm.",
            "[00:20] You: Great.")
        XCTAssertEqual(out, """
        [00:01] Y: How was your week? Anything new?
        [00:09] C: Pretty good. Mostly calm.
        [00:20] Y: Great.
        """)
    }

    func testOverlapKeepsAMarkerAndSplitsTurns() {
        let out = compact(
            "[00:10] You (overlapping): Let me finish.",
            "[00:12] Call audio (overlapping): But I think so.",
            "[00:14] Call audio: Sorry.",
            "[00:15] Call audio (overlapping): Again.")
        XCTAssertEqual(out, """
        [00:10] Y~: Let me finish.
        [00:12] C~: But I think so.
        [00:14] C: Sorry.
        [00:15] C~: Again.
        """)
        assertIdempotent(out)
    }

    func testUnrecognisedLinesPassThroughAndEndTheTurn() {
        let out = compact("[00:01] You: a", "a typed line", "[00:05] You: b", "…", "[00:06] Therapist: x")
        XCTAssertEqual(out, "[00:01] Y: a\na typed line\n[00:05] Y: b\n…\n[00:06] Therapist: x")
    }

    // MARK: - Timestamp anchors

    func testLongTurnGetsAnAnchorEverySixtySeconds() {
        let lines = stride(from: 0, to: 200, by: 10).map { String(format: "[%02d:%02d] You: s%d", $0 / 60, $0 % 60, $0) }
        let out = TranscriptCompactor.compact(lines.joined(separator: "\n"))
        let rows = out.split(separator: "\n").map(String.init)
        XCTAssertEqual(rows.map { TranscriptTimeline.leadingSeconds(of: $0) }, [0, 60, 120, 180])
        XCTAssertTrue(rows.allSatisfy { $0.contains("] Y: ") })
        XCTAssertTrue(rows[0].hasSuffix("s50"))
        assertIdempotent(out)
    }

    func testMinutePastFiftyNineAndHourStampsKeepTheirForm() {
        let out = compact(
            "[1:59:50] You: a", "[2:00:55] You: b", "[75:12] Call audio: c", "[75:20] Call audio: d")
        XCTAssertEqual(out, "[1:59:50] Y: a\n[2:00:55] Y: b\n[75:12] C: c d")
        XCTAssertEqual(TranscriptTimeline.leadingSeconds(of: "[2:00:55] Y: b"), 7255)
        assertIdempotent(out)
    }

    // MARK: - Filler

    func testRemovesOnlyStandaloneFiller() {
        XCTAssertEqual(TranscriptCompactor.removeFiller("I was, um, thinking."), "I was, thinking.")
        XCTAssertEqual(TranscriptCompactor.removeFiller("Um, okay."), "okay.")
        XCTAssertEqual(TranscriptCompactor.removeFiller("Um—I think so."), "I think so.")
        XCTAssertEqual(TranscriptCompactor.removeFiller("It was UH hard, hmm. Yes."), "It was hard. Yes.")
        XCTAssertEqual(TranscriptCompactor.removeFiller("I think, erm."), "I think.")
        XCTAssertEqual(TranscriptCompactor.removeFiller("Right. Um. Okay."), "Right. Okay.")
    }

    func testKeepsWordsThatContainOrFollowFiller() {
        for kept in ["Umbrella season.", "She said uh-huh.", "Mm-hmm, yes.", "Uh-oh.", "Hummus and drums.",
                     "Like, you know, I mean, I wasn't sure.", "I- I wanted to, to say it."] {
            XCTAssertEqual(TranscriptCompactor.removeFiller(kept), kept)
        }
    }

    func testFillerOnlyLineIsDroppedButEndsTheTurn() {
        XCTAssertEqual(compact("[00:01] You: Hello.", "[00:03] Call audio: Um.", "[00:05] You: Bye."), "[00:01] Y: Hello.\n[00:05] Y: Bye.")
        XCTAssertEqual(compact("[00:01] You: Yes.", "[00:02] Call audio: Um.", "[00:03] You: Yes."), "[00:01] Y: Yes.\n[00:03] Y: Yes.")
    }

    func testBackChannelsKeepTheirFiller() {
        for kept in ["Mm hmm.", "Uh huh.", "Uh oh.", "Uh–huh.", "Mm–hmm.", "Uh—oh.", "Yeah, uh huh, I see.", "Mm hmm, okay."] {
            XCTAssertEqual(TranscriptCompactor.removeFiller(kept), kept)
        }
        XCTAssertEqual(TranscriptCompactor.removeFiller("The album uh worked."), "The album worked.")
    }

    func testStandaloneHmmLineIsKept() {
        XCTAssertEqual(compact("[00:01] You: Hmm.", "[00:03] Call audio: Hm.", "[00:05] You: Hmm."), "[00:01] Y: Hmm.\n[00:03] C: Hm.\n[00:05] Y: Hmm.")
    }

    func testEllipsesAndUntouchedPunctuationStay() {
        XCTAssertEqual(TranscriptCompactor.removeFiller("So... uh... yes"), "So... yes")
        XCTAssertEqual(TranscriptCompactor.removeFiller("Well... I guess ,, maybe!! Uh, yes..."), "Well... I guess ,, maybe!! yes...")
        XCTAssertEqual(TranscriptCompactor.removeFiller("Wait... I don't know..."), "Wait... I don't know...")
    }

    // MARK: - Loops

    func testCollapsesFiveOrMoreRepeats() {
        XCTAssertEqual(compact("[00:01] You: Okay. Okay. Okay. Okay. Okay."), "[00:01] Y: Okay. (repeated ×5)")
        let across = compact("[00:01] You: Okay.", "[00:02] You: okay.", "[00:03] You: Okay.", "[00:04] You: Okay.",
                             "[00:05] You: Okay.", "[00:06] You: Okay.", "[00:07] You: Now.")
        XCTAssertEqual(across, "[00:01] Y: Okay. (repeated ×6) Now.")
    }

    func testEmphaticRepetitionStays() {
        for kept in ["No. No. No.", "I don't know. I don't know. I don't know.", "Okay. Okay. Okay. Okay."] {
            XCTAssertEqual(compact("[00:01] You: \(kept)"), "[00:01] Y: \(kept)")
        }
    }

    func testDifferentPunctuationIsNotTheSameSentence() {
        let text = "No? No! No? No! No? No!"
        XCTAssertEqual(compact("[00:01] You: \(text)"), "[00:01] Y: \(text)")
    }

    func testTwoRepeatsAndLongPhrasesStay() {
        XCTAssertEqual(compact("[00:01] You: Okay. Okay."), "[00:01] Y: Okay. Okay.")
        let long = "I really did not want to go there at all. "
        let text = "[00:01] Y: " + String(repeating: long, count: 5).trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(TranscriptCompactor.compact(text), text)
    }

    func testLoopAndFillerOutputIsIdempotent() {
        assertIdempotent("""
        [00:01] You: Okay. Okay. Okay. Okay.
        [00:05] Call audio: Um, I was, uh, scared.
        [00:09] Call audio (overlapping): Thank you. Thank you. Thank you. Thank you. Thank you.
        """)
    }

    // MARK: - Long sessions (timings: PRBenchmarkTests)

    /// Mic-only session: one speaker, so the whole two hours is a single turn.
    func testTwoHourSingleSpeakerSessionCompacts() {
        let lines = (0..<1500).map { stamp($0 * 5, "You", "Segment \($0) um about the week, okay. Okay.") }
        let raw = lines.joined(separator: "\n")
        XCTAssertTrue(TranscriptCompactor.compact(raw).contains("Segment 1499"))
    }

    // MARK: - Synthetic hour

    /// An invented hour of therapy: ~7 s segments alternating in short runs,
    /// a few fillers and one Whisper loop.
    private func syntheticHour() -> String {
        let you = ["How has the week been for you?", "What happened when Marlowe cancelled?", "That sounds hard.",
                   "Tell me more about the morning routine.", "How did you sleep after that?"]
        let them = ["Um, it was okay I guess, uh, mostly fine.", "I kept thinking about Hartley Street again.",
                    "We talked and it was, you know, a bit tense.", "I mean, I did try to breathe like we practised.",
                    "I slept maybe five hours, hmm, not great."]
        var lines: [String] = []
        var t = 0
        var i = 0
        while t < 3600 {
            let runYou = 1 + i % 2, runThem = 1 + (i / 2) % 3
            for r in 0..<runYou { lines.append(stamp(t, "You", you[(i + r) % you.count])); t += 5 }
            for r in 0..<runThem { lines.append(stamp(t, "Call audio", them[(i + r) % them.count])); t += 7 }
            if i == 40 { for _ in 0..<5 { lines.append(stamp(t, "Call audio", "Okay.")); t += 2 } }
            i += 1
        }
        return lines.joined(separator: "\n")
    }

    private func stamp(_ t: Int, _ who: String, _ text: String) -> String {
        String(format: "[%02d:%02d] %@: %@", t / 60, t % 60, who, text)
    }

    func testHourLongTranscriptShrinksAndKeepsContent() {
        let raw = syntheticHour()
        let out = TranscriptCompactor.compact(raw)
        let before = ContextBudget.estimatedTokens(forCharacters: raw.count)
        let after = ContextBudget.estimatedTokens(forCharacters: out.count)
        let reduction = 100 - after * 100 / before
        print("TranscriptCompactor synthetic hour: \(before) -> \(after) tokens (-\(reduction)%)")
        XCTAssertLessThan(after, before * 8 / 10)
        for kept in ["Marlowe", "Hartley Street", "you know", "I mean", "Okay. (repeated ×5)"] {
            XCTAssertTrue(out.contains(kept), kept)
        }
        XCTAssertFalse(out.contains(" um,"))
        assertIdempotent(raw)
        // Every minute of a long hour is still anchored.
        let seconds = out.split(separator: "\n").compactMap { TranscriptTimeline.leadingSeconds(of: String($0)) }
        XCTAssertEqual(seconds, seconds.sorted())
        XCTAssertTrue(zip(seconds, seconds.dropFirst()).allSatisfy { $1 - $0 <= 120 })
    }
}
