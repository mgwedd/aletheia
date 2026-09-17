import Foundation

/// The prompt templates sent to the local Ollama model. Kept in one place
/// so the disclaimer language (summaries can be wrong; always read the
/// transcript) stays consistent everywhere it's used.
enum Prompts {
    static func summarize(transcript: String) -> String {
        """
        You are helping a therapist review her own session notes. Summarize \
        the following therapy session transcript into concise clinical notes: \
        presenting topics, notable statements, mood/affect observations, and \
        any follow-ups to revisit next session. Do not invent details that \
        aren't in the transcript. If the transcript is too short or unclear \
        to summarize, say so plainly.

        Transcript:
        \(transcript)
        """
    }

    static func sessionChat(
        transcript: String,
        notes: String = "",
        comments: [String] = [],
        history: [ChatMessage],
        question: String
    ) -> String {
        """
        You are helping a therapist ask questions about one specific therapy \
        session. Use the transcript below, together with the therapist's own \
        notes and margin comments when they're provided — her notes and \
        comments are her clinical judgment and should be given weight. If the \
        answer isn't in any of that material, say you don't see it in this \
        session. Never speculate.

        Transcript:
        \(transcript)
        \(therapistMaterial(notes: notes, comments: comments))
        \(formatHistory(history))
        Therapist's question: \(question)
        """
    }

    /// Renders the therapist's own notes/comments as a clearly-labeled block,
    /// or nothing when she hasn't written any. Kept distinct from the
    /// transcript so the model never confuses her words with the session's.
    private static func therapistMaterial(notes: String, comments: [String]) -> String {
        var sections: [String] = []
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty {
            sections.append("Therapist's session notes:\n\(trimmedNotes)")
        }
        if !comments.isEmpty {
            sections.append("Therapist's margin comments on the transcript:\n" + comments.joined(separator: "\n"))
        }
        return sections.isEmpty ? "" : "\n" + sections.joined(separator: "\n\n") + "\n"
    }

    static func patientChat(context: String, history: [ChatMessage], question: String) -> String {
        """
        You are helping a therapist ask questions across all of one \
        patient's past session transcripts, given below (most recent \
        first). Each session header carries a short tag in brackets next \
        to its date, like "===== Session [S1] March 5, 2026 =====". Answer \
        only using these transcripts — if the answer isn't in them, say you \
        don't see that in the recorded sessions. When you use something \
        from a session, cite it inline with its tag exactly as written, \
        e.g. [S1]; cite every session you drew from. Never speculate and \
        never invent a tag that isn't listed.

        \(context)

        \(formatHistory(history))
        Therapist's question: \(question)
        """
    }

    private static func formatHistory(_ history: [ChatMessage]) -> String {
        guard !history.isEmpty else { return "" }
        let lines = history.suffix(6).map { message in
            "\(message.role == .user ? "Therapist" : "Assistant"): \(message.text)"
        }
        return "Recent conversation:\n" + lines.joined(separator: "\n") + "\n"
    }
}
