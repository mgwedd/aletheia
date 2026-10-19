import Foundation

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

    private func checkBudget(system: String, prompt: String) throws {
        guard budget.fits(promptCharacters: system.count + prompt.count) else {
            throw ContextBudgetError(minutes: budget.approximateMinutes)
        }
    }

    private func generate(
        task: AITask, system: String, prompt: String, grammar: LocalLLMGrammar? = nil
    ) async throws -> String {
        try checkBudget(system: system, prompt: prompt)
        return try await assistant.generate(
            model: model, system: system, prompt: prompt, task: task, grammar: grammar)
    }

    /// Streams `prompt` after the budget check; an over-budget prompt fails the
    /// stream with `ContextBudgetError` and nothing is sent.
    private func run(
        task: AITask, system: String, prompt: String, grammar: LocalLLMGrammar? = nil
    ) -> AsyncThrowingStream<String, Error> {
        do {
            try checkBudget(system: system, prompt: prompt)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        report?(.reading(estimatedTokens: ContextBudget.estimatedTokens(forCharacters: system.count + prompt.count)))
        let report = report
        return assistant.stream(
            model: model, system: system, prompt: prompt, task: task, grammar: grammar,
            onStats: report.map { report in { report(.finished($0)) } })
    }

    /// Whether `prompt` (with the standing instructions) is within the budget.
    func fits(prompt: String) -> Bool {
        budget.fits(promptCharacters: systemPrompt.count + prompt.count)
    }

    /// Streams a digest prompt: the same budget check, progress report and
    /// truncation tripwire as a note or an answer. `task` picks the sampling
    /// settings (a long-session note's draft and check are `.note`).
    func streamDigest(
        prompt: String, task: AITask = .digest, grammar: LocalLLMGrammar? = nil
    ) -> AsyncThrowingStream<String, Error> {
        run(task: task, system: systemPrompt, prompt: prompt, grammar: grammar)
    }

    func summarize(transcript: String) async throws -> String {
        try await generate(task: .note, system: systemPrompt, prompt: Prompts.summarize(transcript: transcript))
    }

    /// Drafts a clinical progress note in the given documentation format
    /// (SOAP/DAP/BIRP) or a narrative summary, grounded in the transcript and
    /// the therapist's own notes and margin comments.
    func progressNote(
        format: ProgressNoteFormat,
        transcript: String,
        notes: String = "",
        comments: [SessionComment] = [],
        verbosity: SummaryVerbosity = .default,
        instructions: String? = nil
    ) async throws -> String {
        try await generate(task: .note,
            system: systemPrompt,
            prompt: Prompts.progressNote(
                format: format,
                transcript: transcript,
                notes: notes,
                comments: Self.formatComments(comments),
                verbosity: verbosity,
                instructions: instructions
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
        verbosity: SummaryVerbosity = .default,
        instructions: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        run(task: .note,
            system: systemPrompt,
            prompt: Prompts.progressNote(
                format: format,
                transcript: transcript,
                notes: notes,
                comments: Self.formatComments(comments),
                verbosity: verbosity,
                instructions: instructions
            ),
            grammar: format.grammar
        )
    }

    func answerAboutSession(
        transcript: String,
        notes: String = "",
        comments: [SessionComment] = [],
        history: [ChatMessage],
        question: String
    ) async throws -> String {
        return try await generate(task: .chat,
            system: Prompts.chatSystemPrompt(systemPrompt, question: question),
            prompt: Prompts.sessionChat(
                transcript: transcript,
                notes: notes,
                comments: Self.formatComments(comments),
                history: history,
                question: question
            )
        )
    }

    func answerAboutPatient(context: String, history: [ChatMessage], question: String) async throws -> String {
        try await generate(task: .chat,
            system: Prompts.chatSystemPrompt(systemPrompt, question: question),
            prompt: Prompts.patientChat(context: context, history: history, question: question)
        )
    }

    // MARK: - Streaming

    /// Streams the answer to a session question as the growing full text so far.
    /// Backends that stream natively (Ollama, Foundation Models, llama.cpp) emit
    /// progressively; others fall back to a single final emission.
    func streamAnswerAboutSession(
        transcript: String,
        notes: String = "",
        comments: [SessionComment] = [],
        history: [ChatMessage],
        question: String
    ) -> AsyncThrowingStream<String, Error> {
        run(task: .chat,
            system: Prompts.chatSystemPrompt(systemPrompt, question: question),
            prompt: Prompts.sessionChat(
                transcript: transcript,
                notes: notes,
                comments: Self.formatComments(comments),
                history: history,
                question: question
            )
        )
    }

    /// Streams the answer to a whole-patient question as the growing full text.
    /// How many characters of session material a patient-wide question can
    /// carry on this Mac, after the instructions, conversation and question.
    func patientContextCharacters(history: [ChatMessage], question: String) -> Int {
        let system = Prompts.chatSystemPrompt(systemPrompt, question: question)
        let wrapper = Prompts.patientChat(context: "", history: history, question: question)
        return budget.availableCharacters(reserving: system.count + wrapper.count)
    }

    func streamAnswerAboutPatient(
        context: String,
        history: [ChatMessage],
        question: String
    ) -> AsyncThrowingStream<String, Error> {
        run(task: .chat,
            system: Prompts.chatSystemPrompt(systemPrompt, question: question),
            prompt: Prompts.patientChat(context: context, history: history, question: question)
        )
    }

    /// Streams a summary that replaces the conversation so far (`/compact`).
    func streamCompaction(history: [ChatMessage], focus: String) -> AsyncThrowingStream<String, Error> {
        run(task: .compaction, system: systemPrompt, prompt: Prompts.compactChat(history: history, focus: focus))
    }

    /// Renders stored margin comments into the plain lines the prompt expects.
    /// Shared by the batch and streaming session-chat paths. Resolved comments
    /// are left out: like a resolved Google-Docs thread, they've been closed out
    /// and shouldn't quietly steer a regenerated note or answer.
    static func formatComments(_ comments: [SessionComment]) -> [String] {
        comments.filter { !$0.resolved }.map { comment in
            let quote = comment.quotedText.trimmingCharacters(in: .whitespacesAndNewlines)
            return quote.isEmpty ? "- \(comment.body)" : "- On “\(quote)”: \(comment.body)"
        }
    }
}
