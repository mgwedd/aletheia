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

    /// How to read a transcript (`[MM:SS] Y: text` turns, as shrunk by
    /// `TranscriptCompactor` from the stored `[MM:SS] You: text` lines).
    /// Embedded in every prompt that includes a transcript so the model does
    /// not over-read the labels or the ordering. The short labels are defined
    /// only here. Keep in step with the labels in `WhisperTranscriber` and the
    /// "(overlapping)" suffix in `TranscriptFormatter`.
    static let transcriptLegend = """
    How to read the transcript: each turn is "[MM:SS] Y: text" or \
    "[MM:SS] C: text" (minutes can exceed 59 in a long session, e.g. \
    "[75:12]"). The time is when the turn started; a long turn repeats its label and a new time about every \
    minute. The label comes from which audio track the words were recorded \
    on, not from voice analysis. "Y" (You) is the microphone, normally the \
    therapist; it never means you, the reader. "C" (Call audio) is normally \
    the client. In a session recorded with the microphone only, both people \
    may appear as "Y". A "~" after the letter ("Y~", "C~") means \
    "(overlapping)": both tracks had speech at the same time, so the two \
    people spoke over each other. "(repeated ×N)" after a sentence means the same \
    sentence was repeated N times in a row (often a transcription loop, but it \
    can be the speaker repeating it). Filler sounds such as "um" and "uh" were left out. Line order \
    is approximate to within a few seconds.
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
        \(TranscriptCompactor.compact(transcript))
        """
    }

    /// The editable part of a note prompt: the opening instruction and, for the
    /// structured formats, the section spec and rules; for the narrative, its
    /// layout rule. The therapist can replace it per format
    /// (`AppSettings.noteInstructions`); everything else in the prompt is added
    /// by `progressNote` regardless.
    static func defaultInstructions(for format: ProgressNoteFormat) -> String {
        guard !format.sections.isEmpty else {
            return """
            You are helping a therapist review her own session notes. Write a \
            narrative clinical summary of the following therapy session: \
            presenting topics, notable statements, mood/affect observations, and \
            any follow-ups to revisit next session. Fold in the therapist's own \
            notes and comments where they fit, treating them as her clinical \
            judgment. Do not invent details that aren't in the material. If the \
            material is too short or unclear to summarize, say so plainly.

            Write short paragraphs. Where a topic needs a label, start its \
            paragraph with a bold lead-in, e.g. **Mood and affect:**, and put \
            follow-ups in a bulleted list under a **Follow-ups:** lead-in.
            """
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
        - Be specific, not high-level: name the concrete situations, themes and \
        examples the client described, the client's own words where telling \
        (briefly quoted), the interventions the therapist used and how the \
        client responded. Avoid generic phrases such as "discussed stressors" \
        or "explored feelings".
        - If a section has nothing to support it in the material, write \
        "Not documented in this session." under that heading rather than \
        guessing.
        - If a safety concern (risk of harm to self or others) appears, state \
        it plainly in the Assessment/appropriate section.
        - Do not add a diagnosis that isn't already in the material.
        """
    }

    /// Builds a clinical progress note in a standard documentation format
    /// (SOAP/DAP/BIRP), or a plain narrative summary. The heading structure and
    /// per-section meaning come from `ProgressNoteFormat` so the model writes to
    /// the exact sections the exporter and the payer expect. Grounded strictly
    /// in the transcript and the therapist's own notes/comments; empty sections
    /// are marked rather than filled with guesses. `instructions` replaces the
    /// format's default instruction text (nil keeps it); the length setting,
    /// formatting rules, legend and material are always appended.
    static func progressNote(
        format: ProgressNoteFormat,
        transcript: String,
        notes: String = "",
        comments: [String] = [],
        verbosity: SummaryVerbosity = .default,
        instructions: String? = nil
    ) -> String {
        let lengthGuidance = format.sections.isEmpty ? verbosity.promptGuidance : verbosity.noteGuidance
        return """
        \(instructions ?? defaultInstructions(for: format))

        \(lengthGuidance)
        \(SummaryVerbosity.clarityRule)

        \(noteFormattingRules)

        \(transcriptLegend)

        Transcript:
        \(TranscriptCompactor.compact(transcript))
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
        \(TranscriptCompactor.compact(transcript))
        \(therapistMaterial(notes: notes, comments: comments))
        \(formatHistory(history, question: question))
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
        """
        You are helping a therapist ask questions across all of one \
        patient's past sessions, given below (most recent first). Each \
        session header carries a short tag in brackets next to its date, \
        like "===== Session [S1] March 5, 2026 =====". Under a header, the \
        timestamped lines are the session transcript. Blocks labelled \
        "Generated progress note" were drafted by the assistant from that \
        transcript; blocks labelled "Therapist's session notes" and \
        "Therapist's margin comments" are the therapist's own words and \
        carry her clinical judgment. Answer only from this material. A line saying a transcript could not be read means that \
        session is missing, not that nothing was discussed. When you use \
        something from a session, cite it inline with its tag exactly as \
        written, e.g. [S1]; cite every session you drew from. Never \
        speculate and never invent a tag that isn't listed.

        \(patientSearchRule)

        \(transcriptLegend)

        \(context)

        \(formatHistory(history, question: question))
        Therapist's question: \(question)
        """
    }

    /// The conversation as `ChatMemory` remembers it. The question is sent
    /// once, on its own line after this; if the history already ends with it
    /// (the chat views append it before sending), it's left out here.
    private static func formatHistory(_ history: [ChatMessage], question: String? = nil) -> String {
        var (summary, recent) = ChatMemory.remembered(history)
        if let last = recent.last, last.role == .user, last.text == question { recent.removeLast() }
        var parts: [String] = []
        if let summary {
            parts.append("Summary of the earlier conversation:\n\(summary)\n")
        }
        if !recent.isEmpty {
            let lines = recent.map { "\($0.role == .user ? "Therapist" : "Assistant"): \($0.text)" }
            parts.append("Recent conversation:\n" + lines.joined(separator: "\n") + "\n")
        }
        return parts.joined(separator: "\n")
    }

    /// Asks for a summary that can stand in for the conversation so far, so a
    /// long chat keeps going without silently forgetting its start.
    static func compactChat(history: [ChatMessage], focus: String) -> String {
        let focusLine = focus.isEmpty ? "" : """

        The therapist asked to keep this in particular, in full detail: \(focus)

        """
        return """
        Below is a conversation between a therapist and an assistant about \
        her recorded therapy sessions. Write a summary that will replace it, \
        so the conversation can continue without the full history.

        Keep: each question she asked, the answers and conclusions reached, \
        specific facts with the session tags or time stamps they were cited \
        with, and anything left open. Leave out pleasantries and repetition. \
        Write it as compact notes, under 400 words, with no opening or \
        closing remarks. Don't add anything that isn't in the conversation.
        \(focusLine)
        \(formatHistory(history))
        """
    }
}
