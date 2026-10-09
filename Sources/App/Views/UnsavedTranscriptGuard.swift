import Foundation

/// Lets the session list ask the open session whether it holds transcript edits
/// that haven't been saved, before the selection moves to a different session.
///
/// The open `SessionDetailView` attaches closures that read its live state; the
/// owner of the session list (which is what changes the selection) consults
/// them. Nothing here persists anything by itself.
@MainActor
final class UnsavedTranscriptGuard: ObservableObject {
    private var dirtyCheck: () -> Bool = { false }
    private var saveAction: () -> Bool = { true }
    private var discardAction: () -> Void = {}

    /// Whether the open session has transcript edits that were not saved.
    var hasUnsavedEdits: Bool { dirtyCheck() }

    /// - dirty: whether there are unsaved edits right now.
    /// - save: saves them; returns false if the save failed (edits are kept).
    /// - discard: throws the edits away.
    func attach(dirty: @escaping () -> Bool, save: @escaping () -> Bool, discard: @escaping () -> Void) {
        dirtyCheck = dirty
        saveAction = save
        discardAction = discard
    }

    func detach() {
        dirtyCheck = { false }
        saveAction = { true }
        discardAction = {}
    }

    /// Saves the open session's edits. True if there was nothing to save or the
    /// save succeeded.
    func save() -> Bool { saveAction() }

    func discard() { discardAction() }
}

/// Unsaved transcript edits that were on screen when a session view went away by
/// a route that can't ask first (switching patient, a search result, a Spotlight
/// hit). Kept in memory only, per session, and handed back — still unsaved — the
/// next time that session opens, so a stray click doesn't throw work away.
@MainActor
enum UnsavedTranscriptDrafts {
    private static var drafts: [UUID: String] = [:]

    /// Remembers `draft` for the session, or forgets it if it matches `saved`.
    static func stash(_ draft: String, saved: String, for sessionID: UUID) {
        if draft == saved {
            drafts[sessionID] = nil
        } else {
            drafts[sessionID] = draft
        }
    }

    /// The remembered draft for the session, removing it.
    static func take(for sessionID: UUID) -> String? {
        drafts.removeValue(forKey: sessionID)
    }
}
