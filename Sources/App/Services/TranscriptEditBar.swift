import Foundation

/// What the bar above the transcript shows beside "Comment on selection".
/// Save and Discard (and the note about unsaved edits) appear only while there
/// are edits to save; with none, the bar carries nothing but the comment button.
enum TranscriptEditBar {
    static let unsavedNote = "Edits to the transcript are not saved yet"

    static func showsEditControls(isDirty: Bool) -> Bool {
        isDirty
    }

    static func statusNote(isDirty: Bool) -> String? {
        isDirty ? unsavedNote : nil
    }
}
