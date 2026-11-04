import XCTest
@testable import Aletheia

private final class PromptCapturingAssistant: Assistant, @unchecked Sendable {
    var systems: [String] = []
    var prompts: [String] = []
    func isReachable() async -> Bool { true }
    func listModels() async throws -> [String] { [] }
    func hasModel(_ name: String) async -> Bool { true }
    func generate(model: String, system: String, prompt: String) async throws -> String {
        systems.append(system)
        prompts.append(prompt)
        return "ok"
    }
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {}
}

/// Depth, for notes and Ask alike: one type supplies each level's guidance
/// for every kind of output, every surface carries the same clarity rule, and
/// Ask adds the rule that each answer takes its own question on its own terms.
final class AnswerDepthTests: XCTestCase {
    private let transcript = "[00:00] Call audio: I barely slept this week."

    // MARK: The type

    func testDefaultIsNaturalAndTheLevelsAreFixed() {
        XCTAssertEqual(AnswerDepth.default, .natural)
        XCTAssertEqual(AnswerDepth.allCases, [.concise, .natural, .detailed])
        XCTAssertEqual(AnswerDepth.allCases.map(\.displayName), ["Concise", "Natural", "Detailed"])
        XCTAssertEqual(AnswerDepth.label, "Depth")
        // Values stored before the rename still load.
        XCTAssertEqual(AnswerDepth.allCases.map(\.rawValue), ["concise", "natural", "detailed"])
    }

    func testEachFeatureHasItsOwnBlurbForEachLevel() {
        for feature in DepthFeature.allCases {
            let blurbs = AnswerDepth.allCases.map { $0.blurb(for: feature) }
            XCTAssertEqual(Set(blurbs).count, 3, "\(feature)")
            XCTAssertFalse(blurbs.contains(""), "\(feature)")
        }
    }

    func testEachLevelHasDistinctGuidanceForEveryOutput() {
        for output in DepthOutput.allCases {
            XCTAssertEqual(Set(AnswerDepth.allCases.map { $0.guidance(for: output) }).count, 3, "\(output)")
        }
    }

    func testAskTargets() {
        XCTAssertTrue(AnswerDepth.concise.target(for: .answer).contains("one to three sentences"))
        XCTAssertTrue(AnswerDepth.natural.target(for: .answer).contains("a short paragraph or two"))
        XCTAssertTrue(AnswerDepth.detailed.target(for: .answer).contains("full answer"))
    }

    func testOnlyAskCarriesTheConversationRule() {
        for level in AnswerDepth.allCases {
            XCTAssertTrue(level.instructions(for: .answer).contains(AnswerDepth.conversationRule))
            XCTAssertFalse(level.instructions(for: .summary).contains(AnswerDepth.conversationRule))
            XCTAssertFalse(level.instructions(for: .structuredNote).contains(AnswerDepth.conversationRule))
        }
        XCTAssertTrue(AnswerDepth.conversationRule.contains("Answer the latest question on its own terms."))
        XCTAssertTrue(AnswerDepth.conversationRule.contains("use earlier turns only as context"))
    }

    // MARK: Settings

    func testNoteAndAskDepthsDefaultToNaturalAndPersistSeparately() {
        let suite = "depth-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.noteDepth, .natural)
        XCTAssertEqual(settings.askDepth, .natural)

        settings.noteDepth = .detailed
        settings.askDepth = .concise
        let reopened = AppSettings(defaults: defaults)
        XCTAssertEqual(reopened.noteDepth, .detailed)
        XCTAssertEqual(reopened.askDepth, .concise)
    }

    func testNoteDepthLoadsFromTheSettingSavedBeforeTheRename() {
        let suite = "depth-legacy-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("concise", forKey: "summaryVerbosity")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.noteDepth, .concise)
        XCTAssertEqual(settings.askDepth, .natural, "Ask has its own setting")
    }

    // MARK: Notes

    func testSummaryPromptCarriesTheChosenDepthAndClarityRule() {
        for level in AnswerDepth.allCases {
            let prompt = Prompts.progressNote(format: .narrative, transcript: transcript, depth: level)
            XCTAssertTrue(prompt.contains(level.guidance(for: .summary)), "\(level) guidance missing")
            XCTAssertTrue(prompt.contains(AnswerDepth.clarityRule), "\(level) clarity rule missing")
            for other in AnswerDepth.allCases where other != level {
                XCTAssertFalse(prompt.contains(other.guidance(for: .summary)), "\(level) prompt carries \(other) guidance")
            }
        }
    }

    func testSummaryPromptDefaultsToNatural() {
        let prompt = Prompts.progressNote(format: .narrative, transcript: transcript)
        XCTAssertTrue(prompt.contains(AnswerDepth.natural.guidance(for: .summary)))
    }

    func testStructuredFormatsCarryTheNoteGuidanceAndClarityRule() {
        for format in ProgressNoteFormat.allCases where format != .narrative {
            for level in AnswerDepth.allCases {
                let prompt = Prompts.progressNote(format: format, transcript: transcript, depth: level)
                XCTAssertTrue(prompt.contains(level.guidance(for: .structuredNote)), "\(format) \(level) guidance missing")
                XCTAssertTrue(prompt.contains(AnswerDepth.clarityRule))
                XCTAssertFalse(prompt.contains(level.guidance(for: .summary)), "\(format) should not carry the Summary word range")
                XCTAssertFalse(prompt.contains(AnswerDepth.conversationRule))
            }
        }
    }

    func testLocalRequestPassesTheSettingThrough() {
        let request = LocalLLMRequest.progressNote(format: .narrative, transcript: "t", depth: .concise)
        XCTAssertTrue(request.prompt.contains(AnswerDepth.concise.guidance(for: .summary)))
    }

    // MARK: Ask

    @MainActor
    func testSessionAskSystemPromptCarriesTheChosenDepth() async throws {
        for level in AnswerDepth.allCases {
            assertAskInstructions(try await sessionAsk(depth: level).system, level)
        }
    }

    @MainActor
    func testPatientAskSystemPromptCarriesTheChosenDepth() async throws {
        for level in AnswerDepth.allCases {
            assertAskInstructions(try await patientAsk(depth: level).system, level)
        }
    }

    /// Notes and both Ask paths take their depth wording from `AnswerDepth`
    /// alone: the same level's guidance (for each surface's output) and the
    /// same clarity rule.
    @MainActor
    func testNotesAndBothAskPathsShareOneSource() async throws {
        for level in AnswerDepth.allCases {
            let note = Prompts.progressNote(format: .narrative, transcript: transcript, depth: level)
            let structured = Prompts.progressNote(format: .soap, transcript: transcript, depth: level)
            let session = try await sessionAsk(depth: level).system
            let patient = try await patientAsk(depth: level).system

            XCTAssertTrue(note.contains(level.instructions(for: .summary)), "\(level) note")
            XCTAssertTrue(structured.contains(level.instructions(for: .structuredNote)), "\(level) structured note")
            XCTAssertTrue(session.contains(level.instructions(for: .answer)), "\(level) session Ask")
            XCTAssertTrue(patient.contains(level.instructions(for: .answer)), "\(level) patient Ask")
            for prompt in [note, structured, session, patient] {
                XCTAssertTrue(prompt.contains(AnswerDepth.clarityRule), "\(level)")
                XCTAssertTrue(prompt.contains("Depth: \(level.rawValue). "), "\(level)")
                XCTAssertTrue(prompt.contains(level.form), "\(level)")
            }
        }
    }

    /// Earlier turns come first; the question being asked is the last thing
    /// the model reads, alone. The session's text is in the system turn, ahead
    /// of the earlier answers it could be copied from.
    @MainActor
    func testTheLatestQuestionComesLastInBothAskPaths() async throws {
        let history = [
            ChatMessage(role: .user, text: "How did she sleep?"),
            ChatMessage(role: .assistant, text: "She slept badly most nights."),
        ]
        let question = "What did she say about work?"
        let session = try await sessionAsk(depth: .natural, history: history, question: question)
        let patient = try await patientAsk(depth: .natural, history: history, question: question)
        XCTAssertTrue(session.system.contains("Patient discussed sleep."))
        XCTAssertTrue(patient.system.contains("I slept badly."))
        for (system, prompt) in [(session.system, session.prompt), (patient.system, patient.prompt)] {
            XCTAssertTrue(prompt.hasSuffix(Prompts.chatQuestion(question)), prompt)
            XCTAssertFalse(system.contains(question), "the question is not in the system turn")
            XCTAssertFalse(prompt.contains("Patient discussed sleep."))
            XCTAssertFalse(prompt.contains("I slept badly."))
            let earlier = try XCTUnwrap(prompt.range(of: "She slept badly most nights."))
            let latest = try XCTUnwrap(prompt.range(of: question))
            XCTAssertLessThan(earlier.lowerBound, latest.lowerBound)
        }
    }

    // MARK: Helpers

    private func assertAskInstructions(_ system: String, _ level: AnswerDepth, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(system.hasPrefix(Prompts.defaultSystemPrompt), file: file, line: line)
        XCTAssertTrue(system.contains(level.guidance(for: .answer)), "\(level) guidance missing", file: file, line: line)
        XCTAssertTrue(system.contains(AnswerDepth.clarityRule), file: file, line: line)
        XCTAssertTrue(system.contains(AnswerDepth.conversationRule), file: file, line: line)
        for other in AnswerDepth.allCases where other != level {
            XCTAssertFalse(system.contains(other.guidance(for: .answer)), "\(level) carries \(other)", file: file, line: line)
        }
    }

    /// One session Ask, as the chat sends it: the history ends with the question.
    @MainActor
    private func sessionAsk(
        depth: AnswerDepth, history: [ChatMessage] = [], question: String = "How was her mood?"
    ) async throws -> (system: String, prompt: String) {
        let fake = PromptCapturingAssistant()
        let service = AssistantService(assistant: fake, model: "m")
        let stream = LongSessionChat.stream(
            transcript: "Patient discussed sleep.",
            history: history + [ChatMessage(role: .user, text: question)],
            question: question,
            depth: depth,
            sessionID: UUID(),
            service: service,
            builder: DigestBuilder(queue: InferenceQueue()),
            loadDigest: { nil },
            saveDigest: { _ in },
            live: { _, _ in },
            coverage: { _ in }
        )
        for try await _ in stream {}
        return (try XCTUnwrap(fake.systems.last), try XCTUnwrap(fake.prompts.last))
    }

    /// One patient Ask over context that already holds every transcript.
    @MainActor
    private func patientAsk(
        depth: AnswerDepth, history: [ChatMessage] = [], question: String = "How was her mood?"
    ) async throws -> (system: String, prompt: String) {
        let fake = PromptCapturingAssistant()
        let service = AssistantService(assistant: fake, model: "m")
        let context = PatientContext(
            text: "===== Session [S1] March 15, 2026 =====\n[0:10] C: I slept badly.",
            sources: [],
            coverage: TranscriptCoverage(
                transcriptSessions: 1, sessionsWithPassages: 1, mentions: 0, searched: true,
                wholeTranscripts: true, fullTexts: true)
        )
        let stream = PatientChatAnswer.stream(
            context: context,
            history: history + [ChatMessage(role: .user, text: question)],
            question: question,
            depth: depth,
            totalBudget: 12_000,
            scope: { LocalToolScope(sessions: []) },
            service: service,
            builder: DigestBuilder(queue: InferenceQueue()),
            live: { _, _ in },
            onCoverage: { _ in }
        )
        for try await _ in stream {}
        return (try XCTUnwrap(fake.systems.last), try XCTUnwrap(fake.prompts.last))
    }
}
