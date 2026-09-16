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
}

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: ChatRole
    let text: String
    let date: Date

    init(id: UUID = UUID(), role: ChatRole, text: String, date: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
    }
}
