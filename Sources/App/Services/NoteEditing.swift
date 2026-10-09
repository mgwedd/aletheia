import Foundation

/// Where a session's note in one format stands relative to what the assistant
/// last wrote for it.
///
///     none ──generate──▶ generated ──user edits──▶ edited
///                            ▲                        │
///                            └──regenerate (confirm)──┘   edited text kept as "previous"
enum NoteEditState: Equatable {
    /// No note text for this format.
    case none
    /// The note is exactly what the assistant generated.
    case generated
    /// The note differs from the generated baseline. Treated as the
    /// therapist's own work: Regenerate must ask first and keep the old text.
    case edited
}

/// Pure rules for hand-editing a generated progress note. No I/O — the Store
/// persists the baseline and previous version; the view just asks these.
enum NoteEditing {
    /// Text compared for equality: line endings unified and surrounding
    /// whitespace dropped, so an editor adding a trailing newline doesn't count
    /// as an edit.
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `current` is the saved note, `baseline` the text the assistant last
    /// generated for the same format. With no baseline there is nothing to
    /// differ from, so the note reads as `.generated`.
    static func state(current: String?, baseline: String?) -> NoteEditState {
        guard let current, !normalized(current).isEmpty else { return .none }
        guard let baseline else { return .generated }
        return normalized(current) == normalized(baseline) ? .generated : .edited
    }

    /// Whether Save does anything: the draft must have content and differ from
    /// what is already saved. An unchanged draft writes nothing, and a blank one
    /// is refused (a note is replaced, never silently emptied).
    static func canSave(draft: String, original: String) -> Bool {
        let trimmed = normalized(draft)
        return !trimmed.isEmpty && trimmed != normalized(original)
    }

    /// Whether replacing the saved note with new generated text must first
    /// preserve the current text as the previous version.
    static func shouldArchiveBeforeReplacing(_ state: NoteEditState) -> Bool {
        state == .edited
    }
}
