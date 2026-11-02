import Foundation

/// What a piece of writing is, for `AnswerDepth`: the levels mean the same at
/// each, but a note and a chat reply are measured differently.
enum DepthOutput: CaseIterable {
    /// A Summary-format note, measured in words.
    case summary
    /// A SOAP/DAP/BIRP/GIRP note, measured per section.
    case structuredNote
    /// An answer in Ask (a session's or a patient's).
    case answer
}

/// Where a depth is chosen: each has its own default in `AppSettings`
/// (`noteDepth`, `askDepth`).
enum DepthFeature: CaseIterable {
    case note
    case ask
}

/// How much the assistant writes, for notes and Ask alike. One type, one word
/// ("Depth") and one mechanism: every prompt that writes for the therapist
/// carries `instructions(for:)`, a target for its kind of output plus a form
/// line, then the shared `clarityRule`. Ask adds `conversationRule`, so each answer
/// takes its own question on its own terms. Depth sets
/// no token cap: a reply is never cut off to meet it.
///
///     concise  ── genuinely short: what's needed, nothing more
///     natural  ── normal prose, the way a colleague writes (default)
///     detailed ── the full, structured form
enum AnswerDepth: String, CaseIterable, Identifiable, Codable, Hashable {
    case concise
    case natural
    case detailed

    static let `default`: AnswerDepth = .natural

    /// What the selector is called wherever it appears.
    static let label = "Depth"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .concise: return "Concise"
        case .natural: return "Natural"
        case .detailed: return "Detailed"
        }
    }

    /// One line for Settings and the Ask bar's help.
    func blurb(for feature: DepthFeature) -> String {
        switch (feature, self) {
        case (.note, .concise): return "A short note you can take in at a glance."
        case (.note, .natural): return "The session and its context, without extra detail."
        case (.note, .detailed): return "A fuller account, including the order of events and notable statements."
        case (.ask, .concise): return "A direct answer in a few sentences."
        case (.ask, .natural): return "A conversational answer in a short paragraph or two."
        case (.ask, .detailed): return "A full, structured answer with headers and lists where they help."
        }
    }

    // MARK: - What the model is told

    /// How much to write for `output`.
    func target(for output: DepthOutput) -> String {
        switch (output, self) {
        case (.summary, .concise):
            return "Aim for roughly 80–150 words: only what a clinician needs to recall the session at a glance."
        case (.summary, .natural):
            return "Aim for roughly 150–300 words: enough to recall the session and its context, and no more."
        case (.summary, .detailed):
            return "Aim for roughly 300–600 words: include the order of events, notable statements and the nuance a later reader would need."
        case (.structuredNote, .concise):
            return "Keep each section to one or two sentences."
        case (.structuredNote, .natural):
            return "Write a short paragraph for each section."
        case (.structuredNote, .detailed):
            return "Write a full paragraph for each section, including the specifics a later reader would need."
        case (.answer, .concise):
            return "Answer in one to three sentences."
        case (.answer, .natural):
            return "Answer in a short paragraph or two."
        case (.answer, .detailed):
            return "Give a full answer that covers the specifics and nuance the question calls for."
        }
    }

    /// The shape of the writing, the same for every output; a note's own
    /// format (its sections and lead-ins) still applies on top.
    var form: String {
        switch self {
        case .concise:
            return "Lead with the point. No headers, no preamble, no recap; use a list only when the content is itself a short list."
        case .natural:
            return "Write plain prose in short paragraphs, the way a colleague would. Use a list only when it clearly helps, and no bold section headers."
        case .detailed:
            return "Be thorough and organized: headers and bulleted lists are fine where they help the reader scan."
        }
    }

    /// The depth line for `output`: the level, its target and its form.
    func guidance(for output: DepthOutput) -> String {
        let format = output == .answer ? "" : " The note's own format still applies."
        return "Depth: \(rawValue). \(target(for: output)) \(form)\(format)"
    }

    /// Everything depth adds to a prompt for `output`: the guidance, the
    /// clarity rule, and in Ask the conversation rule.
    func instructions(for output: DepthOutput) -> String {
        var parts = [guidance(for: output), Self.clarityRule]
        if output == .answer { parts.append(Self.conversationRule) }
        return parts.joined(separator: "\n")
    }

    /// Carried at every level and in every output, so a deeper setting never
    /// means wordier writing.
    static let clarityRule = """
    Clarity comes before length at every setting: plain words, one idea per \
    sentence, no filler. Never pad to reach a length; if the material is short \
    or thin, so is the reply.
    """

    /// Carried by every Ask answer, at every level, so a conversation doesn't
    /// anchor on its first answer: each reply answers its own question.
    static let conversationRule = """
    Answer the latest question on its own terms. Don't restructure, revise or \
    re-summarise your earlier answers; use earlier turns only as context. Each \
    answer should stand on its own, so repeat a point if this answer needs it.
    """
}
