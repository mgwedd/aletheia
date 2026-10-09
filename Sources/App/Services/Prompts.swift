import Foundation

/// The prompt templates sent to the local Ollama model. Kept in one place
/// so the disclaimer language (summaries can be wrong; always read the
/// transcript) stays consistent everywhere it's used.
enum Prompts {
    /// The default system prompt sent with every LLM request. It's the app's
    /// voice and guardrails in one place; the user can edit it in Settings
    /// (`AppSettings.systemPrompt`) and reset back to this. Kept deliberately
    /// short, clinical, and safety-first.
    static let defaultSystemPrompt = """
    You are a careful clinical assistant inside a private, on-device app used by \
    a licensed psychotherapist to review her own therapy sessions. Everything \
    you see is confidential patient information that never leaves her Mac.

    Ground every answer strictly in the material you are given — the session \
    transcript, the therapist's own notes and comments, and prior sessions. \
    Never invent details, diagnoses, events, or quotes. If something isn't in \
    the material, say so plainly rather than guessing. When you draw on the \
    therapist's own notes or comments, treat them as her clinical judgment.

    Be concise and plain-spoken. You are a support tool, not the clinician: \
    surface what's in the record and flag things worth her attention, but leave \
    clinical decisions to her. If a session raises a safety concern (e.g. risk \
    of harm), point to it directly and factually.

    Answer in clear prose.
    """

    /// Appended to the system prompt for a chat turn only when the question asks
    /// for a diagram. Offering diagrams on every turn made a small local model
    /// draw one for ordinary questions, restating the answer as a flowchart with
    /// invented nodes and broken syntax. Gating on the request keeps them rare.
    static let diagramGuidance = """
    The therapist asked for a diagram. Draw one Mermaid diagram in a \
    ```mermaid code block, using only people, events, and relationships that are \
    in the material above — add no nodes of your own. Use a `graph TD` or \
    `graph LR` flowchart. Write each node as `A[Short label]` and each edge as \
    `A -->|short label| B` (or `A --> B`); nothing may follow the closing `|`. \
    Never put square brackets or parentheses inside a label. Keep it to a \
    handful of nodes, add a sentence of context after it, and if the material \
    doesn't support a meaningful diagram, say so instead of drawing one.
    """

    /// True when a chat question explicitly asks for a diagram or drawing.
    static func asksForDiagram(_ question: String) -> Bool {
        question.range(
            of: #"\b(diagrams?|flow ?charts?|mermaid|visuali[sz]\w*|draw)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// The system prompt for a chat turn: the standing prompt, plus diagram
    /// guidance only when this question asks for one.
    static func chatSystemPrompt(_ base: String, question: String) -> String {
        asksForDiagram(question) ? base + "\n\n" + diagramGuidance : base
    }

    /// How to read a transcript line (`[MM:SS] Label: text`, as printed by
    /// `TranscriptFormatter`). Embedded in every prompt that includes a
    /// transcript so the model does not over-read the labels or the ordering.
    /// Keep in step with the labels in `WhisperTranscriber` and the
    /// "(overlapping)" suffix in `TranscriptFormatter`.
    static let transcriptLegend = """
    How to read the transcript: each line is "[MM:SS] Label: text". The \
    label comes from which audio track the words were recorded on, not from \
    voice analysis. "Call audio" is normally the client. In a session \
    recorded with the microphone only, both people may appear as \
    "Therapist". "(overlapping)" after a label means both tracks had speech \
    at the same time, so the two people spoke over each other. Line order is \
    approximate to within a few seconds.
    """

    static func summarize(transcript: String) -> String {
        """
        You are helping a therapist review her own session notes. Summarize \
        the following therapy session transcript into concise clinical notes: \
        presenting topics, notable statements, mood/affect observations, and \
        any follow-ups to revisit next session. Do not invent details that \
        aren't in the transcript. If the transcript is too short or unclear \
        to summarize, say so plainly.

        \(transcriptLegend)

        Transcript:
        \(transcript)
        """
    }

    /// Builds a clinical progress note in a standard documentation format
    /// (SOAP/DAP/BIRP), or a plain narrative summary. The heading structure and
    /// per-section meaning come from `ProgressNoteFormat` so the model writes to
    /// the exact sections the exporter and the payer expect. Grounded strictly
    /// in the transcript and the therapist's own notes/comments; empty sections
    /// are marked rather than filled with guesses.
    static func progressNote(
        format: ProgressNoteFormat,
        transcript: String,
        notes: String = "",
        comments: [String] = [],
        verbosity: SummaryVerbosity = .default
    ) -> String {
        guard !format.sections.isEmpty else {
            return summarizeNarrative(transcript: transcript, notes: notes, comments: comments, verbosity: verbosity)
        }

        let sectionSpec = format.sections
            .map { "## \($0.heading)\n\($0.guidance)" }
            .joined(separator: "\n\n")
        let headingList = format.sections.map(\.heading).joined(separator: ", ")

        return """
        You are helping a licensed psychotherapist write a clinical progress \
        note for one therapy session, in the \(format.displayName) format. \
        Draft the note from the material below.

        Write exactly these sections, each as a level-2 Markdown heading \
        (\(headingList)), in this order, and nothing outside them:

        \(sectionSpec)

        Rules:
        - Ground every statement in the transcript and the therapist's own \
        notes and comments. Never invent details, diagnoses, quotes, or events.
        - Treat the therapist's notes and comments as her clinical judgment and \
        weave them in where they fit a section.
        - Write in the concise, professional third-person voice of a chart note \
        (e.g. "Client reported…"), not a transcript recap.
        - If a section has nothing to support it in the material, write \
        "Not documented in this session." under that heading rather than \
        guessing.
        - If a safety concern (risk of harm to self or others) appears, state \
        it plainly in the Assessment/appropriate section.
        - Do not add a diagnosis that isn't already in the material.

        \(noteFormattingRules)

        \(transcriptLegend)

        Transcript:
        \(transcript)
        \(therapistMaterial(notes: notes, comments: comments))
        """
    }

    /// Layout rules shared by every note format, so the draft reads as a set
    /// document rather than a chat reply. `NoteMarkdown.tidy` repairs the same
    /// things after the fact when a model ignores them.
    static let noteFormattingRules = """
    Formatting:
    - Start directly with the note itself. No opening line such as "Here is \
    a summary", and no closing remarks.
    - Separate paragraphs with a blank line.
    - Use the therapist's notes and comments as context. Don't quote, discuss, \
    or speculate about them, and leave out any that are unclear.
    """

    /// The narrative-format path of `progressNote`: a prose summary that still
    /// folds in the therapist's own notes and comments, at the length the
    /// therapist chose in Settings.
    private static func summarizeNarrative(
        transcript: String,
        notes: String,
        comments: [String],
        verbosity: SummaryVerbosity
    ) -> String {
        """
        You are helping a therapist review her own session notes. Write a \
        narrative clinical summary of the following therapy session: \
        presenting topics, notable statements, mood/affect observations, and \
        any follow-ups to revisit next session. Fold in the therapist's own \
        notes and comments where they fit, treating them as her clinical \
        judgment. Do not invent details that aren't in the material. If the \
        material is too short or unclear to summarize, say so plainly.

        \(verbosity.promptGuidance)
        \(SummaryVerbosity.clarityRule)

        \(noteFormattingRules)
        - Write short paragraphs. Where a topic needs a label, start its \
        paragraph with a bold lead-in, e.g. **Mood and affect:**, and put \
        follow-ups in a bulleted list under a **Follow-ups:** lead-in.

        \(transcriptLegend)

        Transcript:
        \(transcript)
        \(therapistMaterial(notes: notes, comments: comments))
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

        \(transcriptLegend)

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
    static func therapistMaterial(notes: String, comments: [String]) -> String {
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
        // The question is sent once, in its own line below. If the caller's
        // history already ends with it (the chat view appends it before
        // sending), leave it out of the recent-conversation block.
        var prior = history
        if let last = prior.last, last.role == .user, last.text == question { prior.removeLast() }
        return """
        You are helping a therapist ask questions across all of one \
        patient's past sessions, given below (most recent first). Each \
        session header carries a short tag in brackets next to its date, \
        like "===== Session [S1] March 5, 2026 =====". Under a header, the \
        timestamped lines are the session transcript. Blocks labelled \
        "Generated progress note" were drafted by the assistant from that \
        transcript; blocks labelled "Therapist's session notes" and \
        "Therapist's margin comments" are the therapist's own words and \
        carry her clinical judgment. Answer only from this material — if \
        the answer isn't in it, say you don't see that in the recorded \
        sessions. A line saying a transcript could not be read means that \
        session is missing, not that nothing was discussed. When you use \
        something from a session, cite it inline with its tag exactly as \
        written, e.g. [S1]; cite every session you drew from. Never \
        speculate and never invent a tag that isn't listed.

        \(transcriptLegend)

        \(context)

        \(formatHistory(prior))
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
