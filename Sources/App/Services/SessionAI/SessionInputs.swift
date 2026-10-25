import Foundation

/// What a session's note and chat are written from: the saved transcript, the
/// therapist's own notes and the margin comments. Shared by the note and chat
/// models so both read the same material.
@MainActor
final class SessionInputs: ObservableObject {
    @Published var transcriptText = ""
    @Published var myNotes = ""
    @Published var comments: [SessionComment] = []
}

/// Something a generation wants the person to see.
enum AIAlert {
    /// The plain "Something went wrong" alert.
    case message(String)
    /// The AI engine is down or missing its model; `retry` re-runs the request
    /// once the person has fixed it.
    case engine(AIEngineIncident, kind: EngineRetryKind, retry: () -> Void)
}

/// Holds what a long-session note says it was written from, between the run's
/// first report and the save, whatever the picker shows meanwhile.
final class CoverageBox {
    var text: String?
}
