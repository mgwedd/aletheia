import Foundation

/// Turns the app's use cases (summarize a session, answer a question about a
/// session or a whole patient history) into prompts and runs them through
/// whatever `Assistant` backend is wired in. Keeping the prompt-building
/// here — behind the adapter — means views never touch a concrete client and
/// this logic is unit-testable with a fake `Assistant`.
struct AssistantService {
    let assistant: Assistant
    let model: String

    func summarize(transcript: String) async throws -> String {
        try await assistant.generate(model: model, prompt: Prompts.summarize(transcript: transcript))
    }

    func answerAboutSession(
        transcript: String,
        notes: String = "",
        comments: [SessionComment] = [],
        history: [ChatMessage],
        question: String
    ) async throws -> String {
        let formattedComments = comments.map { comment -> String in
            let quote = comment.quotedText.trimmingCharacters(in: .whitespacesAndNewlines)
            return quote.isEmpty ? "- \(comment.body)" : "- On “\(quote)”: \(comment.body)"
        }
        return try await assistant.generate(
            model: model,
            prompt: Prompts.sessionChat(
                transcript: transcript,
                notes: notes,
                comments: formattedComments,
                history: history,
                question: question
            )
        )
    }

    func answerAboutPatient(context: String, history: [ChatMessage], question: String) async throws -> String {
        try await assistant.generate(
            model: model,
            prompt: Prompts.patientChat(context: context, history: history, question: question)
        )
    }
}
