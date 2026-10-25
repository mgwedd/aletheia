import Foundation

/// Typed repository for the therapist's own annotations — inline margin
/// comments and freeform per-session notes — sitting on the generic
/// `PersistenceCore` (Arch v2 (2), #65/#74/#76) rather than owning any SQL of
/// its own. That's what lets it be unit-tested against
/// `InMemoryPersistenceCore` and run unchanged on `SQLitePersistenceCore` in
/// the app.
///
///   comment — kind "comment", a collection scoped by `itemID = sessionID`,
///             a fresh UUID id per comment.
///   note    — kind "psychotherapyNote", the therapist's private process note:
///             a singleton per session keyed by `sessionID.uuidString`,
///             `itemID = sessionID`. Kept apart from the clinical record (see
///             `AIContextPolicy` and `PsychotherapyExport`). Rows saved before
///             the split carry kind "note" and are moved by
///             `migrateLegacyNotes()`.
///
/// Encoding/encryption is handled by `RecordPayloadCodec`, not this type: a
/// comment or note is JSON-encoded then field-sealed into the record's opaque
/// `payload`, and opened the same way on read.
final class AnnotationRepository {
    private static let commentKind = "comment"
    static let noteKind = "psychotherapyNote"
    static let legacyNoteKind = "note"

    private let core: PersistenceCore
    private let protector: FileProtector
    /// Called when a stored note can't be decoded, so the caller can report it
    /// instead of the note reading as empty.
    var onDecodeFailure: (() -> Void)?

    init(core: PersistenceCore, protector: FileProtector) {
        self.core = core
        self.protector = protector
    }

    // MARK: - Comments

    /// What's actually sealed into a comment's payload. Identity (`id`) and
    /// timestamps already live on the record envelope, so they aren't
    /// duplicated here.
    private struct CommentPayload: Codable {
        var quotedText: String
        var body: String
        var anchorSeconds: Double?
        /// UTF-16 offset of the quote in the transcript at creation time.
        /// Optional so comments written before it existed decode unchanged
        /// (the synthesized decoder treats a missing key as nil); those fall
        /// back to anchoring by quoted text alone.
        var quoteStart: Int?
        /// Google-Docs-style resolution. Optional in the payload so comments
        /// written before this field existed decode cleanly (treated as
        /// unresolved); `makeComment` maps a missing/`nil` value to `false`.
        var resolved: Bool?
    }

    func comments(sessionID: UUID) -> [SessionComment] {
        core.records(kind: Self.commentKind, itemID: sessionID).compactMap(makeComment)
    }

    @discardableResult
    func addComment(
        sessionID: UUID,
        quotedText: String,
        body: String,
        anchorSeconds: Double? = nil,
        quoteStart: Int? = nil,
        now: Date = Date()
    ) -> SessionComment? {
        let payload = CommentPayload(
            quotedText: quotedText, body: body, anchorSeconds: anchorSeconds,
            quoteStart: quoteStart, resolved: false
        )
        guard let data = RecordPayloadCodec.encode(payload, using: protector) else { return nil }
        let record = PersistedRecord(
            id: UUID().uuidString, kind: Self.commentKind, itemID: sessionID,
            payload: data, createdAt: now, updatedAt: now
        )
        guard core.put(record) else { return nil }
        return makeComment(record)
    }

    /// Edits a comment's body only — `quotedText`, `anchorSeconds` and
    /// `quoteStart` are carried over unchanged, matching the original SQL's
    /// `UPDATE ... SET body = ?, updated_at = ?`.
    @discardableResult
    func updateComment(id: String, body: String, now: Date = Date()) -> Bool {
        guard
            var record = core.record(kind: Self.commentKind, id: id),
            var payload = RecordPayloadCodec.decode(CommentPayload.self, from: record.payload, using: protector)
        else { return false }
        payload.body = body
        guard let data = RecordPayloadCodec.encode(payload, using: protector) else { return false }
        record.payload = data
        record.updatedAt = now
        return core.put(record)
    }

    /// Flips a comment's resolved state, leaving `quotedText`, `body`, and
    /// `anchorSeconds` untouched — the Google-Docs "Resolve"/"Reopen" action.
    @discardableResult
    func setCommentResolved(id: String, resolved: Bool, now: Date = Date()) -> Bool {
        guard
            var record = core.record(kind: Self.commentKind, id: id),
            var payload = RecordPayloadCodec.decode(CommentPayload.self, from: record.payload, using: protector)
        else { return false }
        payload.resolved = resolved
        guard let data = RecordPayloadCodec.encode(payload, using: protector) else { return false }
        record.payload = data
        record.updatedAt = now
        return core.put(record)
    }

    @discardableResult
    func deleteComment(id: String) -> Bool {
        core.remove(kind: Self.commentKind, id: id)
    }

    /// The session a comment hangs off, nil when there is no such comment.
    func sessionID(ofComment id: String) -> UUID? {
        core.record(kind: Self.commentKind, id: id)?.itemID
    }

    /// Legacy malformed plaintext remains visible for recovery. A sealed
    /// payload that cannot be opened is omitted from the normal list and
    /// reported by `CommentStore.unreadableEntries` instead.
    private func makeComment(_ record: PersistedRecord) -> SessionComment? {
        if let payload = RecordPayloadCodec.decode(CommentPayload.self, from: record.payload, using: protector) {
            return SessionComment(
                id: record.id, quotedText: payload.quotedText, body: payload.body,
                createdAt: record.createdAt, updatedAt: record.updatedAt,
                anchorSeconds: payload.anchorSeconds, quoteStart: payload.quoteStart,
                resolved: payload.resolved ?? false
            )
        }
        guard let garbled = RecordPayloadCodec.openedText(from: record.payload, using: protector) else { return nil }
        return SessionComment(
            id: record.id, quotedText: "", body: garbled,
            createdAt: record.createdAt, updatedAt: record.updatedAt, anchorSeconds: nil
        )
    }

    // MARK: - Notes

    /// Moves every row of the old "note" kind to the psychotherapy-note kind,
    /// payload untouched (so it works while the folder is locked). Safe to run
    /// again: with no old rows it does nothing. A row whose new-kind twin
    /// already exists (an interrupted earlier run) is just dropped. Returns
    /// the number of rows moved, or nil when a storage error left some behind.
    @discardableResult
    func migrateLegacyNotes() -> Int? {
        var moved = 0
        for old in core.allRecords(kind: Self.legacyNoteKind) {
            if core.record(kind: Self.noteKind, id: old.id) == nil {
                let migrated = PersistedRecord(
                    id: old.id, kind: Self.noteKind, ownerID: old.ownerID, itemID: old.itemID,
                    payload: old.payload, createdAt: old.createdAt, updatedAt: old.updatedAt
                )
                guard core.put(migrated) else { return nil }
            }
            guard core.remove(kind: Self.legacyNoteKind, id: old.id) else { return nil }
            moved += 1
        }
        return moved
    }

    func note(sessionID: UUID) -> String {
        guard let record = core.record(kind: Self.noteKind, id: sessionID.uuidString) else { return "" }
        if let text = RecordPayloadCodec.decode(String.self, from: record.payload, using: protector) {
            return text
        }
        if !protector.isLocked { onDecodeFailure?() }
        return ""
    }

    /// Refuses (returns false) to replace a stored note that can't be decoded,
    /// so a damaged note that reads as empty is never overwritten.
    @discardableResult
    func saveNote(sessionID: UUID, text: String, now: Date = Date()) -> Bool {
        let existing = core.record(kind: Self.noteKind, id: sessionID.uuidString)
        guard RecordPayloadCodec.mayOverwrite(existing, using: protector) else { return false }
        if let existing, RecordPayloadCodec.isDamaged(String.self, payload: existing.payload, using: protector) {
            return false
        }
        guard let data = RecordPayloadCodec.encode(text, using: protector) else { return false }
        let createdAt = existing?.createdAt ?? now
        let record = PersistedRecord(
            id: sessionID.uuidString, kind: Self.noteKind, itemID: sessionID,
            payload: data, createdAt: createdAt, updatedAt: now
        )
        return core.put(record)
    }
}
