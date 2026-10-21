import Foundation

/// What the bar above the transcript shows. Save and Discard (and the note
/// about unsaved edits) appear only while there are edits to save; with none,
/// there is no bar at all.
enum TranscriptEditBar {
    static let unsavedNote = "Edits to the transcript are not saved yet"

    static func showsEditControls(isDirty: Bool) -> Bool {
        isDirty
    }

    static func statusNote(isDirty: Bool) -> String? {
        isDirty ? unsavedNote : nil
    }
}
