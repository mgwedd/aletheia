import Foundation

/// The two kinds of note a session holds, and the words the app uses for them.
///
/// A progress note is the generated session note (dates, modality, assessment,
/// plan) and is part of the clinical record. A psychotherapy note is the
/// therapist's private process note: it is kept apart from the record, left out
/// of the default exports and of every AI prompt, and only exported on its own
/// after the therapist confirms she has the patient's authorization.
enum NoteKind: CaseIterable {
    case progress
    case psychotherapy

    var title: String {
        switch self {
        case .progress: return "Progress note"
        case .psychotherapy: return "Psychotherapy note"
        }
    }

    /// Plural, for result groups and lists.
    var pluralTitle: String {
        switch self {
        case .progress: return "Progress notes"
        case .psychotherapy: return "Psychotherapy notes"
        }
    }

    /// Shown above the psychotherapy note editor.
    static let psychotherapyBanner =
        "Kept separate from the clinical record. Left out of record exports and never read by the AI."

    /// The note area's tip: what it is for and what it is kept apart from.
    static let psychotherapyHelp =
        "Your private process notes for this session, written during or after it. They are kept separate from the clinical record: left out of the default exports, and never used when you generate a note or ask a question."
}
