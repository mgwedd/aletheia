import Foundation

/// Starter questions surfaced in the chat panes, drawn from the things a
/// therapist most often wants when reviewing sessions. They give the feature
/// discoverability (a blank chat box is intimidating) and steer toward the
/// kinds of questions the local model answers well from the notes.
enum SuggestedQuestions {
    /// Questions scoped to a single session's transcript.
    static let session: [String] = [
        "What were the main themes of this session?",
        "How did the client seem — mood and affect?",
        "Were there any risk or safety concerns?",
        "What homework or action items came up?",
        "What should I follow up on next time?"
    ]

    /// Questions across a patient's whole history.
    static let patient: [String] = [
        "What are the recurring themes across our sessions?",
        "How has their mood changed over time?",
        "What action items are still open?",
        "Have there been any safety or risk flags, and when?",
        "Prepare me for our next session."
    ]
}
