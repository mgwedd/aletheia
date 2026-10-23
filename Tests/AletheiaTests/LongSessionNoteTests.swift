import XCTest
@testable import Aletheia

private let defaultPhrases = LongSessionNote.defaultRiskPhrases

/// A stub model that answers by the kind of prompt it is given and records them all.
private final class StubModel: Assistant, @unchecked Sendable {
    var prompts: [String] = []
    var recordedCalls: [(task: AITask, grammar: LocalLLMGrammar?)] = []
    /// What the check call returns; `failCheck` makes it throw instead.
    var checkResponse = "CHECKED NOTE"
    var failCheck = false
    /// When set, the check call throws this.
    var checkError: Error?
    /// Waits this long on each digest call (nanoseconds).
    var digestDelay: UInt64 = 0

    func isReachable() async -> Bool { true }
    func listModels() async throws -> [String] { [] }
    func hasModel(_ name: String) async -> Bool { true }
    func generate(model: String, system: String, prompt: String) async throws -> String {
        prompts.append(prompt)
        if prompt.contains("Transcript section") {
            if digestDelay > 0 { try await Task.sleep(nanoseconds: digestDelay) }
            return "section digest"
        }
        if prompt.contains("Below are digest notes") { return "merged digest [0:00–9:00]" }
        if prompt.contains("Below are a draft clinical note") {
            if let checkError { throw checkError }
            if failCheck { throw URLError(.cannotConnectToHost) }
            return checkResponse
        }
        return "DRAFT NOTE"
    }
    func stream(
        model: String,
        system: String,
        prompt: String,
        task: AITask,
        grammar: LocalLLMGrammar?,
        onStats: (@Sendable (AIRunStats) -> Void)?
    ) -> AsyncThrowingStream<String, Error> {
        recordedCalls.append((task, grammar))
        return stream(model: model, system: system, prompt: prompt, task: task, onStats: onStats)
    }
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {}
}

/// Made-up session: a line every 20 seconds, with one risk statement and its denial late on.
private func syntheticTranscript(minutes: Int) -> String {
    (0..<(minutes * 3)).map { i in
        let stamp = String(format: "[%02d:%02d]", (i * 20) / 60, (i * 20) % 60)
        switch i {
        case minutes * 2: return "\(stamp) Client: Some nights I think about hurting myself, just briefly."
        case minutes * 2 + 1: return "\(stamp) You: Do you have a plan to act on that? Client: No, I would never do it."
        case _ where i % 10 == 0: return "\(stamp) Client: I felt anxious and could not sleep, so work stress piled up \(i)."
        default: return "\(stamp) You: Tell me more about topic number \(i) and how the week went with the family and work."
        }
    }.joined(separator: "\n")
}

private func storedDigest(for text: String, size: Int = 20, model: String = "m") -> SessionDigest {
    SessionDigest(
        model: model, promptVersion: Prompts.digestVersion, transcriptFingerprint: NoteFreshness.fingerprint(of: text),
        sections: [.init(start: 0, end: 540, digest: "s")], sessionDigest: String(repeating: "STORED DIGEST ", count: size),
        createdAt: Date())
}

@MainActor
final class LongSessionNoteTests: XCTestCase {
    private let budget = ContextBudget(tokens: 8192)

    /// The test host app owns the shared index and may have it closed behind its lock; use a private one.
    override func setUp() async throws { SessionSearch.index = SearchIndex() }

    private struct Run {
        var snapshots: [String]
        var coverage: [String]
        var prompts: [String]
    }

    private func run(
        transcript: String, effort: AnswerEffort = .normal, stored: SessionDigest? = nil, tokens: Int = 8192,
        format: ProgressNoteFormat = .soap, phrases: [String] = defaultPhrases, sectionCache: SectionCacheAccess? = nil,
        configure: (StubModel) -> Void = { _ in }
    ) async throws -> Run {
        let stub = StubModel()
        configure(stub)
        var service = AssistantService(assistant: stub, model: "m")
        service.budget = ContextBudget(tokens: tokens)
        var coverage: [String] = []
        let stream = LongSessionNote.stream(
            format: format, transcript: transcript, effort: effort, riskPhrases: phrases, service: service,
            builder: DigestBuilder(queue: InferenceQueue()), sessionID: UUID(),
            loadDigest: { stored }, saveDigest: { _ in }, sectionCache: sectionCache,
            live: { _, _ in }, coverage: { coverage.append($0) })
        var snapshots: [String] = []
        for try await snapshot in stream { snapshots.append(snapshot) }
        return Run(snapshots: snapshots, coverage: coverage, prompts: stub.prompts)
    }

    // MARK: - Paths

    func testWholeSessionWhenItFitsIsUnchanged() async throws {
        let text = syntheticTranscript(minutes: 5)
        let result = try await run(transcript: text, effort: .focus)
        XCTAssertEqual(result.prompts, [Prompts.progressNote(format: .soap, transcript: text)])
        XCTAssertEqual(result.snapshots, ["DRAFT NOTE"])
        XCTAssertTrue(result.coverage.isEmpty)
    }

    func testOverflowUsesDigestAndPassagesWithinBudget() async throws {
        let text = syntheticTranscript(minutes: 120)
        var service = AssistantService(assistant: StubModel(), model: "m")
        service.budget = ContextBudget(tokens: 8192)
        XCTAssertFalse(service.fits(prompt: Prompts.progressNote(format: .soap, transcript: text)))

        let result = try await run(transcript: text)
        let final = try XCTUnwrap(result.prompts.last)
        XCTAssertEqual(result.snapshots.last, "DRAFT NOTE")
        XCTAssertTrue(service.fits(prompt: final))
        XCTAssertTrue(final.contains("merged digest"))
        XCTAssertTrue(final.contains("think about hurting myself"), "risk statement comes from the transcript")
        XCTAssertTrue(final.contains("I would never do it"), "the denial comes with it")
        XCTAssertFalse(final.contains(text))
        XCTAssertTrue(result.prompts.dropLast().allSatisfy { !$0.contains("Draft note:") && !$0.contains("Passages from the original") })
    }

    func testStoredDigestIsNotRebuilt() async throws {
        let text = syntheticTranscript(minutes: 120)
        let result = try await run(transcript: text, stored: storedDigest(for: text))
        XCTAssertEqual(result.prompts.count, 1)
        XCTAssertTrue(result.prompts[0].contains("STORED DIGEST"))
    }

    /// A note that builds the digest inline keeps each section summary in the
    /// session's section cache; the next one reads them back and only merges.
    func testInlineDigestUsesTheSectionCache() async throws {
        let text = syntheticTranscript(minutes: 120)
        var saved: [String: String] = [:]
        let access = SectionCacheAccess(load: { saved }, save: { saved = $0 })
        let first = try await run(transcript: text, sectionCache: access)
        let sectionCalls = first.prompts.filter { $0.contains("Transcript section") }.count
        XCTAssertGreaterThan(sectionCalls, 1)
        XCTAssertEqual(saved.count, sectionCalls)

        let second = try await run(transcript: text, sectionCache: access)
        XCTAssertFalse(second.prompts.contains { $0.contains("Transcript section") }, "every section comes from the cache")
        XCTAssertTrue(second.prompts.contains { $0.contains("Below are digest notes") }, "only the merge runs again")
    }

    // MARK: - Coverage

    func testCoverageCountsExactlyTheLinesInThePrompt() async throws {
        let text = syntheticTranscript(minutes: 120)
        let result = try await run(transcript: text, stored: storedDigest(for: text))
        let notice = try XCTUnwrap(result.coverage.first)
        XCTAssertTrue(notice.hasPrefix("Read: a summary of the whole session"))
        XCTAssertTrue(notice.contains("of 360 transcript lines"))
        XCTAssertTrue(notice.contains("Normal"))
        XCTAssertTrue(notice.contains("may be missing"))
        let sent = try XCTUnwrap(result.prompts.last?.components(separatedBy: "Passages from the original transcript:\n").last)
        // The prompt carries the passages compacted (same-speaker lines merged), so count
        // the transcript lines whose text is in it.
        let lines = text.split(separator: "\n").filter { line in
            line.range(of: "] ").map { sent.contains(line[$0.upperBound...].drop { $0 != ":" }.dropFirst(2)) } ?? false
        }
        let reported = try XCTUnwrap(notice.components(separatedBy: " plus ").last?.split(separator: " ").first.flatMap { Int($0) })
        XCTAssertEqual(lines.count, reported)
        XCTAssertLessThanOrEqual(reported, 360)
    }

    func testBlankLinesAreNotCounted() {
        let text = "[00:00] You: hello\n[00:20] Client: I want to end my life\n[00:40] You: tell me more\n\n\n"
        let found = LongSessionNote.passages(in: text, format: .soap, limit: 5_000, riskLimit: 2_000, phrases: defaultPhrases)
        XCTAssertEqual(found.lineCount, 3)
        XCTAssertEqual(LongSessionNote.nonBlankLines(text).count, 3)
    }

    // MARK: - Risk

    func testRiskParaphrasesAreFoundAndSurviveATightRoom() {
        var lines = (0..<400).map { String(format: "[%02d:%02d] You: Tell me more about topic number %d, the safe route and a drink with friends.", $0 / 3, ($0 % 3) * 20, $0) }
        lines[300] = "[100:00] Client: Honestly I don't want to be here anymore."
        lines[350] = "[116:40] Client: I have been thinking about ending my life."
        lines[200] = "[66:40] Client: I took all my pills last year."
        let found = LongSessionNote.passages(in: lines.joined(separator: "\n"), format: .soap, limit: 1_500, riskLimit: 900, phrases: defaultPhrases)
        XCTAssertTrue(found.text.contains("don't want to be here anymore"))
        XCTAssertTrue(found.text.contains("thinking about ending my life"))
        XCTAssertTrue(found.text.contains("pills"))
        XCTAssertLessThanOrEqual(found.text.count, 1_500 + found.lineCount)
    }

    func testExplicitRiskOutranksGenericWords() {
        // Many generic "drinking"/"safe" lines come first; the one explicit line must still make a small risk room.
        var lines = (0..<200).map { "[\($0)] Client: I was drinking again and felt safe at home, drinking with Sam." + String(repeating: " x", count: 5) + " \($0)" }
        lines[190] = "[190] Client: I want to kill myself some days."
        let found = LongSessionNote.passages(in: lines.joined(separator: "\n"), format: .soap, limit: 800, riskLimit: 300, phrases: defaultPhrases)
        XCTAssertTrue(found.text.contains("kill myself"))
    }

    func testRiskLinesReachThePromptOnATightBudget() async throws {
        var lines = (0..<600).map { String(format: "[%02d:%02d] You: Tell me more about topic number %d and how the week went.", $0 / 3, ($0 % 3) * 20, $0) }
        lines[500] = "[166:40] Client: I don't want to be here anymore."
        lines[510] = "[170:00] Client: I have been thinking about ending my life."
        let text = lines.joined(separator: "\n")
        for effort in [AnswerEffort.normal, .focus] {
            let result = try await run(transcript: text, effort: effort, stored: storedDigest(for: text), tokens: 4600)
            let final = try XCTUnwrap(result.prompts.first)
            XCTAssertTrue(final.contains("don't want to be here anymore"), "\(effort)")
            XCTAssertTrue(final.contains("thinking about ending my life"), "\(effort)")
            var service = AssistantService(assistant: StubModel(), model: "m")
            service.budget = ContextBudget(tokens: 4600)
            XCTAssertTrue(service.fits(prompt: final), "\(effort)")
        }
    }

    // MARK: - Budget

    func testFocusSkipsItsCheckRatherThanStarvePassages() async throws {
        var lines = (0..<600).map { String(format: "[%02d:%02d] You: Tell me more about topic number %d and how the week went.", $0 / 3, ($0 % 3) * 20, $0) }
        lines[500] = "[166:40] Client: I felt anxious and could not sleep."
        let text = lines.joined(separator: "\n")
        let result = try await run(transcript: text, effort: .focus, stored: storedDigest(for: text), tokens: 4600)
        XCTAssertEqual(result.prompts.count, 1, "no check call")
        XCTAssertTrue(try XCTUnwrap(result.coverage.last).contains("Not checked: not enough room"))
        XCTAssertGreaterThan(try XCTUnwrap(result.prompts.first).count, 3_000)
    }

    func testOversizedDigestIsShortenedNotRefused() async throws {
        let text = syntheticTranscript(minutes: 120)
        let result = try await run(transcript: text, stored: storedDigest(for: text, size: 600), tokens: 5000)
        let final = try XCTUnwrap(result.prompts.last)
        var service = AssistantService(assistant: StubModel(), model: "m")
        service.budget = ContextBudget(tokens: 5000)
        XCTAssertTrue(service.fits(prompt: final))
        XCTAssertTrue(final.contains("[digest shortened]"))
        XCTAssertTrue(try XCTUnwrap(result.coverage.first).contains("shortened to fit"))
        XCTAssertFalse(ContextBudgetError(minutes: 5).localizedDescription.contains("coming"))
    }

    // MARK: - Focus check

    func testFocusAddsOneCheckCallAndFinalTextIsTheChecked() async throws {
        let text = syntheticTranscript(minutes: 120)
        let normal = try await run(transcript: text, effort: .normal)
        let focus = try await run(transcript: text, effort: .focus) { $0.checkResponse = String(repeating: "CHECKED NOTE ", count: 3) }
        XCTAssertEqual(focus.prompts.count, normal.prompts.count + 1)
        let check = try XCTUnwrap(focus.prompts.last)
        XCTAssertTrue(check.contains("Draft note:\n<draft>\nDRAFT NOTE"))
        XCTAssertTrue(check.contains("I would never do it"))
        XCTAssertEqual(focus.snapshots.count, 2)
        XCTAssertTrue(try XCTUnwrap(focus.snapshots.last).hasPrefix("CHECKED NOTE"))
        XCTAssertTrue(try XCTUnwrap(focus.coverage.last).contains("Checked against the passages"))
        XCTAssertFalse(normal.prompts.contains { $0.contains("Draft note:") })
    }

    func testAFailedCheckKeepsTheDraftAndSaysSo() async throws {
        let text = syntheticTranscript(minutes: 120)
        let result = try await run(transcript: text, effort: .focus) { $0.failCheck = true }
        XCTAssertEqual(result.snapshots, ["DRAFT NOTE"])
        XCTAssertTrue(try XCTUnwrap(result.coverage.last).contains("check didn't run"))
    }

    func testAnIncompleteCheckResultIsNotAccepted() async throws {
        let text = syntheticTranscript(minutes: 120)
        let result = try await run(transcript: text, effort: .focus) { $0.checkResponse = "ok" }
        XCTAssertEqual(result.snapshots, ["DRAFT NOTE"])
        XCTAssertTrue(try XCTUnwrap(result.coverage.last).contains("looked incomplete"))
    }

    func testPlausiblyCompleteNeedsLengthAndHeadings() {
        let draft = "Subjective\nShe slept badly all week and worried a lot.\nPlan\nTry the sleep diary next week."
        XCTAssertTrue(LongSessionNote.plausiblyComplete(draft.replacingOccurrences(of: "badly", with: "poorly"), draft: draft, format: .soap, phrases: defaultPhrases))
        XCTAssertFalse(LongSessionNote.plausiblyComplete("Subjective\nSlept.", draft: draft, format: .soap, phrases: defaultPhrases))
        XCTAssertFalse(LongSessionNote.plausiblyComplete(draft.replacingOccurrences(of: "Plan", with: "Next"), draft: draft, format: .soap, phrases: defaultPhrases))
    }

    // MARK: - Risk phrases

    private func isRisk(_ line: String, _ phrases: [String] = defaultPhrases) -> Bool {
        RiskPhraseMatcher(phrases).firstMatch(in: line) != nil
    }

    func testTheDefaultListIsAReadableSizeWithNoDuplicates() {
        XCTAssertTrue((30...110).contains(defaultPhrases.count), "\(defaultPhrases.count) phrases")
        XCTAssertEqual(Set(defaultPhrases.map { $0.lowercased() }).count, defaultPhrases.count)
        XCTAssertFalse(defaultPhrases.contains { $0.trimmingCharacters(in: .whitespaces) != $0 || $0.isEmpty })
    }

    func testDefaultsMatchSuicideSelfHarmAndViolence() {
        let risky = [
            "I want to kill myself", "I don't want to be here anymore", "I don\u{2019}t want to be here anymore",
            "I don\u{2018}t want to live", "I don\u{02BC}t want to live", "he threatened to kill me",
            "I'm going to kill him", "I wish I was dead", "He hits me when he drinks", "Client denies SI",
            "client DENIES si/hi", "Client endorses SH", "I've been cutting myself", "I\u{2019}ve been cutting myself",
            "I cut myself", "I overdosed last year", "she would murder him", "I want to hurt someone",
            "he beat me up", "I hope I don't wake up", "I took all my pills", "I might walk into traffic",
            "history of SI", "Reports HI: no. Denies HI.", "I think about self-harm",
            "take my own life", "end my own life", "wish I were dead", "thinking of ending it all",
            "she killed herself", "he killed himself", "she is killing herself", "he is killing himself",
            "I will kill them", "I could kill you", "I might kill someone", "I want to kill people", "I\u{2019}m gonna kill",
            "I want to hurt someone", "I want to hurt him", "I want to hurt myself", "I could harm others",
            "thoughts of dying", "I can\u{2019}t go on", "I can't go on", "I want to jump off the bridge",
            "I will shoot him", "I will shoot her", "I will stab him", "I will stab her", "I might stab myself",
            "a homicide threat", "he hit me", "she hit me", "he hits me when he drinks", "never wake up",
            "I want to shoot up the school", "I will murder her", "I will murder them", "ending it all",
            "I have no reason to live",
        ]
        for line in risky { XCTAssertTrue(isRisk(line), line) }
    }

    func testAmbiguousShortPhrasesAreNotDefaults() {
        for line in [
            "I give up on this recipe", "He shot me a look",
            "It hit me that I was late", "She beat me to the door", "I did not wake up until noon",
            "I am cutting back on coffee", "I don\u{2019}t want to hurt his feelings", "A murder mystery novel",
            "Prices are shooting up", "The SI units were converted", "No SI units here", "He hits me up for gossip",
            "I want to kill the lights", "It is not wake up time", "She found a reason to live it up",
            "I\u{2019}ve been cutting corners", "I threaten to leave the group", "She ended it with him",
            "I hit him with a serve", "I hurt her feelings once", "I took a shot at it", "He put his hands on the table",
        ] { XCTAssertFalse(isRisk(line), line) }
    }

    func testTheMainFalsePositivesAreAcceptedBecauseTheListIsEditable() {
        XCTAssertTrue(isRisk("I want to die laughing at that show"))
        XCTAssertTrue(isRisk("We could jump off the dock into the lake"))
    }

    func testDefaultsMissNothingBenign() {
        for line in [
            "I hit my target at work this quarter", "I beat him at chess on Sunday", "I choked up when I spoke",
            "There is a threat of layoffs", "I cut the onions for dinner", "My grandmother died last year",
            "The photo shoot went well", "The SI units were converted", "I missed my pills once and the pharmacy called",
            "Death of a salesman was on at the theatre", "The weapon in the video game was a sword",
        ] { XCTAssertFalse(isRisk(line), line) }
    }

    func testAPhraseMatchesWholeWordsIgnoringCase() {
        XCTAssertTrue(isRisk("My GOLDFISH died", ["goldfish"]))
        XCTAssertTrue(isRisk("Goldfish.", ["goldfish"]))
        XCTAssertFalse(isRisk("two goldfishes", ["goldfish"]))
        XCTAssertFalse(isRisk("a gold fish", ["goldfish"]))
        XCTAssertFalse(isRisk("a waterfall", ["fall"]))
        XCTAssertTrue(isRisk("a bad Fall, again", ["fall"]))
        XCTAssertTrue(isRisk("kill   myself", ["kill myself"]), "any run of spaces")
    }

    func testRegexCharactersInAPhraseAreMatchedLiterally() {
        let phrases = ["a.b", "(x", "c+", "what?", "[z]", "^start", "end$", "a|b", "\\d"]
        for phrase in phrases {
            XCTAssertTrue(isRisk("here: \(phrase) there", [phrase]), phrase)
        }
        XCTAssertFalse(isRisk("axb", ["a.b"]))
        XCTAssertFalse(isRisk("123", ["\\d"]))
        XCTAssertFalse(isRisk("a", ["a|b"]), "an alternation typed by the user is plain text")
        XCTAssertFalse(isRisk("zzz", ["[z]"]))
    }

    func testApostropheFormsAreTheSameCharacter() {
        let forms = ["'", "\u{2019}", "\u{2018}", "\u{02BC}"]
        for typed in forms {
            for spoken in forms {
                XCTAssertTrue(isRisk("I don\(spoken)t want to live", ["don\(typed)t want to live"]), "\(typed) vs \(spoken)")
            }
        }
    }

    func testTheLiteralFallbackNeverFailsOpen() {
        let matcher = RiskPhraseMatcher(["kill myself", "don't want to live"], forceLiteralFallback: true)
        XCTAssertNotNil(matcher.firstMatch(in: "Some days I want to KILL MYSELF"))
        XCTAssertNotNil(matcher.firstMatch(in: "I don\u{2019}t want to live"))
        XCTAssertNil(matcher.firstMatch(in: "a quiet week in the garden"))
        XCTAssertNil(RiskPhraseMatcher([], forceLiteralFallback: true).firstMatch(in: "kill myself"))
    }

    func testBlankPhrasesMatchNothing() {
        XCTAssertFalse(isRisk("anything at all", ["", "   "]))
        XCTAssertFalse(isRisk("anything at all", []))
    }

    // MARK: - Risk phrases in settings

    func testUnsetKeyLoadsTheDefaultsAndAStoredEmptyListStaysEmpty() throws {
        let name = "riskPhrasesTest-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }
        XCTAssertEqual(AppSettings.loadRiskPhrases(from: suite), defaultPhrases)
        suite.set([String](), forKey: "riskPhrases")
        XCTAssertEqual(AppSettings.loadRiskPhrases(from: suite), [])
        suite.set(["only this"], forKey: "riskPhrases")
        XCTAssertEqual(AppSettings.loadRiskPhrases(from: suite), ["only this"])
    }

    @MainActor
    func testClearAddAndResetRiskPhrases() {
        let settings = AppSettings.shared
        let original = settings.riskPhrases
        defer { settings.riskPhrases = original }
        settings.resetRiskPhrases()
        XCTAssertEqual(settings.riskPhrases, defaultPhrases)
        XCTAssertNil(UserDefaults.standard.object(forKey: "riskPhrases"), "the defaults are stored as never set")
        settings.riskPhrases = []
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: "riskPhrases"), [])
        XCTAssertEqual(AppSettings.loadRiskPhrases(from: .standard), [])
        settings.addRiskPhrase("  my phrase ")
        settings.addRiskPhrase("MY PHRASE")
        settings.addRiskPhrase("my   phrase")
        settings.addRiskPhrase("   ")
        settings.addRiskPhrase("don't like it")
        settings.addRiskPhrase("Don\u{2019}t  like it")
        XCTAssertEqual(settings.riskPhrases, ["my phrase", "don't like it"])
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: "riskPhrases"), ["my phrase", "don't like it"])
        settings.resetRiskPhrases()
        XCTAssertEqual(settings.riskPhrases, defaultPhrases)
        XCTAssertNil(UserDefaults.standard.object(forKey: "riskPhrases"))
    }

    func testAnEmptyListFlagsNoLines() {
        let text = tightRiskTranscript()
        XCTAssertGreaterThan(LongSessionNote.strongCost(in: text, phrases: defaultPhrases), 0)
        XCTAssertEqual(LongSessionNote.strongCost(in: text, phrases: []), 0)
        let found = LongSessionNote.passages(in: text, format: .soap, limit: 1_000, riskLimit: 300, phrases: [])
        XCTAssertEqual(found.droppedRisk, 0)
        XCTAssertFalse(found.text.contains("kill myself"))
    }

    func testACustomPhraseIsFoundAndKeptFirst() {
        var lines = (0..<400).map { "[\($0)] You: Tell me more about topic number \($0) and how the week went." }
        lines[300] = "[300] Client: The goldfish situation is getting worse."
        let text = lines.joined(separator: "\n")
        let defaults = LongSessionNote.passages(in: text, format: .soap, limit: 1_500, riskLimit: 300, phrases: defaultPhrases)
        XCTAssertFalse(defaults.text.contains("goldfish"))
        let custom = LongSessionNote.passages(in: text, format: .soap, limit: 1_500, riskLimit: 300, phrases: ["goldfish"])
        XCTAssertTrue(custom.text.contains("goldfish situation"))
    }

    func testTheAlteredRiskRuleUsesTheGivenList() {
        let draft = "## Subjective\nShe slept badly all week. Her goldfish died last week.\n\n## Plan\nTry the sleep diary next week."
        let corrected = draft.replacingOccurrences(of: " Her goldfish died last week.", with: "")
        XCTAssertEqual(LongSessionNote.rejection(corrected, draft: draft, format: .soap, phrases: ["goldfish"]), .alteredRisk)
        XCTAssertNil(LongSessionNote.rejection(corrected, draft: draft, format: .soap, phrases: defaultPhrases))
        XCTAssertNil(LongSessionNote.rejection(corrected, draft: draft, format: .soap, phrases: []))
    }

    // MARK: - Risk room structure

    func testPassagesKeepAsManyRiskLinesAsStreamSetAside() {
        let lines = (0..<20).map { "[\($0)] Client: Some days I want to kill myself, thought number \($0)." }
        let text = lines.joined(separator: "\n")
        let cost = LongSessionNote.strongCost(in: text, phrases: defaultPhrases)
        let capped = LongSessionNote.passages(in: text, format: .soap, limit: cost + 100, riskLimit: 0, phrases: defaultPhrases)
        XCTAssertGreaterThan(capped.droppedRisk, 0, "two thirds of the room is not enough by itself")
        let reserved = LongSessionNote.passages(
            in: text, format: .soap, limit: cost + 100, riskLimit: 0, phrases: defaultPhrases, strongBudget: cost)
        XCTAssertEqual(reserved.droppedRisk, 0)
    }

    func testNeighboursOfDroppedRiskLinesAreNotAdded() {
        var lines = (0..<40).map { "[\($0)] Client: ordinary chat number \($0) about the garden." }
        lines[5] = "[5] Client: I want to kill myself."
        lines[35] = "[35] Client: I want to kill myself again."
        let found = LongSessionNote.passages(
            in: lines.joined(separator: "\n"), format: .soap, limit: 90, riskLimit: 300, phrases: defaultPhrases)
        XCTAssertTrue(found.text.contains("kill myself."))
        XCTAssertFalse(found.text.contains("kill myself again"))
        XCTAssertEqual(found.droppedRisk, 1)
        XCTAssertFalse(found.text.contains("chat number 34"))
        XCTAssertFalse(found.text.contains("chat number 36"))
    }

    func testACutRiskLineKeepsThePartWithThePhrase() {
        let line = "[00:00] Client: " + String(repeating: "and so on ", count: 80) + "and then I said I want to kill myself " + String(repeating: "more words ", count: 80)
        let found = LongSessionNote.passages(in: line, format: .soap, limit: 300, riskLimit: 0, phrases: defaultPhrases)
        XCTAssertTrue(found.text.contains("kill myself"))
        XCTAssertTrue(found.text.hasPrefix("[…truncated]"))
        XCTAssertTrue(found.text.hasSuffix("[…truncated]"))
        XCTAssertLessThanOrEqual(found.text.count, 300)
        XCTAssertEqual(found.droppedRisk, 1)
    }

    func testTheStoppedEarlyNoticeSaysThePartialNoteIsPartial() {
        XCTAssertTrue(LongSessionNote.stoppedEarlyText.contains("Stopped early"))
    }

    // MARK: - Risk room

    private func tightRiskTranscript() -> String {
        var lines = (0..<300).map { String(format: "[%02d:%02d] You: Tell me more about topic number %d and how it went.", $0 / 3, ($0 % 3) * 20, $0) }
        for i in 10..<30 { lines[i] = "[00:\(i)] Client: Some days I want to kill myself, thought \(i)." }
        lines[280] = "[93:20] Client: I took all my pills last year."
        lines[290] = "[96:40] Client: I don't want to be here anymore."
        return lines.joined(separator: "\n")
    }

    func testLateRiskLinesSurviveEarlyChatterOnATightRoom() {
        let found = LongSessionNote.passages(in: tightRiskTranscript(), format: .soap, limit: 1_000, riskLimit: 300, phrases: defaultPhrases)
        XCTAssertTrue(found.text.contains("don't want to be here"), "the late risk line must not be starved")
        XCTAssertTrue(found.text.contains("pills") || found.droppedRisk > 0, "kept or reported")
        XCTAssertGreaterThan(found.droppedRisk, 0, "about 20 lines cannot all fit in 1,000 characters")
        XCTAssertLessThanOrEqual(found.text.count, 1_000 + found.lineCount)
    }

    func testEveryRiskLineIsKeptWhenThereIsRoom() {
        let found = LongSessionNote.passages(in: tightRiskTranscript(), format: .soap, limit: 6_000, riskLimit: 300, phrases: defaultPhrases)
        XCTAssertEqual(found.droppedRisk, 0)
        XCTAssertTrue(found.text.contains("pills"))
        XCTAssertTrue(found.text.contains("don't want to be here"))
        XCTAssertTrue(found.text.contains("thought 10."))
        XCTAssertTrue(found.text.contains("thought 29."))
    }

    func testNeighboursComeOnlyFromTheirOwnAllowance() {
        let lines = (0..<50).map { "[\($0)] Client: ordinary chat number \($0) about the garden." }
        var withRisk = lines
        withRisk[25] = "[25] Client: I want to kill myself."
        let text = withRisk.joined(separator: "\n")
        let bare = LongSessionNote.passages(in: text, format: .soap, limit: 400, riskLimit: 0, phrases: defaultPhrases)
        XCTAssertFalse(bare.text.contains("chat number 24"))
        let roomy = LongSessionNote.passages(in: text, format: .soap, limit: 400, riskLimit: 300, phrases: defaultPhrases)
        XCTAssertTrue(roomy.text.contains("chat number 24"))
    }

    func testAFlaggedLineLongerThanTheRoomIsCutWithAMarker() {
        let long = "[00:00] Client: I want to kill myself " + String(repeating: "and so on ", count: 500)
        let found = LongSessionNote.passages(in: "[00:00] You: hello\n" + long, format: .soap, limit: 400, riskLimit: 100, phrases: defaultPhrases)
        XCTAssertTrue(found.text.contains("kill myself"))
        XCTAssertTrue(found.text.contains("[…truncated]"))
        XCTAssertLessThanOrEqual(found.text.count, 400)
        XCTAssertEqual(found.droppedRisk, 1, "a cut line counts toward the warning")
    }

    func testSpreadTakesBothEndsAndMidpointsFirst() {
        XCTAssertEqual(Array(LongSessionNote.spread(Array(0..<21)).prefix(3)), [0, 20, 10])
        XCTAssertEqual(Set(LongSessionNote.spread(Array(0..<21))), Set(0..<21))
    }

    func testDroppedRiskLinesAreInTheCoverageNotice() {
        let one = LongSessionNote.coverageLabel(digestParts: 3, passageLines: 5, totalLines: 90, effort: .normal, droppedRisk: 1, check: nil)
        XCTAssertTrue(one.contains("1 risk-flagged line didn't fit"))
        let many = LongSessionNote.coverageLabel(digestParts: 3, passageLines: 5, totalLines: 90, effort: .normal, droppedRisk: 4, check: nil)
        XCTAssertTrue(many.contains("4 risk-flagged lines didn't fit"))
        XCTAssertTrue(one.contains("didn't fit or were shortened"))
        let none = LongSessionNote.coverageLabel(digestParts: 3, passageLines: 5, totalLines: 90, effort: .normal, droppedRisk: 0, check: nil)
        XCTAssertFalse(none.contains("risk-flagged"))
    }

    func testCoverageWordingSingularAndOmitted() {
        let one = LongSessionNote.coverageLabel(digestParts: 1, passageLines: 5, totalLines: 90, effort: .normal, check: nil)
        XCTAssertTrue(one.contains("(1 part)"))
        XCTAssertFalse(one.contains("1 parts"))
        let cut = LongSessionNote.coverageLabel(digestParts: 3, digestShortened: true, passageLines: 5, totalLines: 90, effort: .normal, check: nil)
        XCTAssertTrue(cut.contains("(3 parts, shortened to fit)"))
        let gone = LongSessionNote.coverageLabel(digestParts: 3, digestOmitted: true, passageLines: 5, totalLines: 90, effort: .normal, check: nil)
        XCTAssertTrue(gone.contains("no summary of the whole session"))
        XCTAssertFalse(gone.contains("shortened"))
    }

    func testAPassageSearchStopsWhenCancelled() async {
        let text = tightRiskTranscript()
        let task = Task.detached { () -> Int in
            while !Task.isCancelled { await Task.yield() }
            return LongSessionNote.passages(in: text, format: .soap, limit: 6_000, riskLimit: 300, phrases: LongSessionNote.defaultRiskPhrases).lineCount
        }
        task.cancel()
        let lines = await task.value
        XCTAssertEqual(lines, 0)
    }

    // MARK: - The check keeps risk

    private let checkedDraft = """
        ## Subjective
        The client slept badly and worried a lot about work. Client denies SI/HI. She said she stopped taking her medication in May.

        ## Plan
        Try the sleep diary next week and review the safety plan together.
        """

    func testACorrectionThatDropsADenialIsRejected() {
        XCTAssertTrue(LongSessionNote.plausiblyComplete(checkedDraft, draft: checkedDraft, format: .soap, phrases: defaultPhrases))
        let dropped = checkedDraft.replacingOccurrences(of: " Client denies SI/HI.", with: "")
        XCTAssertFalse(LongSessionNote.plausiblyComplete(dropped, draft: checkedDraft, format: .soap, phrases: defaultPhrases))
        for variant in ["Client denies SI.", "Client endorses SI.", "Client denies SI and HI."] {
            let draft = checkedDraft.replacingOccurrences(of: "Client denies SI/HI.", with: variant)
            let gone = draft.replacingOccurrences(of: variant, with: "")
            XCTAssertFalse(LongSessionNote.plausiblyComplete(gone, draft: draft, format: .soap, phrases: defaultPhrases), variant)
            XCTAssertTrue(LongSessionNote.plausiblyComplete(draft, draft: draft, format: .soap, phrases: defaultPhrases), variant)
        }
    }

    func testACorrectionThatDropsAStatedRiskIsRejected() {
        let draft = checkedDraft + "\nShe said \"I don't want to be here anymore\" in week two."
        let gone = draft.replacingOccurrences(of: "She said \"I don't want to be here anymore\" in week two.", with: "She was low in week two and worried.")
        XCTAssertFalse(LongSessionNote.plausiblyComplete(gone, draft: draft, format: .soap, phrases: defaultPhrases))
    }

    func testACorrectionThatAddsADenialIsRejected() {
        let draft = checkedDraft.replacingOccurrences(of: " Client denies SI/HI.", with: "")
        let added = checkedDraft
        XCTAssertFalse(LongSessionNote.plausiblyComplete(added, draft: draft, format: .soap, phrases: defaultPhrases))
    }

    func testHeadingsMustBeWholeLines() {
        let sneaky = checkedDraft.replacingOccurrences(of: "## Plan", with: "Next steps").replacingOccurrences(of: "review the safety plan", with: "review the Plan")
        XCTAssertFalse(LongSessionNote.plausiblyComplete(sneaky, draft: checkedDraft, format: .soap, phrases: defaultPhrases), "'Plan' in the body is not the heading")
    }

    // MARK: - Round 3

    func testBenignSessionFlagsNoLines() {
        let pool = [
            "I hit my target at work this quarter", "I beat him at chess on Sunday", "I choked up when I spoke",
            "There is a threat of layoffs", "I cut the onions for dinner", "My grandmother died last year",
            "The photo shoot went well", "Work stress and deadlines again", "We won the soccer match", "I was a burden at the office meeting",
            "The knife set in the kitchen is new", "Abuse of the expense system annoys me", "He took a shot at the goal", "The SI units were converted",
            "I missed my pills once and the pharmacy called", "Death of a salesman was on at the theatre",
        ]
        for phrase in pool { XCTAssertFalse(isRisk(phrase), phrase) }
        let lines = (0..<3_000).map { "[\($0)] Client: \(pool[$0 % pool.count]), number \($0)." }
        let text = lines.joined(separator: "\n")
        XCTAssertEqual(LongSessionNote.strongCost(in: text, phrases: defaultPhrases), 0)
        let found = LongSessionNote.passages(in: text, format: .soap, limit: 6_000, riskLimit: 1_000, phrases: defaultPhrases)
        XCTAssertEqual(found.droppedRisk, 0)
        XCTAssertGreaterThan(found.lineCount, 20, "topics still get the room")
        let label = LongSessionNote.coverageLabel(digestParts: 3, passageLines: found.lineCount, totalLines: 3_000, effort: .normal, droppedRisk: found.droppedRisk, check: nil)
        XCTAssertFalse(label.contains("risk-flagged"))
    }

    func testStrongLinesAreCappedAtTwoThirdsOfTheRoom() {
        let lines = (0..<200).map { "[\($0)] Client: Some days I want to kill myself, thought number \($0) to share." }
        let found = LongSessionNote.passages(in: lines.joined(separator: "\n"), format: .soap, limit: 3_000, riskLimit: 500, phrases: defaultPhrases)
        XCTAssertLessThanOrEqual(found.text.count, 3_000 + found.lineCount)
        XCTAssertGreaterThan(found.droppedRisk, 0)
    }

    func testNothingFitsStillReportsDroppedRiskLines() {
        let found = LongSessionNote.passages(in: tightRiskTranscript(), format: .soap, limit: 0, riskLimit: 0, phrases: defaultPhrases)
        XCTAssertEqual(found.text, "")
        XCTAssertEqual(found.droppedRisk, 22)
    }

    // MARK: - The check leaves risk sentences alone

    func testFlippedRiskStatementsAreRejected() {
        let draft = "## Subjective\nThe client is suicidal. Client endorses SI. She slept badly.\n\n## Plan\nTry the sleep diary next week and review safety."
        XCTAssertEqual(LongSessionNote.rejection(draft.replacingOccurrences(of: "is suicidal", with: "is not suicidal"), draft: draft, format: .soap, phrases: defaultPhrases), .alteredRisk)
        XCTAssertEqual(LongSessionNote.rejection(draft.replacingOccurrences(of: "endorses SI", with: "SI absent"), draft: draft, format: .soap, phrases: defaultPhrases), .alteredRisk)
    }

    func testRemovedMovedOrInventedRiskStatementsAreRejected() {
        let draft = "## Subjective\nShe slept badly all week. Client denies SI/HI. She worried about work.\n\n## Plan\nTry the sleep diary next week and review safety."
        let removed = draft.replacingOccurrences(of: " Client denies SI/HI.", with: "")
        XCTAssertEqual(LongSessionNote.rejection(removed, draft: draft, format: .soap, phrases: defaultPhrases), .alteredRisk)
        let moved = removed.replacingOccurrences(of: "review safety.", with: "review safety. Client denies SI/HI.")
        XCTAssertEqual(LongSessionNote.rejection(moved, draft: draft, format: .soap, phrases: defaultPhrases), .alteredRisk, "same sentence, wrong section")
        let calm = draft.replacingOccurrences(of: " Client denies SI/HI.", with: "")
        let invented = draft
        XCTAssertEqual(LongSessionNote.rejection(invented, draft: calm, format: .soap, phrases: defaultPhrases), .alteredRisk)
    }

    func testACorrectionThatLeavesRiskSentencesAloneIsAccepted() {
        let draft = "## Subjective\nShe slept badly all week. Client denies SI/HI. She worried about work.\n\n## Plan\nTry the sleep diary next week and review safety."
        let fixed = draft.replacingOccurrences(of: "slept badly all week", with: "slept poorly most of the week")
        XCTAssertNil(LongSessionNote.rejection(fixed, draft: draft, format: .soap, phrases: defaultPhrases))
        XCTAssertTrue(LongSessionNote.CheckOutcome.alteredRisk.text.contains("changed a risk statement"))
    }


    func testACancelledURLRequestInTheCheckCountsAsStopped() async throws {
        let text = syntheticTranscript(minutes: 120)
        let result = try await run(transcript: text, effort: .focus) { $0.checkError = URLError(.cancelled) }
        XCTAssertTrue(try XCTUnwrap(result.coverage.last).contains("Stopped before the check finished"))
    }

    // MARK: - Passages

    func testPassagesStayInOrderWithinLimitAndMarkGaps() {
        let text = syntheticTranscript(minutes: 120)
        let found = LongSessionNote.passages(in: text, format: .soap, limit: 3_000, riskLimit: 800, phrases: defaultPhrases)
        XCTAssertLessThanOrEqual(found.text.count, 3_000 + found.lineCount)
        XCTAssertGreaterThan(found.lineCount, 0)
        XCTAssertTrue(found.text.contains("[…]"))
        let stamps = found.text.split(separator: "\n").compactMap { TranscriptTimeline.leadingSeconds(of: String($0)) }
        XCTAssertEqual(stamps, stamps.sorted())
    }

    // MARK: - Concurrency and stages

    func testInferenceQueueReportsAJobByLabel() async throws {
        let queue = InferenceQueue()
        XCTAssertFalse(queue.hasJob(labelled: "progress note A"))
        queue.enqueue(kind: .note, label: "progress note A") { try? await Task.sleep(nanoseconds: 200_000_000) }
        XCTAssertTrue(queue.hasJob(labelled: "progress note A"))
        XCTAssertFalse(queue.hasJob(labelled: "progress note B"))
    }

    func testNoBackgroundDigestStartsWhileANoteBuildsInline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LongNote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root)
        let patient = try store.createPatient(name: "Dana Cole")
        let session = try store.createSession(for: patient)
        let text = syntheticTranscript(minutes: 40)
        try store.saveTranscript(text, for: patient, session: session)
        let stub = StubModel()
        stub.digestDelay = 60_000_000
        let service = AssistantService(assistant: stub, model: "m")
        let builder = DigestBuilder(queue: InferenceQueue())

        let inline = Task { try await builder.buildInline(sessionID: session.id, transcript: text, service: service, live: { _, _ in }) }
        for _ in 0..<200 where stub.prompts.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        builder.ensureDigest(for: patient, session: session, transcript: text, store: store, service: service)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(builder.progress[session.id], "no second build started")
        _ = try await inline.value
    }

    func testStageProgressIsNotClobberedAndLateEventsAreDropped() {
        let runner = ChatStreamRunner()
        let first = Date(timeIntervalSince1970: 1)
        let second = Date(timeIntervalSince1970: 2)
        runner.update(started: nil) { $0 = AIRunProgress(readTitle: "Checking", writeTitle: "w", startedAt: second) }
        runner.update(started: first) { $0.readTitle = "late" }
        XCTAssertEqual(runner.progress.readTitle, "Checking")
        // A stats event from the runner's own reporter is ignored once stages are reported.
        runner.apply(.finished(AIRunStats(promptTokens: 1, expectedPromptTokens: 5_000)), run: runner.currentRun)
        XCTAssertNil(runner.progress.stats)
    }

    // MARK: - Saved coverage

    func testCoverageIsSavedWithTheNoteAndClearedByAWholeSessionNote() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LongNoteSave-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root)
        let patient = try store.createPatient(name: "Dana Cole")
        let session = try store.createSession(for: patient)
        try store.saveGeneratedNote("S: a", for: patient, session: session, format: .soap, coverage: "Read: partly")
        XCTAssertEqual(store.noteCoverage(for: patient, session: session, format: .soap), "Read: partly")
        XCTAssertNil(store.noteCoverage(for: patient, session: session, format: .dap))
        XCTAssertFalse(Store.isNoteFileName("note.soap.coverage.txt"))
        XCTAssertTrue(Store.isNoteSidecarFileName("note.soap.coverage.txt"))
        try store.saveGeneratedNote("S: b", for: patient, session: session, format: .soap)
        XCTAssertNil(store.noteCoverage(for: patient, session: session, format: .soap))
    }

    func testOverflowFocusNotePassesGrammarOnlyToDraftAndCheckStages() async throws {
        let text = syntheticTranscript(minutes: 120)
        let stub = StubModel()
        stub.checkResponse = """
        ## Subjective
        Client reported brief thoughts of hurting myself and stated "No, I would never do it."
        ## Objective
        Alert and engaged.
        ## Assessment
        Stable mood.
        ## Plan
        Follow up next week.
        """
        var service = AssistantService(assistant: stub, model: "m")
        service.budget = ContextBudget(tokens: 8192)
        let stream = LongSessionNote.stream(
            format: .soap, transcript: text, effort: .focus, riskPhrases: defaultPhrases, service: service,
            builder: DigestBuilder(queue: InferenceQueue()), sessionID: UUID(),
            loadDigest: { nil }, saveDigest: { _ in },
            live: { _, _ in }, coverage: { _ in })
        for try await _ in stream {}

        // All calls except the last two are digest stages (.digest, nil grammar);
        // the last two are the draft and Focus check stages (.note, SOAP grammar).
        XCTAssertGreaterThanOrEqual(stub.recordedCalls.count, 3)
        let digestCalls = stub.recordedCalls.dropLast(2)
        let noteCalls = Array(stub.recordedCalls.suffix(2))
        XCTAssertTrue(digestCalls.allSatisfy { $0.task == .digest && $0.grammar == nil })
        XCTAssertEqual(noteCalls.map(\.task), [.note, .note])
        XCTAssertEqual(noteCalls.map(\.grammar), [ProgressNoteFormat.soap.grammar, ProgressNoteFormat.soap.grammar])
    }

    func testFastEffortUsesSmallerPromptThanNormalAndKeepsRiskLines() async throws {
        let text = syntheticTranscript(minutes: 120)
        let digest = storedDigest(for: text)
        let fast = try await run(transcript: text, effort: .fast, stored: digest)
        let normal = try await run(transcript: text, effort: .normal, stored: digest)

        let fastPrompt = try XCTUnwrap(fast.prompts.last)
        let normalPrompt = try XCTUnwrap(normal.prompts.last)
        XCTAssertLessThan(fastPrompt.count, normalPrompt.count)
        XCTAssertTrue(fastPrompt.contains("think about hurting myself"))
        XCTAssertTrue(fastPrompt.contains("I would never do it"))
        XCTAssertTrue(try XCTUnwrap(fast.coverage.last).contains("· Fast."))
    }
}
