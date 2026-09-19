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

    func summarize(transcript: String) async throws -> String {
        try await assistant.generate(model: model, system: systemPrompt, prompt: Prompts.summarize(transcript: transcript))
    }

    /// Drafts a clinical progress note in the given documentation format
    /// (SOAP/DAP/BIRP) or a narrative summary, grounded in the transcript and
    /// the therapist's own notes and margin comments.
    func progressNote(
        format: ProgressNoteFormat,
        transcript: String,
        notes: String = "",
        comments: [SessionComment] = []
    ) async throws -> String {
        try await assistant.generate(
            model: model,
            system: systemPrompt,
            prompt: Prompts.progressNote(
                format: format,
                transcript: transcript,
                notes: notes,
                comments: Self.formatComments(comments)
            )
        )
    }

    /// Streams the progress note as the growing full text so far, so the note
    /// visibly writes itself. Backends without native streaming emit once.
    func streamProgressNote(
        format: ProgressNoteFormat,
        transcript: String,
        notes: String = "",
        comments: [SessionComment] = []
    ) -> AsyncThrowingStream<String, Error> {
        assistant.stream(
            model: model,
            system: systemPrompt,
            prompt: Prompts.progressNote(
                format: format,
                transcript: transcript,
                notes: notes,
                comments: Self.formatComments(comments)
            )
        )
    }

    func answerAboutSession(
        transcript: String,
        notes: String = "",
        comments: [SessionComment] = [],
        history: [ChatMessage],
        question: String
    ) async throws -> String {
        return try await assistant.generate(
            model: model,
            system: systemPrompt,
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
        try await assistant.generate(
            model: model,
            system: systemPrompt,
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
        assistant.stream(
            model: model,
            system: systemPrompt,
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
    func streamAnswerAboutPatient(
        context: String,
        history: [ChatMessage],
        question: String
    ) -> AsyncThrowingStream<String, Error> {
        assistant.stream(
            model: model,
            system: systemPrompt,
            prompt: Prompts.patientChat(context: context, history: history, question: question)
        )
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
