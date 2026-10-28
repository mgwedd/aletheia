import Foundation

struct SessionRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let patientId: UUID
    let date: Date
    /// Folder name on disk, e.g. "2026-09-16_Session".
    let folderName: String

    var hasRecording: Bool
    var hasTranscript: Bool
    var hasSummary: Bool

    init(
        id: UUID = UUID(),
        patientId: UUID,
        date: Date = Date(),
        folderName: String,
        hasRecording: Bool = false,
        hasTranscript: Bool = false,
        hasSummary: Bool = false
    ) {
        self.id = id
        self.patientId = patientId
        self.date = date
        self.folderName = folderName
        self.hasRecording = hasRecording
        self.hasTranscript = hasTranscript
        self.hasSummary = hasSummary
    }
}

enum ChatRole: String, Codable {
    case user
    case assistant
    /// A compaction: the model's summary of everything before it, which stands
    /// in for those messages in later prompts (see `ChatMemory`).
    case summary
}

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: ChatRole
    let text: String
    let date: Date
    /// True for a reply read straight from My Notes on this Mac (`MyNotesLookup`).
    /// It is shown, but never sent to the model or counted toward compaction,
    /// so My Notes stay out of every prompt. Nil in chats saved before it.
    let fromMyNotes: Bool?

    init(id: UUID = UUID(), role: ChatRole, text: String, date: Date = Date(), fromMyNotes: Bool? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
        self.fromMyNotes = fromMyNotes
    }

    /// Whether the message may go into a prompt.
    var reachesModel: Bool { fromMyNotes != true }
}
