import XCTest
@testable import Aletheia

/// The token estimate by script: English keeps the old 3-characters-a-token
/// figure, while Japanese, Chinese and Korean count about a token a character,
/// so a prompt in those scripts can't slip past the budget check.
final class TokenEstimateTests: XCTestCase {
    private let japanese = "今日はとても疲れました。"   // 12 characters
    private let chinese = "我最近睡得不好"
    private let korean = "요즘 잠을 잘 못 자요"

    // MARK: Estimate

    func testEnglishEstimateIsUnchanged() {
        let english = String(repeating: "I felt tired all week, honestly. ", count: 300)
        XCTAssertEqual(ContextBudget.weightedLength(of: english), english.count)
        XCTAssertEqual(ContextBudget.estimatedTokens(for: english),
                       ContextBudget.estimatedTokens(forCharacters: english.count))
        XCTAssertEqual(ContextBudget.estimatedTokens(for: String(repeating: "x", count: 3_000)), 1_000)
        // Accented Latin, dashes, ellipses and curly quotes still count as one character each.
        let accented = "Café — naïve “déjà vu”… São Paulo × 2"
        XCTAssertEqual(ContextBudget.weightedLength(of: accented), accented.count)
        // A CRLF line break is one character, as `count` has it.
        XCTAssertEqual(ContextBudget.weightedLength(of: "a\r\nb"), 3)
    }

    func testCJKIsAtLeastATokenACharacter() {
        for text in [japanese, chinese] {
            XCTAssertGreaterThanOrEqual(ContextBudget.estimatedTokens(for: text), text.count, text)
        }
        // Korean: every Hangul syllable is a token; the spaces count as Latin.
        let hangul = korean.filter { $0 != " " }.count
        XCTAssertGreaterThanOrEqual(ContextBudget.estimatedTokens(for: korean), hangul)
        XCTAssertGreaterThanOrEqual(ContextBudget.estimatedTokens(for: "สวัสดีครับ"), 5)
        let long = String(repeating: japanese, count: 2_500)
        XCTAssertEqual(long.count, 30_000)
        XCTAssertGreaterThanOrEqual(ContextBudget.estimatedTokens(for: long), 30_000)
    }

    func testMixedTextCountsEachScriptByItsOwnRate() {
        let latin = "[00:12] C: "   // 11 characters
        let mixed = latin + japanese
        XCTAssertEqual(ContextBudget.weightedLength(of: mixed), 11 + 12 * ContextBudget.charactersPerToken)
        XCTAssertEqual(ContextBudget.estimatedTokens(for: mixed), (11 + 36) / 3)
        XCTAssertEqual(ContextBudget.estimatedTokens(system: latin, prompt: japanese),
                       ContextBudget.estimatedTokens(for: mixed))
    }

    // MARK: Fit check

    func testThirtyThousandJapaneseCharactersDoNotFitA32KWindow() {
        let budget = ContextBudget(tokens: 32_768)
        let long = String(repeating: japanese, count: 2_500)
        let prompt = Prompts.progressNote(format: .narrative, transcript: long)
        XCTAssertFalse(budget.fits(system: Prompts.defaultSystemPrompt, prompt: prompt))
        // Counting characters at 3 a token, as before, would have let it through.
        XCTAssertTrue(budget.fits(promptCharacters: Prompts.defaultSystemPrompt.count + prompt.count))
        // The same length of English still fits.
        let english = String(repeating: "x", count: 30_000)
        XCTAssertTrue(budget.fits(system: Prompts.defaultSystemPrompt, prompt: english))
    }

    func testCharacterRoomShrinksForDenseScripts() {
        XCTAssertEqual(ContextBudget.characters(fitting: 9_000, like: "plain English text"), 9_000)
        XCTAssertEqual(ContextBudget.characters(fitting: 9_000, like: japanese), 3_000)
        XCTAssertEqual(ContextBudget.characters(fitting: 9_000, like: ""), 9_000)
        // Material sized that way fits the room it was given.
        let room = ContextBudget(tokens: 8_192).availableCharacters(reserving: 0)
        let chars = ContextBudget.characters(fitting: room, like: japanese)
        let material = String(String(repeating: japanese, count: chars / 12 + 1).prefix(chars))
        XCTAssertLessThanOrEqual(ContextBudget.weightedLength(of: material), room)
    }

    func testPrefixByWeightedLength() {
        let text = Substring("ab" + japanese)
        XCTAssertEqual(ContextBudget.prefix(text, weightedLength: 8), "ab今日")
        XCTAssertEqual(ContextBudget.prefix(text, weightedLength: 7), "ab今")
        XCTAssertEqual(ContextBudget.prefix(Substring("hello"), weightedLength: 3), "hel")
        // Never empty, so a caller cutting a long run always moves on.
        XCTAssertEqual(ContextBudget.prefix(Substring(japanese), weightedLength: 1), "今")
    }

    // MARK: Sections

    func testJapaneseTranscriptSectionsStayWithinTheirTokenCap() {
        let line = "[00:01] C: " + String(repeating: japanese, count: 20)   // 251 characters
        let transcript = Array(repeating: line, count: 200).joined(separator: "\n")
        let sections = TranscriptSections.split(transcript, targetSeconds: 100_000)
        XCTAssertGreaterThan(sections.count, 1)
        for section in sections {
            XCTAssertLessThanOrEqual(ContextBudget.weightedLength(of: section.text), TranscriptSections.maxCharacters)
            XCTAssertLessThan(section.text.count, TranscriptSections.maxCharacters / 2)
        }
        XCTAssertEqual(sections.map(\.text).joined(separator: "\n"), transcript)
    }

    func testOneLongJapaneseLineIsCutByWeight() {
        let monologue = String(repeating: japanese, count: 1_000)   // 12,000 characters, no breaks
        let sections = TranscriptSections.split(monologue)
        XCTAssertEqual(sections.count, 3)
        XCTAssertTrue(sections.allSatisfy { ContextBudget.weightedLength(of: $0.text) <= TranscriptSections.maxCharacters })
        XCTAssertEqual(sections.map(\.text).joined(), monologue)
    }

    func testEnglishSectionsAreUnchanged() {
        let monologue = String(repeating: "a", count: 30_000)
        XCTAssertEqual(TranscriptSections.split(monologue).map(\.text.count), [12_000, 12_000, 6_000])
    }

    // MARK: Tripwire

    func testNearLimitReadIsFlagged() {
        let window = 8_192
        let edge = window - ContextBudget.replyHeadroomTokens
        // Read exactly what was estimated, but up to the window's edge: likely cut.
        let atEdge = AIRunStats(promptTokens: edge, expectedPromptTokens: edge, contextTokens: window)
        XCTAssertTrue(atEdge.nearContextLimit)
        XCTAssertTrue(atEdge.possiblyTruncated)
        XCTAssertTrue(AIRunStats(promptTokens: window, expectedPromptTokens: edge, contextTokens: window).possiblyTruncated)
        // Just below it: clear.
        let below = AIRunStats(promptTokens: edge - 1, expectedPromptTokens: edge, contextTokens: window)
        XCTAssertFalse(below.nearContextLimit)
        XCTAssertFalse(below.possiblyTruncated)
        // Window unknown (the embedded engine, which refuses rather than cuts): not judged.
        XCTAssertFalse(AIRunStats(promptTokens: window, expectedPromptTokens: edge).possiblyTruncated)
    }

    func testTheWindowDecidesWhetherASixThousandTokenReadWasCut() {
        let cut = AIRunStats(promptTokens: 6_200, expectedPromptTokens: 6_000, contextTokens: 8_192)
        XCTAssertTrue(cut.possiblyTruncated)
        let roomy = AIRunStats(promptTokens: 6_200, expectedPromptTokens: 6_000, contextTokens: 32_768)
        XCTAssertFalse(roomy.possiblyTruncated)
    }
}
