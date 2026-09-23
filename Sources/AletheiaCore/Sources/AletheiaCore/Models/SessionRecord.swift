import Foundation

public struct SessionRecord: Identifiable, Codable, Hashable {
    public let id: UUID
    public let patientId: UUID
    public let date: Date
    /// Folder name on disk, e.g. "2026-09-16_Session".
    public let folderName: String

    public var hasRecording: Bool
    public var hasTranscript: Bool
    public var hasSummary: Bool

    public init(
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

public enum ChatRole: String, Codable {
    case user
    case assistant
}

public struct ChatMessage: Identifiable, Codable, Equatable {
    public let id: UUID
    public let role: ChatRole
    public let text: String
    public let date: Date

    public init(id: UUID = UUID(), role: ChatRole, text: String, date: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
    }
}
