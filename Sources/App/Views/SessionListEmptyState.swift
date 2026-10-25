import Foundation

/// What a patient's session list says when the patient has no sessions yet.
enum SessionListEmptyState {
    static let title = "No Sessions Yet"
    static let detail = "Start a session to record, transcribe, and summarize it."
    static let newSessionButton = "New session"

    static func isShown(sessionCount: Int) -> Bool { sessionCount == 0 }
}
