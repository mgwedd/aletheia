import Foundation

/// What may go into an AI prompt. Psychotherapy notes are the therapist's
/// private process notes, kept apart from the record, so none of their text is
/// ever handed to note generation, the session chat or the patient chat. Every
/// place that puts the therapist's note into a prompt passes it through here.
enum AIContextPolicy {
    enum Use: CaseIterable {
        case noteGeneration
        case sessionChat
        case patientChat
    }

    static func includesPsychotherapyNote(for use: Use) -> Bool {
        false
    }

    /// `psychotherapyNote` as it may appear in a prompt for `use`: empty when
    /// the note is kept out.
    static func notes(_ psychotherapyNote: String, for use: Use) -> String {
        includesPsychotherapyNote(for: use) ? psychotherapyNote : ""
    }
}
