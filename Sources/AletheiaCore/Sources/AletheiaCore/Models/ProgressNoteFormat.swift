import Foundation

/// The clinical documentation formats a therapist can ask the assistant to
/// draft a session note in. SOAP/DAP/BIRP are the standard progress-note
/// structures third-party payers and licensing boards expect; "narrative" is
/// the plain prose summary the app shipped with first.
///
/// Pure data — the section headings and the per-section guidance are what the
/// prompt builder turns into instructions, and what the exporter can render as
/// stable headings. No UI or model calls here, so it's unit-tested in isolation.
public enum ProgressNoteFormat: String, CaseIterable, Identifiable, Codable, Hashable {
    case soap
    case dap
    case birp
    case narrative

    public var id: String { rawValue }

    /// The out-of-box default: free text, no imposed template. A therapist who
    /// wants a payer-ready structure opts into SOAP/DAP/BIRP, per session or as
    /// their Settings default.
    public static let `default`: ProgressNoteFormat = .narrative

    /// One clause naming a section and, in plain clinical language, what belongs
    /// in it. The guidance is written for the model, but reads correctly to a
    /// clinician too.
    public struct Section: Equatable {
        public let heading: String
        public let guidance: String
    }

    /// Full name for a picker, e.g. "SOAP note".
    public var displayName: String {
        switch self {
        case .soap: return "SOAP note"
        case .dap: return "DAP note"
        case .birp: return "BIRP note"
        case .narrative: return "Free text (no template)"
        }
    }

    /// Compact label for a segmented control or a menu-bar-tight space.
    public var shortName: String {
        switch self {
        case .soap: return "SOAP"
        case .dap: return "DAP"
        case .birp: return "BIRP"
        case .narrative: return "Free text"
        }
    }

    /// A one-line description of when a clinician reaches for this format.
    public var blurb: String {
        switch self {
        case .soap: return "Subjective · Objective · Assessment · Plan — the most widely accepted progress-note format."
        case .dap: return "Data · Assessment · Plan — a leaner structure common in behavioral health."
        case .birp: return "Behavior · Intervention · Response · Plan — centers what happened in the room."
        case .narrative: return "Plain-prose summary of the session, no fixed headings — Aletheia's default."
        }
    }

    /// The ordered sections that make up the note. Empty for `.narrative`,
    /// which is intentionally free-form.
    public var sections: [Section] {
        switch self {
        case .soap:
            return [
                Section(heading: "Subjective",
                        guidance: "What the client reported in their own words — presenting concerns, symptoms, mood, and relevant life events as they described them."),
                Section(heading: "Objective",
                        guidance: "Observable, factual data from the session — appearance, affect, behavior, and anything measurable or directly witnessed. No interpretation here."),
                Section(heading: "Assessment",
                        guidance: "The clinician's clinical impression: how the client is doing, progress toward goals, and any risk or clinical concerns supported by the material. Do not invent a diagnosis."),
                Section(heading: "Plan",
                        guidance: "Next steps — interventions used or planned, homework, referrals, medication notes if raised, and the focus or timing of the next session."),
            ]
        case .dap:
            return [
                Section(heading: "Data",
                        guidance: "Both what the client reported and what was observed this session — the factual account of what happened and what was discussed."),
                Section(heading: "Assessment",
                        guidance: "The clinician's clinical impression drawn from the data: progress, themes, and any risk or concern the material supports. Do not invent a diagnosis."),
                Section(heading: "Plan",
                        guidance: "Next steps — interventions, homework, referrals, and the focus or timing of the next session."),
            ]
        case .birp:
            return [
                Section(heading: "Behavior",
                        guidance: "What the client presented with and reported — their words, mood, affect, and behavior in the session."),
                Section(heading: "Intervention",
                        guidance: "What the clinician did — the techniques, approaches, and topics they worked with during the session."),
                Section(heading: "Response",
                        guidance: "How the client responded to those interventions — engagement, insight, shifts, or resistance observed."),
                Section(heading: "Plan",
                        guidance: "Next steps — homework, referrals, and the focus or timing of the next session."),
            ]
        case .narrative:
            return []
        }
    }
}
