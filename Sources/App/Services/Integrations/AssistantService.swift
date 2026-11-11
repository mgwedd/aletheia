import Foundation
import os

/// Turns the app's use cases (summarize a session, answer a question about a
/// session or a whole patient history) into prompts and runs them through
/// whatever `Assistant` backend is wired in. Keeping the prompt-building
/// here — behind the adapter — means views never touch a concrete client and
/// this logic is unit-testable with a fake `Assistant`.
struct AssistantService {
    let assistant: Assistant
    let model: String
    /// Standing instructions sent with every request (see `AppSettings.systemPrompt`).
    var systemPrompt: String = Prompts.defaultSystemPrompt
    /// What this Mac can read at once. A prompt over it is refused, never cut.
    var budget: ContextBudget = .current
    /// Told when a run is about to read its prompt and when it finishes (see
    /// `ChatStreamRunner.reporter`).
    var report: (@Sendable (AIRunEvent) -> Void)?
    /// The patient's name, for the prompts' speaker guide: notes and answers
    /// call the call-audio speaker by its first word. Empty means "the client".
    var clientName: String = ""
    /// Whether the model keeps track of a long transcript read in one piece
    /// (`LlamaModel.readsLongTranscripts`); a long note reads more of it when it does.
    var readsLongTranscripts = false

    private func checkBudget(system: String, turns: [PromptTurn], prompt: String) throws {
        guard budget.fits(system: system, prompt: PromptTurn.flattened(turns, then: prompt)) else {
            throw ContextBudgetError(minutes: budget.approximateMinutes)
        }
    }

    private func generate(
        task: AITask, system: String, turns: [PromptTurn] = [], prompt: String, grammar: LocalLLMGrammar? = nil
    ) async throws -> String {
        try checkBudget(system: system, turns: turns, prompt: prompt)
        return try await assistant.generate(
            model: model, system: system, turns: turns, prompt: prompt, task: task, grammar: grammar)
    }

    /// Streams `prompt` after the budget check; an over-budget prompt fails the
    /// stream with `ContextBudgetError` and nothing is sent.
    private func run(
        task: AITask, system: String, turns: [PromptTurn] = [], prompt: String, grammar: LocalLLMGrammar? = nil
    ) -> AsyncThrowingStream<String, Error> {
        do {
            try checkBudget(system: system, turns: turns, prompt: prompt)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        report?(.reading(estimatedTokens: ContextBudget.estimatedTokens(
            system: system, prompt: PromptTurn.flattened(turns, then: prompt))))
        let report = report
        return assistant.stream(
            model: model, system: system, turns: turns, prompt: prompt, task: task, grammar: grammar,
            onStats: report.map { report in { @Sendable stats in
                if let prefill = stats.prefill { report(.prefill(prefill)) } else { report(.finished(stats)) }
            } })
    }

    /// Whether `prompt` (with the standing instructions) is within the budget.
    func fits(prompt: String, turns: [PromptTurn] = []) -> Bool {
        budget.fits(system: systemPrompt, prompt: PromptTurn.flattened(turns, then: prompt))
    }

    /// Streams a digest prompt: the same budget check, progress report and
    /// truncation tripwire as a note or an answer. `task` picks the sampling
    /// settings (a long-session note's draft and check are `.note`).
    func streamDigest(
        prompt: String, turns: [PromptTurn] = [], task: AITask = .digest, grammar: LocalLLMGrammar? = nil
    ) -> AsyncThrowingStream<String, Error> {
        run(task: task, system: systemPrompt, turns: turns, prompt: prompt, grammar: grammar)
    }

    /// Streams a chat answer: `turns` are the conversation since its latest
    /// summary, sent as real chat turns, and `prompt` is the final user turn.
    func streamAnswer(system: String, turns: [PromptTurn], prompt: String) -> AsyncThrowingStream<String, Error> {
        run(task: .chat, system: system, turns: turns, prompt: prompt)
    }

    func summarize(transcript: String, patientBackground: String = "") async throws -> String {
        try await generate(task: .note, system: systemPrompt, prompt: Prompts.summarize(transcript: transcript, patientBackground: patientBackground, clientName: clientName))
    }

    /// Drafts a clinical progress note in the given documentation format
    /// (SOAP/DAP/BIRP) or a narrative summary, grounded in the transcript and
    /// the therapist's own notes and margin comments.
    func progressNote(
        format: ProgressNoteFormat,
        transcript: String,
        notes: String = "",
        comments: [SessionComment] = [],
        patientBackground: String = "",
        depth: AnswerDepth = .default,
        instructions: String? = nil
    ) async throws -> String {
        try await generate(task: .note,
            system: systemPrompt,
            prompt: Prompts.progressNote(
                format: format,
                transcript: transcript,
                notes: AIContextPolicy.notes(notes, for: .noteGeneration),
                comments: Self.formatComments(comments),
                patientBackground: patientBackground,
                depth: depth,
                instructions: instructions,
                clientName: clientName
            ),
            grammar: format.grammar
        )
    }

    /// Streams the progress note as the growing full text so far, so the note
    /// visibly writes itself. Backends without native streaming emit once.
    func streamProgressNote(
        format: ProgressNoteFormat,
        transcript: String,
        notes: String = "",
        comments: [SessionComment] = [],
        patientBackground: String = "",
        depth: AnswerDepth = .default,
        instructions: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        run(task: .note,
            system: systemPrompt,
            prompt: Prompts.progressNote(
                format: format,
                transcript: transcript,
                notes: AIContextPolicy.notes(notes, for: .noteGeneration),
                comments: Self.formatComments(comments),
                patientBackground: patientBackground,
                depth: depth,
                instructions: instructions,
                clientName: clientName
            ),
            grammar: format.grammar
        )
    }

    func answerAboutSession(
        transcript: String,
        notes: String = "",
        comments: [SessionComment] = [],
        patientBackground: String = "",
        history: [ChatMessage],
        question: String,
        depth: AnswerDepth = .default
    ) async throws -> String {
        return try await generate(task: .chat,
            system: Prompts.chatSystem(systemPrompt, question: question, depth: depth, material: Prompts.sessionChat(
                transcript: transcript,
                notes: AIContextPolicy.notes(notes, for: .sessionChat),
                comments: Self.formatComments(comments),
                patientBackground: patientBackground,
                history: history,
                clientName: clientName
            )),
            turns: PromptTurn.recent(history, question: question),
            prompt: Prompts.chatQuestion(question, depth: depth)
        )
    }

    func answerAboutPatient(context: String, history: [ChatMessage], question: String, depth: AnswerDepth = .default) async throws -> String {
        try await generate(task: .chat,
            system: Prompts.chatSystem(
                systemPrompt, question: question, depth: depth,
                material: Prompts.patientChat(context: context, history: history, clientName: clientName)),
            turns: PromptTurn.recent(history, question: question),
            prompt: Prompts.chatQuestion(question, depth: depth)
        )
    }

    // MARK: - Streaming

    /// Streams the answer to a session question as the growing full text so far.
    /// Backends that stream natively (Foundation Models, llama.cpp) emit
    /// progressively; others fall back to a single final emission.
    func streamAnswerAboutSession(
        transcript: String,
        notes: String = "",
        comments: [SessionComment] = [],
        patientBackground: String = "",
        history: [ChatMessage],
        question: String,
        depth: AnswerDepth = .default
    ) -> AsyncThrowingStream<String, Error> {
        run(task: .chat,
            system: Prompts.chatSystem(systemPrompt, question: question, depth: depth, material: Prompts.sessionChat(
                transcript: transcript,
                notes: AIContextPolicy.notes(notes, for: .sessionChat),
                comments: Self.formatComments(comments),
                patientBackground: patientBackground,
                history: history,
                clientName: clientName
            )),
            turns: PromptTurn.recent(history, question: question),
            prompt: Prompts.chatQuestion(question, depth: depth)
        )
    }

    /// Streams the answer to a whole-patient question as the growing full text.
    /// How many characters of session material a patient-wide question can
    /// carry on this Mac, after the instructions, conversation and question
    /// (measured by script, so a conversation in Japanese takes its real share).
    func patientContextCharacters(history: [ChatMessage], question: String, depth: AnswerDepth = .default) -> Int {
        let system = Prompts.chatSystem(
            systemPrompt, question: question, depth: depth,
            material: Prompts.patientChat(context: "", history: history, clientName: clientName))
        let wrapper = PromptTurn.flattened(PromptTurn.recent(history, question: question), then: Prompts.chatQuestion(question, depth: depth))
        return budget.availableCharacters(
            reserving: ContextBudget.weightedLength(of: system) + ContextBudget.weightedLength(of: wrapper))
    }

    func streamAnswerAboutPatient(
        context: String,
        history: [ChatMessage],
        question: String,
        depth: AnswerDepth = .default
    ) -> AsyncThrowingStream<String, Error> {
        run(task: .chat,
            system: Prompts.chatSystem(
                systemPrompt, question: question, depth: depth,
                material: Prompts.patientChat(context: context, history: history, clientName: clientName)),
            turns: PromptTurn.recent(history, question: question),
            prompt: Prompts.chatQuestion(question, depth: depth)
        )
    }

    /// Streams a summary that replaces the conversation so far (`/compact`).
    /// A summary the model was still writing when it reached the reply limit
    /// fails the stream with `CompactionError.cutOff`: it would stand in for
    /// messages it doesn't cover.
    func streamCompaction(history: [ChatMessage], focus: String) -> AsyncThrowingStream<String, Error> {
        let cutOff = OSAllocatedUnfairLock(initialState: false)
        var counting = self
        let outer = report
        counting.report = { event in
            if case .finished(let stats) = event { cutOff.withLock { $0 = stats.reachedReplyLimit } }
            outer?(event)
        }
        let stream = counting.run(
            task: .compaction, system: Prompts.compactSystem(systemPrompt, history: history),
            turns: [], prompt: Prompts.compactChat(PromptTurn.recent(history), focus: focus))
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await text in stream { continuation.yield(text) }
                    if cutOff.withLock({ $0 }) { throw CompactionError.cutOff }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Renders stored margin comments into the plain lines the prompt expects.
    /// Shared by the batch and streaming session-chat paths. Resolved comments
    /// are left out: like a resolved Google-Docs thread, they've been closed out
    /// and shouldn't quietly steer a regenerated note or answer.
    static func formatComments(_ comments: [SessionComment]) -> [String] {
        comments.filter { !$0.resolved }.map { comment in
            // One line per comment: a multi-line quote or body would otherwise
            // read as extra list items in the prompt.
            let quote = oneLine(comment.quotedText)
            let body = oneLine(comment.body)
            if let format = comment.format {
                return quote.isEmpty
                    ? "- [On \(format.shortName) note]: \(body)"
                    : "- [On \(format.shortName) note “\(quote)”]: \(body)"
            }
            return quote.isEmpty ? "- \(body)" : "- On “\(quote)”: \(body)"
        }
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}

/// Why a conversation summary was discarded.
enum CompactionError: LocalizedError, Equatable, DiscardsPartialReply {
    /// The model reached the reply limit before finishing the summary.
    case cutOff

    var errorDescription: String? {
        "The summary didn't finish, so the conversation was kept as it was. "
            + "Try Compact again, or name what to keep, like /compact medication."
    }
}
