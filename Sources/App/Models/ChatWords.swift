import Foundation

/// The chat screens' own wording, in one place so screens and tests agree.
enum ChatWords {
    /// The empty Ask tab and chat: `subject` is "this session" or the patient's name.
    static func emptyTitle(about subject: String) -> String { "Ask a question about \(subject)" }
    static func windowTitle(patientName: String) -> String { "Ask about \(patientName)" }
    static let patientGone = "This patient is no longer available."
    static let compactedChip = "Conversation compacted"
    /// What the chat names the person it sits under, for a session's Ask tab.
    static let thisSession = "this session"
    /// A thread's right-click menu in the Chats list, in order.
    static let renameThread = "Rename"
    static let deleteThread = "Delete"
    static let threadMenu = [renameThread, deleteThread]
}
