import XCTest
@testable import Aletheia

/// A stub model that answers by the kind of prompt it is given and records them all.
private final class StubModel: Assistant, @unchecked Sendable {
    var prompts: [String] = []
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
        format: ProgressNoteFormat = .soap, configure: (StubModel) -> Void = { _ in }
    ) async throws -> Run {
        let stub = StubModel()
        configure(stub)
        var service = AssistantService(assistant: stub, model: "m")
        service.budget = ContextBudget(tokens: tokens)
        var coverage: [String] = []
        let stream = LongSessionNote.stream(
            format: format, transcript: transcript, effort: effort, service: service,
            builder: DigestBuilder(queue: InferenceQueue()), sessionID: UUID(),
            loadDigest: { stored }, saveDigest: { _ in },
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
        let found = LongSessionNote.passages(in: text, format: .soap, limit: 5_000, riskLimit: 2_000)
        XCTAssertEqual(found.lineCount, 3)
        XCTAssertEqual(LongSessionNote.nonBlankLines(text).count, 3)
    }

    // MARK: - Risk

    func testRiskParaphrasesAreFoundAndSurviveATightRoom() {
        var lines = (0..<400).map { String(format: "[%02d:%02d] You: Tell me more about topic number %d, the safe route and a drink with friends.", $0 / 3, ($0 % 3) * 20, $0) }
        lines[300] = "[100:00] Client: Honestly I don't want to be here anymore."
        lines[350] = "[116:40] Client: I have been thinking about ending it."
        lines[200] = "[66:40] Client: I took too many pills last year."
        let found = LongSessionNote.passages(in: lines.joined(separator: "\n"), format: .soap, limit: 1_500, riskLimit: 900)
        XCTAssertTrue(found.text.contains("don't want to be here anymore"))
        XCTAssertTrue(found.text.contains("thinking about ending it"))
        XCTAssertTrue(found.text.contains("pills"))
        XCTAssertLessThanOrEqual(found.text.count, 1_500 + found.lineCount)
    }

    func testExplicitRiskOutranksGenericWords() {
        // Many generic "drinking"/"safe" lines come first; the one explicit line must still make a small risk room.
        var lines = (0..<200).map { "[\($0)] Client: I was drinking again and felt safe at home, drinking with Sam." + String(repeating: " x", count: 5) + " \($0)" }
        lines[190] = "[190] Client: I want to kill myself some days."
        let found = LongSessionNote.passages(in: lines.joined(separator: "\n"), format: .soap, limit: 800, riskLimit: 300)
        XCTAssertTrue(found.text.contains("kill myself"))
    }

    func testRiskLinesReachThePromptOnATightBudget() async throws {
        var lines = (0..<600).map { String(format: "[%02d:%02d] You: Tell me more about topic number %d and how the week went.", $0 / 3, ($0 % 3) * 20, $0) }
        lines[500] = "[166:40] Client: I don't want to be here anymore."
        lines[510] = "[170:00] Client: I have been thinking about ending it."
        let text = lines.joined(separator: "\n")
        for effort in [AnswerEffort.normal, .focus] {
            let result = try await run(transcript: text, effort: effort, stored: storedDigest(for: text), tokens: 4600)
            let final = try XCTUnwrap(result.prompts.first)
            XCTAssertTrue(final.contains("don't want to be here anymore"), "\(effort)")
            XCTAssertTrue(final.contains("thinking about ending it"), "\(effort)")
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
        XCTAssertTrue(check.contains("Draft note:\nDRAFT NOTE"))
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
        XCTAssertTrue(LongSessionNote.plausiblyComplete(draft.replacingOccurrences(of: "badly", with: "poorly"), draft: draft, format: .soap))
        XCTAssertFalse(LongSessionNote.plausiblyComplete("Subjective\nSlept.", draft: draft, format: .soap))
        XCTAssertFalse(LongSessionNote.plausiblyComplete(draft.replacingOccurrences(of: "Plan", with: "Next"), draft: draft, format: .soap))
    }

    // MARK: - Risk lexicon

    /// The most specific tier (0 is strongest) that matches `line`, or nil.
    private func riskTier(_ line: String) -> Int? {
        let range = NSRange(line.startIndex..., in: line)
        return LongSessionNote.riskRegexes().firstIndex { $0.firstMatch(in: line, range: range) != nil }
    }

    func testAllRiskPatternsCompile() {
        XCTAssertEqual(LongSessionNote.riskRegexes().count, 3)
    }

    func testCommonRiskLanguageMatchesAStrongTier() {
        let strong = [
            "I don't want to be here", "I don\u{2019}t want to be here", "I don't want to live", "I don\u{2019}t want to live",
            "I'm going to shoot him", "She punches me and chokes me", "I want to jump off the bridge",
            "I can't go on", "I can\u{2019}t do this anymore", "I don't see the point anymore", "I don\u{2019}t see the point anymore",
            "life isn't worth living", "no reason to keep going", "I wish I wouldn't wake up", "I wish I wouldn\u{2019}t wake up",
            "I hurt my kids", "my husband raped me", "he threatens me, I'm scared to go home",
            "He hits me when he drinks", "Client denies SI", "Client denies SI/HI", "No SI", "Client denies SI and HI",
            "Reports SH last month", "history of SA",
        ]
        for phrase in strong {
            XCTAssertEqual(riskTier(phrase), 0, "\(phrase) should be tier 1")
        }
    }

    func testStoppingMedicationIsTierTwo() {
        XCTAssertEqual(riskTier("I stopped taking my medication"), 1)
        XCTAssertEqual(riskTier("I haven\u{2019}t been taking my meds"), 1)
        XCTAssertEqual(riskTier("I haven't been taking my meds"), 1)
        XCTAssertEqual(riskTier("She is off her meds again"), 2, "skipping is a weak sign")
    }

    func testHitsMeReachesAHighTierNotJustTheDrinkWord() {
        XCTAssertEqual(riskTier("He hits me when he drinks"), 0)
        XCTAssertEqual(riskTier("He drinks on weekends"), 2)
    }

    func testAbbreviationsAreCaseSensitive() {
        XCTAssertNil(riskTier("hi there, how was the si"), "lowercase si/hi is not an abbreviation")
        XCTAssertNil(riskTier("Hi, how are you"))
    }

    // MARK: - Risk room

    private func tightRiskTranscript() -> String {
        var lines = (0..<300).map { String(format: "[%02d:%02d] You: Tell me more about topic number %d and how it went.", $0 / 3, ($0 % 3) * 20, $0) }
        for i in 10..<30 { lines[i] = "[00:\(i)] Client: Some days I want to kill myself, thought \(i)." }
        lines[280] = "[93:20] Client: I took too many pills last year."
        lines[290] = "[96:40] Client: I don't want to be here anymore."
        return lines.joined(separator: "\n")
    }

    func testLateRiskLinesSurviveEarlyChatterOnATightRoom() {
        let found = LongSessionNote.passages(in: tightRiskTranscript(), format: .soap, limit: 1_000, riskLimit: 300)
        XCTAssertTrue(found.text.contains("don't want to be here"), "the late tier-1 line must not be starved")
        XCTAssertTrue(found.text.contains("pills") || found.droppedRisk > 0, "tier 2 is kept or reported")
        XCTAssertGreaterThan(found.droppedRisk, 0, "about 20 lines cannot all fit in 1,000 characters")
        XCTAssertLessThanOrEqual(found.text.count, 1_000 + found.lineCount)
    }

    func testEveryRiskLineIsKeptWhenThereIsRoom() {
        let found = LongSessionNote.passages(in: tightRiskTranscript(), format: .soap, limit: 6_000, riskLimit: 300)
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
        let bare = LongSessionNote.passages(in: text, format: .soap, limit: 400, riskLimit: 0)
        XCTAssertFalse(bare.text.contains("chat number 24"))
        let roomy = LongSessionNote.passages(in: text, format: .soap, limit: 400, riskLimit: 300)
        XCTAssertTrue(roomy.text.contains("chat number 24"))
    }

    func testAFlaggedLineLongerThanTheRoomIsCutWithAMarker() {
        let long = "[00:00] Client: I want to kill myself " + String(repeating: "and so on ", count: 500)
        let found = LongSessionNote.passages(in: "[00:00] You: hello\n" + long, format: .soap, limit: 400, riskLimit: 100)
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
            return LongSessionNote.passages(in: text, format: .soap, limit: 6_000, riskLimit: 300).lineCount
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
        XCTAssertTrue(LongSessionNote.plausiblyComplete(checkedDraft, draft: checkedDraft, format: .soap))
        let dropped = checkedDraft.replacingOccurrences(of: " Client denies SI/HI.", with: "")
        XCTAssertFalse(LongSessionNote.plausiblyComplete(dropped, draft: checkedDraft, format: .soap))
        for variant in ["Client denies SI.", "No SI.", "Client denies SI and HI."] {
            let draft = checkedDraft.replacingOccurrences(of: "Client denies SI/HI.", with: variant)
            let gone = draft.replacingOccurrences(of: variant, with: "")
            XCTAssertFalse(LongSessionNote.plausiblyComplete(gone, draft: draft, format: .soap), variant)
            XCTAssertTrue(LongSessionNote.plausiblyComplete(draft, draft: draft, format: .soap), variant)
        }
    }

    func testACorrectionThatDropsAStatedRiskIsRejected() {
        let draft = checkedDraft + "\nShe said \"I don't want to be here anymore\" in week two."
        let gone = draft.replacingOccurrences(of: "She said \"I don't want to be here anymore\" in week two.", with: "She was low in week two and worried.")
        XCTAssertFalse(LongSessionNote.plausiblyComplete(gone, draft: draft, format: .soap))
        let medication = checkedDraft.replacingOccurrences(of: "She said she stopped taking her medication in May.", with: "She talked about May and her prescriptions at length.")
        XCTAssertFalse(LongSessionNote.plausiblyComplete(medication, draft: checkedDraft, format: .soap))
    }

    func testACorrectionThatAddsADenialIsRejected() {
        let draft = checkedDraft.replacingOccurrences(of: " Client denies SI/HI.", with: "")
        let added = checkedDraft
        XCTAssertFalse(LongSessionNote.plausiblyComplete(added, draft: draft, format: .soap))
    }

    func testHeadingsMustBeWholeLines() {
        let sneaky = checkedDraft.replacingOccurrences(of: "## Plan", with: "Next steps").replacingOccurrences(of: "review the safety plan", with: "review the Plan")
        XCTAssertFalse(LongSessionNote.plausiblyComplete(sneaky, draft: checkedDraft, format: .soap), "'Plan' in the body is not the heading")
    }

    // MARK: - Round 3

    func testBenignTalkFlagsNoStrongLines() {
        let pool = [
            "I hit my target at work this quarter", "I beat him at chess on Sunday", "I choked up when I spoke",
            "There is a threat of layoffs", "I cut the onions for dinner", "My grandmother died last year",
            "The photo shoot went well", "Work stress and deadlines again", "We won the soccer match", "I was a burden at the office meeting",
            "The knife set in the kitchen is new", "Abuse of the expense system annoys me", "He took a shot at the goal", "The SI units were converted",
            "I missed my pills once and the pharmacy called", "Death of a salesman was on at the theatre",
        ]
        for phrase in pool {
            XCTAssertTrue([nil, 2].contains(riskTier(phrase)), "\(phrase) must not be a strong line")
        }
        let lines = (0..<3_000).map { "[\($0)] Client: \(pool[$0 % pool.count]), number \($0)." }
        let text = lines.joined(separator: "\n")
        XCTAssertEqual(LongSessionNote.riskCost(in: text), 0)
        let found = LongSessionNote.passages(in: text, format: .soap, limit: 6_000, riskLimit: 1_000)
        XCTAssertEqual(found.droppedRisk, 0)
        XCTAssertGreaterThan(found.lineCount, 20, "topics still get the room")
        let label = LongSessionNote.coverageLabel(digestParts: 3, passageLines: found.lineCount, totalLines: 3_000, effort: .normal, droppedRisk: found.droppedRisk, check: nil)
        XCTAssertFalse(label.contains("risk-flagged"))
    }

    func testMoreRiskLanguageIsStrong() {
        let tierOne = [
            "he said he would kill me", "he's going to kill me", "I shot myself", "going to hang myself",
            "I want to go to sleep and not wake up", "everyone would be better without me", "nobody would miss me",
            "I don't see a reason to go on", "life isn't worth it", "what's the point of anything", "I give up",
            "I might walk into traffic", "he pushed me down the stairs", "he grabbed my throat",
            "he forced himself on me", "he touched me inappropriately", "kms", "I have been starving myself",
            "I've been cutting", "I cut myself", "I would be better off dead", "he beat her up",
        ]
        for phrase in tierOne { XCTAssertEqual(riskTier(phrase), 0, "\(phrase) should be tier 1") }
        let tierTwo = ["I swallowed a bottle of aspirin", "I took all my pills", "I overdosed on sleeping tablets", "he has a gun at home"]
        for phrase in tierTwo { XCTAssertEqual(riskTier(phrase), 1, "\(phrase) should be tier 2") }
        XCTAssertEqual(riskTier("I give up on this recipe"), nil)
    }

    func testStrongLinesAreCappedAtTwoThirdsOfTheRoom() {
        let lines = (0..<200).map { "[\($0)] Client: Some days I want to kill myself, thought number \($0) to share." }
        let found = LongSessionNote.passages(in: lines.joined(separator: "\n"), format: .soap, limit: 3_000, riskLimit: 500)
        XCTAssertLessThanOrEqual(found.text.count, 3_000 + found.lineCount)
        XCTAssertGreaterThan(found.droppedRisk, 0)
    }

    func testNothingFitsStillReportsDroppedRiskLines() {
        let found = LongSessionNote.passages(in: tightRiskTranscript(), format: .soap, limit: 0, riskLimit: 0)
        XCTAssertEqual(found.text, "")
        XCTAssertEqual(found.droppedRisk, 22)
    }

    // MARK: - The check leaves risk sentences alone

    func testFlippedRiskStatementsAreRejected() {
        let draft = "## Subjective\nThe client is suicidal. Client endorses SI. She slept badly.\n\n## Plan\nTry the sleep diary next week and review safety."
        XCTAssertEqual(LongSessionNote.rejection(draft.replacingOccurrences(of: "is suicidal", with: "is not suicidal"), draft: draft, format: .soap), .alteredRisk)
        XCTAssertEqual(LongSessionNote.rejection(draft.replacingOccurrences(of: "endorses SI", with: "SI absent"), draft: draft, format: .soap), .alteredRisk)
    }

    func testRemovedMovedOrInventedRiskStatementsAreRejected() {
        let draft = "## Subjective\nShe slept badly all week. Client denies SI/HI. She worried about work.\n\n## Plan\nTry the sleep diary next week and review safety."
        let removed = draft.replacingOccurrences(of: " Client denies SI/HI.", with: "")
        XCTAssertEqual(LongSessionNote.rejection(removed, draft: draft, format: .soap), .alteredRisk)
        let moved = removed.replacingOccurrences(of: "review safety.", with: "review safety. Client denies SI/HI.")
        XCTAssertEqual(LongSessionNote.rejection(moved, draft: draft, format: .soap), .alteredRisk, "same sentence, wrong section")
        let calm = draft.replacingOccurrences(of: " Client denies SI/HI.", with: "")
        let invented = draft
        XCTAssertEqual(LongSessionNote.rejection(invented, draft: calm, format: .soap), .alteredRisk)
    }

    func testACorrectionThatLeavesRiskSentencesAloneIsAccepted() {
        let draft = "## Subjective\nShe slept badly all week. Client denies SI/HI. She worried about work.\n\n## Plan\nTry the sleep diary next week and review safety."
        let fixed = draft.replacingOccurrences(of: "slept badly all week", with: "slept poorly most of the week")
        XCTAssertNil(LongSessionNote.rejection(fixed, draft: draft, format: .soap))
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
        let found = LongSessionNote.passages(in: text, format: .soap, limit: 3_000, riskLimit: 800)
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
}
